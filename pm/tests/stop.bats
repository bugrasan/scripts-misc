#!/usr/bin/env bats
# stub tests for pm stop (pm v9, owner decision R2): for a running pm run
# --hc container, pm stops its core with hc server stop before podman stop,
# as podman stop never signals a core that podman exec started; a fake
# podman logs every call, keeps a running core as a state file, and runs
# pm's own core stop script with a fake hc and kill (FR1-01)
# run: bats pm/tests/stop.bats
# shellcheck disable=SC2016,SC2030,SC2031
# SC2016: literal backticks on purpose; SC2030, SC2031: each bats test runs
# in its own subshell, and its exports are meant for it alone

load test_helper

setup() { stub_setup; }

# core_stop_call <container>: the exec that runs hc server stop there
core_stop_call() {
  podman_find exec -- "$1" sh -c && (( ${#CALL[@]} == 6 )) \
    && [[ ${CALL[5]} == *'hc server stop --json'* ]]
}

# kills: what kill got in the containers, one "<container> <args>" a call
kills() { cat -- "$STUB_STATE/kill.log" 2>/dev/null || true; }

@test "pm stop: a running pm-hc container gets hc server stop, then podman stop" {
  fake_container pm-x pm-x
  : >"$STUB_STATE/cores/pm-x"
  run --separate-stderr pm stop pm-x
  expect_status 0
  local s
  core_stop_call pm-x || { podman_show; fail 'no hc server stop'; }
  s=$FOUND
  podman_find -x stop -- pm-x || { podman_show; fail 'no podman stop'; }
  (( FOUND > s )) || { podman_show; fail 'podman stop came before the core stop'; }
  [ "${lines[0]}" = 'ok    hc core in pm-x stopped' ] || fail "output: $output"
  [ "${lines[1]}" = pm-x ] || fail "output: $output"
  [ ! -e "$STUB_STATE/cores/pm-x" ]
  [ "$(<"$STUB_STATE/status/pm-x")" = exited ]
  [ "$(kills)" = 'pm-x 1' ] || fail "kills: $(kills)"
}

@test "pm stop: no core running is a skip line, and podman stop runs" {
  fake_container pm-x pm-x
  run --separate-stderr pm stop pm-x
  expect_status 0
  core_stop_call pm-x || { podman_show; fail 'no hc server stop'; }
  podman_find -x stop -- pm-x || { podman_show; fail 'no podman stop'; }
  [ "$output" = $'skip  hc core in pm-x: none running\npm-x' ] || fail "output: $output"
  # podman stop ends the container; no kill 1 for it
  [ -z "$(kills)" ] || fail "kills: $(kills)"
}

@test "pm stop: a failing core stop is a skip line with its output; podman stop still runs" {
  fake_container pm-x pm-x
  : >"$STUB_STATE/cores/pm-x"
  export STUB_HCSTOP_RC=127 STUB_HCSTOP_OUT='Error: crun: executable file `hc` not found'
  run --separate-stderr pm stop pm-x
  expect_status 0
  [ "${lines[0]}" = "skip  hc core in pm-x: hc server stop failed: $STUB_HCSTOP_OUT" ] || fail "output: $output"
  podman_find -x stop -- pm-x || { podman_show; fail 'no podman stop'; }
  [ -z "$stderr" ] || fail "stderr: $stderr"
  # an answer that is no stop result counts as a failure too
  fake_container pm-y pm-y
  unset STUB_HCSTOP_RC
  export STUB_HCSTOP_OUT='hc: odd'
  run --separate-stderr pm stop pm-y
  expect_status 0
  [ "${lines[0]}" = 'skip  hc core in pm-y: hc server stop failed: hc: odd' ] || fail "output: $output"
  podman_find -x stop -- pm-y || { podman_show; fail 'no podman stop'; }
  [ -z "$(kills)" ] || fail "kills: $(kills)"
}

@test "FR1-01: once hc stopped the core, the same exec ends the init, so hc on the host starts none before podman stop" {
  fake_container pm-x pm-x
  : >"$STUB_STATE/cores/pm-x"
  run --separate-stderr pm stop pm-x
  expect_status 0
  core_stop_call pm-x || { podman_show; fail 'no core stop exec'; }
  local e=$FOUND
  # kill 1 in that exec, which dies with the container (status 137 here):
  # the ok line comes from hc's answer before it
  [ "$(kills)" = 'pm-x 1' ] || fail "kills: $(kills)"
  [ "$output" = $'ok    hc core in pm-x stopped\npm-x' ] || fail "output: $output"
  [ -z "$stderr" ] || fail "stderr: $stderr"
  # one exec only, and podman stop still runs after it
  podman_load
  local i n=0
  for (( i = 0; i < ${#CALLS[@]}; i++ )); do
    podman_call "$i"
    [[ ${CALL[0]} != exec ]] || (( ++n ))
  done
  (( n == 1 )) || { podman_show; fail "$n execs"; }
  podman_find -x stop -- pm-x || { podman_show; fail 'no podman stop'; }
  (( FOUND > e )) || { podman_show; fail 'podman stop came before the exec'; }

  # a kill that fails with an error: the ok line stays, podman stop runs
  fake_container pm-y pm-y
  : >"$STUB_STATE/cores/pm-y"
  : >"$STUB_STATE/kill.log"
  STUB_KILL_RC=1 run --separate-stderr pm stop pm-y
  expect_status 0
  [ "$output" = $'ok    hc core in pm-y stopped\npm-y' ] || fail "output: $output"
  [ "$(kills)" = 'pm-y 1' ] || fail "kills: $(kills)"
  podman_find -x stop -- pm-y || { podman_show; fail 'no podman stop'; }

  # pm stop still exits with podman stop's status
  fake_container pm-z pm-z
  : >"$STUB_STATE/cores/pm-z"
  STUB_STOP_RC=125 run --separate-stderr pm stop pm-z
  expect_status 125
  [ "$output" = 'ok    hc core in pm-z stopped' ] || fail "output: $output"
  [[ $stderr == *'podman stop failed'* ]] || fail "stderr: $stderr"
}

@test "pm stop: no core stop without the label; a pm-hc container that is not running gets a skip line" {
  fake_container plain
  : >"$STUB_STATE/cores/plain"
  run --separate-stderr pm stop plain
  expect_status 0
  [ "$output" = plain ] || fail "output: $output"
  if podman_find exec; then podman_show; fail 'exec in an unlabeled container'; fi
  fake_container pm-x pm-x
  printf 'exited\n' >"$STUB_STATE/status/pm-x"
  : >"$PODMAN_LOG"
  run --separate-stderr pm stop pm-x
  expect_status 0
  [ "${lines[0]}" = 'skip  hc core in pm-x: container is exited' ] || fail "output: $output"
  if podman_find exec; then podman_show; fail 'exec in a stopped container'; fi
  podman_find -x stop -- pm-x || { podman_show; fail 'no podman stop'; }
}

@test "pm stop: podman's exit status and errors stay; an unknown container gets no core line" {
  fake_container pm-x pm-x
  STUB_STOP_RC=125 run --separate-stderr pm stop pm-x
  expect_status 125
  [[ $stderr == *'podman stop failed'* ]] || fail "stderr: $stderr"
  : >"$PODMAN_LOG"
  run --separate-stderr pm stop nosuch
  expect_status 125
  [ -z "$output" ] || fail "output: $output"
  [[ $stderr == *nosuch* ]] || fail "stderr: $stderr"
  if podman_find exec; then podman_show; fail 'exec for an unknown container'; fi
}

@test "pm stop, then pm start: pm starts no core, which comes back when hc needs it" {
  fake_container pm-x pm-x
  : >"$STUB_STATE/cores/pm-x"
  run --separate-stderr pm stop pm-x
  expect_status 0
  [ ! -e "$STUB_STATE/cores/pm-x" ]
  run --separate-stderr pm start pm-x
  expect_status 0
  [ "$output" = pm-x ] || fail "output: $output"
  no_hc_serve
  [ ! -e "$STUB_STATE/cores/pm-x" ]
}

@test "pm stop: --help and pm help tell about the core stop; usage errors as before" {
  run pm stop --help
  expect_status 0
  [[ $output == *'hc server stop --json, then kill 1'* && $output == *pm-hc* ]] \
    || fail "pm stop --help: $output"
  [[ $output == *'podman exec <container> sh -c'* ]] || fail "pm stop --help: $output"
  run pm help
  expect_status 0
  has_line "$output" '  stop       <container>    after hc server stop for a pm run --hc container'
  run --separate-stderr pm stop
  expect_status 2
  run --separate-stderr pm stop a b
  expect_status 2
  [ ! -s "$PODMAN_LOG" ] || { podman_show; fail 'podman was called'; }
}
