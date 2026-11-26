#!/usr/bin/env bats
# stub tests for pm hc-add and pm hc-rm (pm v9, V9-50 and V9-51: any
# container, no pm-hc label), and the hints in pm run that point to pm
# hc-add; a fake podman and a fake host hc log every call
# run: bats pm/tests/hc-cmds.bats
# shellcheck disable=SC2030,SC2031
# SC2030, SC2031: each bats test runs in its own subshell

load test_helper

setup() { stub_setup; }

IMG=example.org/img:1

# machines <object>...: a machine ls --json answer with these machines
machines() { local IFS=,; printf '{"machines":[%s]}' "$*"; }

CONF=/home/vscode/.config/herdr-core/config.toml
STATE_T=/home/vscode/.local/state/herdr-core

# note_missing <what>: the note of V9-50 for pm-x without these mounts
note_missing() {
  printf 'pm hc-add: note: pm-x does not mount %s from the host, so its hc identity and state end with the container; pm run --hc makes a container that keeps them\n' "$1"
}

# ------------------------------------------------------------------ hc-add

@test "V9-50: hc-add takes any running container: the bash config, then the machine named after it, with a bare podman" {
  fake_container pm-x
  run --separate-stderr pm hc-add pm-x
  expect_status 0
  [ "${lines[0]}" = "ok    pm-x:$CONF: shell = [ \"/bin/bash\" ]" ] || fail "output: $output"
  [ "${lines[1]}" = 'ok    hc machine pm-x added' ] || fail "output: $output"
  [ "$(<"$STUB_STATE/fs/pm-x$CONF")" = 'shell = [ "/bin/bash" ]' ]
  hc_find -x machine add --name pm-x --via 'podman exec -i pm-x sh -c' || { hc_show; fail 'no hc machine add'; }
  [ "$(<"$HC_LOG.stdin")" = devnull ]
  no_hc_serve
  has_line "$stderr" "$(note_missing "/etc/machine-id and $STATE_T")"
}

@test "V9-50: hc-add keeps an existing config.toml with a skip line, and still adds the machine" {
  fake_container pm-x
  mkdir -p "$STUB_STATE/fs/pm-x${CONF%/*}"
  printf 'shell = [ "/bin/zsh" ]\n' >"$STUB_STATE/fs/pm-x$CONF"
  run --separate-stderr pm hc-add pm-x
  expect_status 0
  has_line "$output" "skip  pm-x:$CONF: exists; kept"
  has_line "$output" 'ok    hc machine pm-x added'
  [ "$(<"$STUB_STATE/fs/pm-x$CONF")" = 'shell = [ "/bin/zsh" ]' ]
}

@test "V9-50: a failed config write is an error, exit 1, and the machine is still added" {
  fake_container pm-x
  STUB_HCCONF_RC=1 run --separate-stderr pm hc-add pm-x
  expect_status 1
  has_line "$stderr" "error pm-x:$CONF: Error: stub: write failed"
  has_line "$output" 'ok    hc machine pm-x added'
}

@test "V9-50: the mount note names what is missing, and is gone with both herdr-core mounts" {
  fake_container pm-x '' "$T/id:/etc/machine-id" "$T/state:$STATE_T"
  run --separate-stderr pm hc-add pm-x
  expect_status 0
  [[ $stderr != *'does not mount'* ]] || fail "stderr: $stderr"
  forget_containers
  fake_container pm-x '' "$T/id:/etc/machine-id"
  run --separate-stderr pm hc-add pm-x
  expect_status 0
  has_line "$stderr" "$(note_missing "$STATE_T")"
  forget_containers
  fake_container pm-x '' "$T/state:$STATE_T" "$P:/workspaces/proj"
  run --separate-stderr pm hc-add pm-x
  expect_status 0
  has_line "$stderr" "$(note_missing /etc/machine-id)"
}

@test "F1-01: hc-add given a container ID names the machine and the config line after the container" {
  fake_container pm-x
  fake_id 0123abcd pm-x
  run --separate-stderr pm hc-add 0123abcd
  expect_status 0
  hc_find -x machine add --name pm-x --via 'podman exec -i pm-x sh -c' || { hc_show; fail 'no machine pm-x'; }
  has_line "$output" "ok    pm-x:$CONF: shell = [ \"/bin/bash\" ]"
  has_line "$output" 'ok    hc machine pm-x added'
  has_line "$stderr" "$(note_missing "/etc/machine-id and $STATE_T")"
  [[ $output$stderr != *0123abcd* ]] || fail "the ID names the machine: $output $stderr"
}

