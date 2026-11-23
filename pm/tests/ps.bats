#!/usr/bin/env bats
# stub tests for the pm ps tables (pm v9): the default columns, with the
# experimental CONT-HERDR and HOST-HERDR, and pm ps --agents; a fake podman
# and a fake host hc answer; fake container names double as their IDs
# run: bats pm/tests/ps.bats
# shellcheck disable=SC2030,SC2031
# SC2030, SC2031: each bats test runs in its own subshell

load test_helper

setup() {
  stub_setup
  export PM_CLAUDE_MD=$T/claude.md PM_CLAUDE_SETTINGS=$T/claude-settings.json \
    PM_COPILOT_SETTINGS=$T/copilot-settings.json STUB_SECRETS='cc_token cp_token'
  printf 'rules\n' >"$PM_CLAUDE_MD"
  printf '{"a":1}\n' >"$PM_CLAUDE_SETTINGS"
  printf '{"b":2}\n' >"$PM_COPILOT_SETTINGS"
}

IMG=example.org/img:1

# machines <object>...: a machine ls --json answer with these machines
machines() { local IFS=,; printf '{"machines":[%s]}' "$*"; }

# ------------------------------------------------------------------ the table

@test "ps: the default table has the v9 columns, no namespace column" {
  run --separate-stderr pm ps
  expect_status 0
  [[ ${lines[0]} =~ ^CONTAINER\ ID\ +NAME\ +STATUS\ +PM\ +NETWORK\ +CONT-HERDR\ +HOST-HERDR\ +PROJECT$ ]] \
    || fail "header: ${lines[0]}"
}

@test "ps: PM shows v and the pm-script label; NETWORK the networks, else the mode" {
  run --separate-stderr pm run --hc --mount "$P" "$IMG"
  expect_status 0
  fake_container old
  printf '8\n' >"$STUB_STATE/pmscript/old"
  fake_container plain
  run --separate-stderr pm ps
  expect_status 0
  local r
  r=$(ps_row pm-proj)
  [ "$(ps_cell PM "$r")" = v9 ]
  [ "$(ps_cell NETWORK "$r")" = proj ]
  [ "$(ps_cell PROJECT "$r")" = "$P" ]
  r=$(ps_row old)
  [ "$(ps_cell PM "$r")" = v8 ]
  [ "$(ps_cell NETWORK "$r")" = '(pasta)' ]
  r=$(ps_row plain)
  [ -z "$(ps_cell PM "$r")" ]
}

@test "ps: CONT-HERDR is running, stopped, or unavailable" {
  run --separate-stderr pm run --hc --mount "$P" "$IMG"
  expect_status 0
  fake_container idle
  fake_container nohcc
  : >"$STUB_STATE/nohc/nohcc"
  fake_container off
  printf 'exited\n' >"$STUB_STATE/status/off"
  : >"$STUB_STATE/nohc/off"
  run --separate-stderr pm ps -a
  expect_status 0
  [ "$(ps_cell CONT-HERDR "$(ps_row pm-proj)")" = running ]
  [ "$(ps_cell CONT-HERDR "$(ps_row idle)")" = stopped ]
  [ "$(ps_cell CONT-HERDR "$(ps_row nohcc)")" = unavailable ]
  # a container that is not running is stopped, hc or not
  [ "$(ps_cell CONT-HERDR "$(ps_row off)")" = stopped ]
}

@test "ps: HOST-HERDR is yes with pm's machine, no without, unavailable without hc" {
  run --separate-stderr pm run --hc --mount "$P" "$IMG"
  expect_status 0
  fake_container other
  FAKE_HC_LS=$(machines "$(hc_machine pm-proj "$(pm_via pm-proj)")" "$(hc_machine other 'ssh other' false)")
  export FAKE_HC_LS
  run --separate-stderr pm ps
  expect_status 0
  [ "$(ps_cell HOST-HERDR "$(ps_row pm-proj)")" = yes ]
  [ "$(ps_cell HOST-HERDR "$(ps_row other)")" = no ]
  rm -- "$STUB_BIN/hc"
  use_min_path
  run --separate-stderr pm ps
  expect_status 0
  [ "$(ps_cell HOST-HERDR "$(ps_row pm-proj)")" = unavailable ]
}

