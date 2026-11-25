#!/usr/bin/env bats
# stub tests for pm stop and pm start (pm v9): plain podman stop and podman
# start for every container, also one made with pm run --hc, whose main
# command, hc serve, gets podman stop's SIGTERM through the init and comes
# back with podman start; a fake podman logs every call and keeps a
# running core as a state file
# run: bats pm/tests/stop.bats
# shellcheck disable=SC2030,SC2031
# SC2030, SC2031: each bats test runs in its own subshell, and its exports
# are meant for it alone

load test_helper

setup() { stub_setup; }

IMG=example.org/img:1

# only_call <arg>...: podman got exactly one call, with these arguments
only_call() {
  podman_load
  (( ${#CALLS[@]} == 1 )) && podman_find -x "$@" && return 0
  podman_show >&2
  fail "not just: podman $*"
}

@test "pm stop: plain podman stop, also for a running pm-hc container, whatever its state" {
  local c
  fake_container pm-x pm-x
  fake_container pm-y pm-y
  printf 'exited\n' >"$STUB_STATE/status/pm-y"
  fake_container plain
  for c in pm-x pm-y plain; do
    : >"$PODMAN_LOG"
    run --separate-stderr pm stop "$c"
    expect_status 0
    [ "$output" = "$c" ] || fail "output: $output"
    [ -z "$stderr" ] || fail "stderr: $stderr"
    only_call stop -- "$c"
  done
}

@test "pm stop: podman's exit status and errors stay" {
  fake_container pm-x pm-x
  STUB_STOP_RC=125 run --separate-stderr pm stop pm-x
  expect_status 125
  [[ $stderr == *'podman stop failed'* ]] || fail "stderr: $stderr"
  : >"$PODMAN_LOG"
  run --separate-stderr pm stop nosuch
  expect_status 125
  [ -z "$output" ] || fail "output: $output"
  [[ $stderr == *nosuch* ]] || fail "stderr: $stderr"
  only_call stop -- nosuch
}

@test "pm stop, then pm start: plain podman calls; the main command hc serve ends and comes back" {
  run --separate-stderr pm run --hc --mount "$P" "$IMG"
  expect_status 0
  [[ -e $STUB_STATE/cores/pm-proj ]] || fail 'no core after pm run --hc'
  : >"$PODMAN_LOG"
  run --separate-stderr pm stop pm-proj
  expect_status 0
  [ "$output" = pm-proj ] || fail "output: $output"
  only_call stop -- pm-proj
  [[ ! -e $STUB_STATE/cores/pm-proj ]] || fail 'the core runs after pm stop'
  : >"$PODMAN_LOG"
  run --separate-stderr pm start pm-proj
  expect_status 0
  [ "$output" = pm-proj ] || fail "output: $output"
  only_call start -- pm-proj
  [[ -e $STUB_STATE/cores/pm-proj ]] || fail 'no core after pm start'
}

@test "pm stop and pm start: the help says podman stop and start only; usage errors as before" {
  run pm stop --help
  expect_status 0
  has_line "$output" 'runs: podman stop <container>'
  [[ $output != *'hc server stop'* && $output != *'kill 1'* && $output != *'podman exec'* ]] \
    || fail "pm stop --help: $output"
  run pm start --help
  expect_status 0
  has_line "$output" 'runs: podman start <container>'
  [[ $output == *'hc serve'* && $output == *'pm run --hc'* ]] || fail "pm start --help: $output"
  run pm help
  expect_status 0
  has_line "$output" '  stop       <container>'
  [[ $output != *'hc server stop'* ]] || fail "pm help: $output"
  run --separate-stderr pm stop
  expect_status 2
  run --separate-stderr pm stop a b
  expect_status 2
  [ ! -s "$PODMAN_LOG" ] || { podman_show; fail 'podman was called'; }
}