@test "F1-04: hc-add uses the container user's HOME for config.toml and the state mount" {
  fake_container pm-x '' "$T/id:/etc/machine-id" "$T/state:/root/.local/state/herdr-core"
  fake_home pm-x /root
  run --separate-stderr pm hc-add pm-x
  expect_status 0
  has_line "$output" 'ok    pm-x:/root/.config/herdr-core/config.toml: shell = [ "/bin/bash" ]'
  [ "$(<"$STUB_STATE/fs/pm-x/root/.config/herdr-core/config.toml")" = 'shell = [ "/bin/bash" ]' ]
  [[ $stderr != *'does not mount'* ]] || fail "stderr: $stderr"
  # the state folder of /home/vscode does not count for a /root user
  forget_containers
  fake_container pm-x '' "$T/id:/etc/machine-id" "$T/state:$STATE_T"
  fake_home pm-x /root
  run --separate-stderr pm hc-add pm-x
  expect_status 0
  has_line "$stderr" "$(note_missing /root/.local/state/herdr-core)"
}

@test "F1-05: only a bind mount counts; a volume or tmpfs at a herdr-core target gets the note" {
  fake_container pm-x '' "vol:/etc/machine-id:volume" "$T/state:$STATE_T"
  run --separate-stderr pm hc-add pm-x
  expect_status 0
  has_line "$stderr" "$(note_missing /etc/machine-id)"
  forget_containers
  fake_container pm-x '' "$T/id:/etc/machine-id" "tmpfs:$STATE_T:tmpfs"
  run --separate-stderr pm hc-add pm-x
  expect_status 0
  has_line "$stderr" "$(note_missing "$STATE_T")"
}

@test "V9-50: hc-add ignores a pm-hc label from an earlier v9 build" {
  fake_container pm-x other
  run --separate-stderr pm hc-add pm-x
  expect_status 0
  hc_find -x machine add --name pm-x --via 'podman exec -i pm-x sh -c' || { hc_show; fail 'no machine pm-x'; }
}

@test "hc-add: a machine with pm's connection stays, with a note" {
  fake_container pm-x
  FAKE_HC_LS=$(machines "$(hc_machine pm-x "$(pm_via pm-x)")")
  export FAKE_HC_LS
  run --separate-stderr pm hc-add pm-x
  expect_status 0
  has_line "$stderr" 'pm hc-add: note: hc machine pm-x already connects to this container; kept'
  if hc_find machine add; then hc_show; fail 'added again'; fi
}

@test "hc-add: another connection or a failed add is an error, exit 1" {
  fake_container pm-x
  FAKE_HC_LS=$(machines "$(hc_machine pm-x 'ssh box' false)") run --separate-stderr pm hc-add pm-x
  expect_status 1
  has_line "$stderr" 'error pm-x: hc already has a machine pm-x with another connection; see hc machine ls'
  : >"$HC_LOG"
  FAKE_HC_ADD_RC=1 FAKE_HC_ADD_OUT='{"error":{"kind":"unreachable"}}' run --separate-stderr pm hc-add pm-x
  expect_status 1
  has_line "$stderr" 'error pm-x: hc machine add: {"error":{"kind":"unreachable"}}'
}