@test "ps: without -a only running containers; -a adds the others" {
  fake_container up
  fake_container down
  printf 'exited\n' >"$STUB_STATE/status/down"
  run --separate-stderr pm ps
  expect_status 0
  [ -n "$(ps_row up)" ]
  [ -z "$(ps_row down)" ]
  run --separate-stderr pm ps --all
  expect_status 0
  [ "$(ps_cell STATUS "$(ps_row down)")" = exited ]
}

@test "ps: the help marks CONT-HERDR and HOST-HERDR as experimental" {
  run pm ps --help
  expect_status 0
  [[ $output == *CONT-HERDR*experimental* && $output == *HOST-HERDR* && $output == *--agents* ]] \
    || fail "help: $output"
}

# ------------------------------------------------------------------ --agents

@test "ps --agents: secrets from podman inspect, files compared with the host's" {
  run --separate-stderr pm run --cc --cp --mount "$P" "$IMG"
  expect_status 0
  run --separate-stderr pm ps --agents
  expect_status 0
  [[ ${lines[0]} =~ ^CONTAINER\ ID\ +NAME\ +STATUS\ +SECRET-CC\ +CONFIG-CC\ +SECRET-CP\ +CONFIG-CP$ ]] \
    || fail "header: ${lines[0]}"
  local r
  r=$(ps_row pm-proj)
  [ "$(ps_cell SECRET-CC "$r")" = yes ]
  [ "$(ps_cell SECRET-CP "$r")" = yes ]
  [ "$(ps_cell CONFIG-CC "$r")" = identical,identical ]
  [ "$(ps_cell CONFIG-CP "$r")" = identical,identical ]

  # a changed CLAUDE.md differs in both; a missing settings file is n/a
  printf 'new rules\n' >"$PM_CLAUDE_MD"
  rm -- "$PM_COPILOT_SETTINGS"
  run --separate-stderr pm ps --agents
  expect_status 0
  r=$(ps_row pm-proj)
  [ "$(ps_cell CONFIG-CC "$r")" = differ,identical ]
  [ "$(ps_cell CONFIG-CP "$r")" = differ,n/a ]
}

@test "ps --agents: no secrets and no files give no and n/a; one exec per running container" {
  run --separate-stderr pm run --mount "$P" "$IMG"
  expect_status 0
  fake_container nosum
  : >"$STUB_STATE/nosha/nosum"
  : >"$PODMAN_LOG"
  run --separate-stderr pm ps --agents
  expect_status 0
  local r i n=0
  r=$(ps_row pm-proj)
  [ "$(ps_cell SECRET-CC "$r")" = no ]
  [ "$(ps_cell SECRET-CP "$r")" = no ]
  [ "$(ps_cell CONFIG-CC "$r")" = n/a,n/a ]
  [ "$(ps_cell CONFIG-CP "$r")" = n/a,n/a ]
  [ "$(ps_cell CONFIG-CC "$(ps_row nosum)")" = n/a,n/a ]
  podman_load
  for (( i = 0; i < ${#CALLS[@]}; i++ )); do
    [[ ${CALLS[i]} != exec* ]] || n=$((n + 1))
  done
  [ "$n" -eq 2 ] || { podman_show; fail "$n execs for 2 running containers"; }
}

@test "ps --agents: a stopped container shows stopped in the CONFIG columns; -a combines" {
  run --separate-stderr pm run --cc --mount "$P" "$IMG"
  expect_status 0
  printf 'exited\n' >"$STUB_STATE/status/pm-proj"
  run --separate-stderr pm ps --agents
  expect_status 0
  [ -z "$(ps_row pm-proj)" ]
  local args r
  for args in '--agents -a' '-a --agents' '--all --agents'; do
    # shellcheck disable=SC2086  # split the argument string on purpose
    run --separate-stderr pm ps $args
    expect_status 0
    r=$(ps_row pm-proj)
    [ "$(ps_cell SECRET-CC "$r")" = yes ] || fail "$args: $r"
    [ "$(ps_cell SECRET-CP "$r")" = no ]
    [ "$(ps_cell CONFIG-CC "$r")" = stopped ]
    [ "$(ps_cell CONFIG-CP "$r")" = stopped ]
  done
  run --separate-stderr pm ps --agents x
  expect_status 2
}
