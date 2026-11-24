#!/usr/bin/env bats
# stub tests for pm hc-add and pm hc-rm (pm v9), and the hints in pm run
# that point to pm hc-add; a fake podman and a fake host hc log every call
# run: bats pm/tests/hc-cmds.bats
# shellcheck disable=SC2030,SC2031
# SC2030, SC2031: each bats test runs in its own subshell

load test_helper

setup() { stub_setup; }

IMG=example.org/img:1

# machines <object>...: a machine ls --json answer with these machines
machines() { local IFS=,; printf '{"machines":[%s]}' "$*"; }

# ------------------------------------------------------------------ hc-add

@test "hc-add: starts hc serve, then adds the machine named by the label" {
  fake_container pm-x pm-x
  run --separate-stderr pm hc-add pm-x
  expect_status 0
  hc_serve_call pm-x || { podman_show; fail 'no hc serve'; }
  hc_find -x machine add --name pm-x --via "$(pm_via pm-x)" || { hc_show; fail 'no hc machine add'; }
  [ "$(<"$HC_LOG.stdin")" = devnull ]
  [ "$output" = 'ok    hc serve started in pm-x
ok    hc machine pm-x added' ] || fail "output: $output"
}

@test "hc-add: a machine with pm's connection stays, with a note" {
  fake_container pm-x pm-x
  FAKE_HC_LS=$(machines "$(hc_machine pm-x "$(pm_via pm-x)")")
  export FAKE_HC_LS
  run --separate-stderr pm hc-add pm-x
  expect_status 0
  has_line "$stderr" 'pm hc-add: note: hc machine pm-x already connects to this container; kept'
  if hc_find machine add; then hc_show; fail 'added again'; fi
}

@test "hc-add: another connection or a failed add is an error, exit 1" {
  fake_container pm-x pm-x
  FAKE_HC_LS=$(machines "$(hc_machine pm-x 'ssh box' false)") run --separate-stderr pm hc-add pm-x
  expect_status 1
  has_line "$stderr" 'error pm-x: hc already has a machine pm-x with another connection; see hc machine ls'
  : >"$HC_LOG"
  FAKE_HC_ADD_RC=1 FAKE_HC_ADD_OUT='{"error":{"kind":"unreachable"}}' run --separate-stderr pm hc-add pm-x
  expect_status 1
  has_line "$stderr" 'error pm-x: hc machine add: {"error":{"kind":"unreachable"}}'
}

@test "hc-add: no pm-hc label, a stopped container, or no hc is an error before anything happens" {
  fake_container pm-y
  run --separate-stderr pm hc-add pm-y
  expect_status 1
  has_line "$stderr" 'error pm-y has no pm-hc label; only pm run --hc sets it, when it creates a container'
  fake_container pm-x pm-x
  printf 'exited\n' >"$STUB_STATE/status/pm-x"
  run --separate-stderr pm hc-add pm-x
  expect_status 1
  has_line "$stderr" 'error container pm-x is exited; start it with: pm start pm-x'
  printf 'running\n' >"$STUB_STATE/status/pm-x"
  rm -- "$STUB_BIN/hc"
  use_min_path
  run --separate-stderr pm hc-add pm-x
  expect_status 1
  has_line "$stderr" 'error no hc on PATH; install it on this host to add pm-x as an hc machine'
  if podman_find exec; then podman_show; fail 'pm started hc serve'; fi
}

@test "hc-add and hc-rm: exactly one container, else a usage error" {
  local sub
  for sub in hc-add hc-rm; do
    run --separate-stderr pm "$sub"
    expect_status 2
    [[ $stderr == "usage: pm $sub <container>"* ]] || fail "stderr: $stderr"
    run --separate-stderr pm "$sub" a b
    expect_status 2
    run --separate-stderr pm "$sub" --help
    expect_status 0
    [[ $output == "usage: pm $sub <container>"* ]] || fail "output: $output"
  done
}

# ------------------------------------------------------------------ hc-rm

@test "hc-rm: removes the machine with pm's connection; the container stays" {
  fake_container pm-x pm-x
  FAKE_HC_LS=$(machines "$(hc_machine pm-x "$(pm_via pm-x)")")
  export FAKE_HC_LS
  run --separate-stderr pm hc-rm pm-x
  expect_status 0
  hc_find -x machine rm -- pm-x || { hc_show; fail 'no hc machine rm'; }
  [ "$output" = 'ok    hc machine pm-x removed' ] || fail "output: $output"
  if podman_find rm; then podman_show; fail 'pm removed the container'; fi
  [[ -e $STUB_STATE/containers/pm-x ]]
}

@test "hc-rm: a machine that is gone is a skip line, exit 0; a stopped container is fine" {
  fake_container pm-x pm-x
  printf 'exited\n' >"$STUB_STATE/status/pm-x"
  run --separate-stderr pm hc-rm pm-x
  expect_status 0
  [ "$output" = 'skip  hc machine pm-x: not in hc machine ls' ] || fail "output: $output"
}

@test "hc-rm: another connection, no hc, no label, or a failed rm is an error, exit 1" {
  fake_container pm-x pm-x
  FAKE_HC_LS=$(machines "$(hc_machine pm-x 'ssh box' false)") run --separate-stderr pm hc-rm pm-x
  expect_status 1
  has_line "$stderr" 'error hc machine pm-x has another connection; remove it by hand with: hc machine rm pm-x'
  if hc_find machine rm; then hc_show; fail 'pm removed the machine'; fi

  FAKE_HC_LS=$(machines "$(hc_machine pm-x "$(pm_via pm-x)")")
  FAKE_HC_LS=$FAKE_HC_LS FAKE_HC_RM_RC=4 FAKE_HC_RM_OUT='{"error":{"kind":"machine_unknown"}}' \
    run --separate-stderr pm hc-rm pm-x
  expect_status 1
  has_line "$stderr" 'error hc machine pm-x: {"error":{"kind":"machine_unknown"}}; remove it by hand with: hc machine rm pm-x'

  fake_container pm-y
  run --separate-stderr pm hc-rm pm-y
  expect_status 1
  has_line "$stderr" 'error pm-y has no pm-hc label; only pm run --hc sets it, when it creates a container'

  rm -- "$STUB_BIN/hc"
  use_min_path
  run --separate-stderr pm hc-rm pm-x
  expect_status 1
  has_line "$stderr" 'error no hc on PATH; install it on this host to remove the hc machine pm-x'
}

# ------------------------------------------------------------------ pm run hints

@test "pm run: without hc, the note points to pm hc-add" {
  rm -- "$STUB_BIN/hc"
  use_min_path
  fake_hash sha256sum
  run --separate-stderr pm run --hc --mount "$P" "$IMG"
  expect_status 0
  has_line "$stderr" 'pm run: note: no hc on PATH, so pm-proj is not added as an hc machine; add it later with: pm hc-add pm-proj'
}

@test "pm run: a failed hc machine ls or add points to pm hc-add" {
  FAKE_HC_ADD_RC=1 FAKE_HC_ADD_OUT='{"error":{"kind":"unreachable"}}' \
    run --separate-stderr pm run --hc --mount "$P" "$IMG"
  expect_status 1
  has_line "$stderr" 'pm run: add it later with: pm hc-add pm-proj'
  forget_containers
  FAKE_HC_LS_RC=1 FAKE_HC_LS='{"error":{"kind":"unavailable"}}' \
    run --separate-stderr pm run --hc --mount "$P" "$IMG" c2
  expect_status 1
  has_line "$stderr" 'pm run: add it later with: pm hc-add c2'
}