@test "V9-50: no such container, a stopped one, a name hc rejects, or no hc is an error before anything happens" {
  run --separate-stderr pm hc-add nope
  expect_status 1
  has_line "$stderr" 'error container nope: Error: no such container nope'
  fake_container pm-x
  printf 'exited\n' >"$STUB_STATE/status/pm-x"
  run --separate-stderr pm hc-add pm-x
  expect_status 1
  has_line "$stderr" 'error container pm-x is exited; start it with: pm start pm-x'
  fake_container Up
  run --separate-stderr pm hc-add Up
  expect_status 1
  has_line "$stderr" 'error hc cannot use Up as a machine name: 1-32 of a-z 0-9 - _ ., a letter or digit first, not like t7'
  printf 'running\n' >"$STUB_STATE/status/pm-x"
  rm -- "$STUB_BIN/hc"
  use_min_path
  run --separate-stderr pm hc-add pm-x
  expect_status 1
  has_line "$stderr" 'error no hc on PATH; install it on this host to add pm-x as an hc machine'
  if podman_find exec; then podman_show; fail 'pm ran podman exec'; fi
  [ ! -s "$HC_LOG" ] || { hc_show; fail 'pm called hc'; }
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

@test "V9-51: hc-rm removes the machine with pm's connection from any container; the container stays" {
  fake_container pm-x
  FAKE_HC_LS=$(machines "$(hc_machine pm-x "$(pm_via pm-x)")")
  export FAKE_HC_LS
  run --separate-stderr pm hc-rm pm-x
  expect_status 0
  hc_find -x machine rm -- pm-x || { hc_show; fail 'no hc machine rm'; }
  [ "$output" = 'ok    hc machine pm-x removed' ] || fail "output: $output"
  if podman_find rm; then podman_show; fail 'pm removed the container'; fi
  [[ -e $STUB_STATE/containers/pm-x ]]
}

@test "F1-01: hc-rm given a container ID removes the machine named after the container" {
  fake_container pm-x
  fake_id 0123abcd pm-x
  FAKE_HC_LS=$(machines "$(hc_machine pm-x "$(pm_via pm-x)")")
  export FAKE_HC_LS
  run --separate-stderr pm hc-rm 0123abcd
  expect_status 0
  hc_find -x machine rm -- pm-x || { hc_show; fail 'no hc machine rm pm-x'; }
  [ "$output" = 'ok    hc machine pm-x removed' ] || fail "output: $output"
}

@test "hc-rm: a machine that is gone is a skip line, exit 0; a stopped container is fine" {
  fake_container pm-x
  printf 'exited\n' >"$STUB_STATE/status/pm-x"
  run --separate-stderr pm hc-rm pm-x
  expect_status 0
  [ "$output" = 'skip  hc machine pm-x: not in hc machine ls' ] || fail "output: $output"
}

@test "V9-51: hc-rm: another connection, no such container, no hc, or a failed rm is an error, exit 1" {
  fake_container pm-x
  FAKE_HC_LS=$(machines "$(hc_machine pm-x 'ssh box' false)") run --separate-stderr pm hc-rm pm-x
  expect_status 1
  has_line "$stderr" 'error hc machine pm-x has another connection; remove it by hand with: hc machine rm pm-x'
  if hc_find machine rm; then hc_show; fail 'pm removed the machine'; fi

  FAKE_HC_LS=$(machines "$(hc_machine pm-x "$(pm_via pm-x)")")
  FAKE_HC_LS=$FAKE_HC_LS FAKE_HC_RM_RC=4 FAKE_HC_RM_OUT='{"error":{"kind":"machine_unknown"}}' \
    run --separate-stderr pm hc-rm pm-x
  expect_status 1
  has_line "$stderr" 'error hc machine pm-x: {"error":{"kind":"machine_unknown"}}; remove it by hand with: hc machine rm pm-x'

  : >"$HC_LOG"
  run --separate-stderr pm hc-rm nope
  expect_status 1
  has_line "$stderr" 'error container nope: Error: no such container nope'
  [ ! -s "$HC_LOG" ] || { hc_show; fail 'pm called hc for a missing container'; }

  rm -- "$STUB_BIN/hc"
  use_min_path
  run --separate-stderr pm hc-rm pm-x
  expect_status 1
  has_line "$stderr" 'error no hc on PATH; install it on this host to remove the hc machine pm-x'
}

@test "decision 4: hc-add and hc-rm leave a machine with an absolute podman path alone, as another connection" {
  fake_container pm-x
  FAKE_HC_LS=$(machines "$(hc_machine pm-x '/usr/local/bin/podman exec -i pm-x sh -c')")
  export FAKE_HC_LS
  run --separate-stderr pm hc-add pm-x
  expect_status 1
  has_line "$stderr" 'error pm-x: hc already has a machine pm-x with another connection; see hc machine ls'
  run --separate-stderr pm hc-rm pm-x
  expect_status 1
  has_line "$stderr" 'error hc machine pm-x has another connection; remove it by hand with: hc machine rm pm-x'
  if hc_find machine rm || hc_find machine add; then hc_show; fail 'pm changed hc'; fi
}

@test "V9-50, V9-51: the help of hc-add and hc-rm names the exact connection and any container, no label" {
  run pm hc-add --help
  expect_status 0
  has_line "$output" "runs: hc machine add --name <name> --via 'podman exec -i <name> sh -c'"
  [[ $output == *config.toml* && $output == *'/etc/machine-id'* && $output == *'pm run --hc'* ]] \
    || fail "pm hc-add --help: $output"
  [[ $output != *pm-hc* && $output != *label* && $output != *'podman path'* ]] \
    || fail "pm hc-add --help: $output"
  run pm hc-rm --help
  expect_status 0
  [[ $output == *'exactly podman exec -i <name> sh -c'* ]] || fail "pm hc-rm --help: $output"
  # F1-02: a renamed container leaves its old machine behind
  [[ $output == *'podman rename'* && $output == *'hc machine rm <old name>'* ]] \
    || fail "pm hc-rm --help lacks the rename note: $output"
  [[ $output != *pm-hc* && $output != *label* && $output != *'podman path'* ]] \
    || fail "pm hc-rm --help: $output"
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
