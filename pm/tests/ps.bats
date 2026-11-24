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
  # the host's core runs: a process of this user in the test's pid namespace
  fake ps "printf '%s hc serve\n' $$"
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
  # P7: the default table with the agent columns before PROJECT
  [[ ${lines[0]} =~ ^CONTAINER\ ID\ +NAME\ +STATUS\ +PM\ +NETWORK\ +CONT-HERDR\ +HOST-HERDR\ +SECRET-CC\ +CONFIG-CC\ +SECRET-CP\ +CONFIG-CP\ +PROJECT$ ]] \
    || fail "header: ${lines[0]}"
  [ "$(ps_cell PROJECT "$(ps_row pm-proj)")" = "$P" ]
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

@test "ps --agents: no secrets and no files give no and n/a; one exec per running container for each part" {
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
  # the agent files: one exec per running container; the herdr columns
  # their own one, and no podman top
  podman_load
  for (( i = 0; i < ${#CALLS[@]}; i++ )); do
    [[ ${CALLS[i]} != exec*sha256sum* ]] || n=$((n + 1))
  done
  [ "$n" -eq 2 ] || { podman_show; fail "$n hash execs for 2 running containers"; }
  n=0
  for (( i = 0; i < ${#CALLS[@]}; i++ )); do
    [[ ${CALLS[i]} != exec*/proc* ]] || n=$((n + 1))
  done
  [ "$n" -eq 2 ] || { podman_show; fail "$n herdr execs for 2 running containers"; }
  if podman_find top; then podman_show; fail 'pm ps called podman top'; fi
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

# ------------------------------------------------------------------ review round 1

@test "ps --agents: a newline in the create command splits no row and hides no --secret" {
  fake_container odd
  printf '%s\0' podman run -d -e $'NOTE=a\nb' --secret cc_token,type=env,target=X \
    --name odd example.org/img:1 sleep infinity >"$STUB_STATE/create/odd"
  run --separate-stderr pm ps --agents
  expect_status 0
  [ "${#lines[@]}" -eq 2 ] || fail "rows: $output"
  [ "$(ps_cell SECRET-CC "$(ps_row odd)")" = yes ]
  [ "$(ps_cell SECRET-CP "$(ps_row odd)")" = no ]
}

@test "ps --agents: a mount secret counts, and a name that only starts alike does not" {
  fake_container ms
  printf 'cp_token\n' >"$STUB_STATE/secrets/ms"
  fake_container alike
  printf '%s\0' podman run --secret cc_token2,type=env,target=X --secret=cp_token_old \
    --name alike example.org/img:1 >"$STUB_STATE/create/alike"
  run --separate-stderr pm ps --agents
  expect_status 0
  [ "$(ps_cell SECRET-CP "$(ps_row ms)")" = yes ]
  [ "$(ps_cell SECRET-CC "$(ps_row ms)")" = no ]
  [ "$(ps_cell SECRET-CC "$(ps_row alike)")" = no ]
  [ "$(ps_cell SECRET-CP "$(ps_row alike)")" = no ]
}

@test "ps --agents: an unreadable file in the container is n/a and shifts no other state" {
  (( EUID != 0 )) || skip 'root can read any file'
  run --separate-stderr pm run --cc --cp --mount "$P" "$IMG"
  expect_status 0
  chmod 000 "$STUB_STATE/fs/pm-proj/home/vscode/.claude/CLAUDE.md"
  run --separate-stderr pm ps --agents
  chmod 600 "$STUB_STATE/fs/pm-proj/home/vscode/.claude/CLAUDE.md"
  expect_status 0
  [ "$(ps_cell CONFIG-CC "$(ps_row pm-proj)")" = n/a,identical ]
  [ "$(ps_cell CONFIG-CP "$(ps_row pm-proj)")" = identical,identical ]
}

@test "ps: no rows, no hc machine ls; a failing one makes HOST-HERDR unavailable" {
  run --separate-stderr pm ps
  expect_status 0
  [ ! -s "$HC_LOG" ] || { hc_show; fail 'hc machine ls without rows'; }
  fake_container up pm-up
  fake ps "printf '%s hc serve\n' $$"
  FAKE_HC_LS_RC=1 FAKE_HC_LS='{"error":{"kind":"unavailable"}}' run --separate-stderr pm ps
  expect_status 0
  [ "$(ps_cell HOST-HERDR "$(ps_row up)")" = unavailable ]
}

@test "ps: without a running host core, HOST-HERDR is stopped and pm asks hc nothing" {
  fake_container up pm-up
  fake_container down pm-down
  printf 'exited\n' >"$STUB_STATE/status/down"
  # no hc serve among this user's processes; a container's core in another
  # pid namespace (here: a process that does not exist) does not count
  fake ps "printf '%s\n' '999999999 hc serve' '1 /usr/bin/sleep 9'"
  run --separate-stderr pm ps -a
  expect_status 0
  [ "$(ps_cell HOST-HERDR "$(ps_row up)")" = stopped ]
  [ "$(ps_cell HOST-HERDR "$(ps_row down)")" = stopped ]
  [ ! -s "$HC_LOG" ] || { hc_show; fail 'pm ps called hc without a host core'; }
}

@test "ps: at most 5 execs run at once, and more than 5 running containers keep their rows" {
  local i r
  for i in 1 2 3 4 5 6 7 8; do fake_container "c$i"; done
  : >"$STUB_STATE/cores/c2"; : >"$STUB_STATE/cores/c5"; : >"$STUB_STATE/cores/c8"
  : >"$STUB_STATE/nohc/c3"; : >"$STUB_STATE/nohc/c7"
  # c4 alone has the host's CLAUDE.md
  mkdir -p "$STUB_STATE/fs/c4/home/vscode/.claude"
  cp -- "$PM_CLAUDE_MD" "$STUB_STATE/fs/c4/home/vscode/.claude/CLAUDE.md"
  export STUB_EXEC_DELAY=0.3
  run --separate-stderr pm ps --agents
  expect_status 0
  [ "$(cat -- "$STUB_STATE/execs.max")" -le 5 ] || fail "peak: $(cat -- "$STUB_STATE/execs.max")"
  [ "$(cat -- "$STUB_STATE/execs.max")" -ge 2 ] || fail 'the execs did not overlap'
  # the rows in container order, each with its own results
  [ "$(sed 1d <<<"$output" | cut -d' ' -f1 | tr '\n' ' ')" = 'c1 c2 c3 c4 c5 c6 c7 c8 ' ] || fail "rows: $output"
  for i in 1 2 3 4 5 6 7 8; do
    r=$(ps_row "c$i")
    case $i in
      2|5|8) [ "$(ps_cell CONT-HERDR "$r")" = running ] || fail "c$i: $r" ;;
      3|7)   [ "$(ps_cell CONT-HERDR "$r")" = unavailable ] || fail "c$i: $r" ;;
      *)     [ "$(ps_cell CONT-HERDR "$r")" = stopped ] || fail "c$i: $r" ;;
    esac
    if (( i == 4 )); then [ "$(ps_cell CONFIG-CC "$r")" = identical,n/a ] || fail "c4: $r"
    else [ "$(ps_cell CONFIG-CC "$r")" = n/a,n/a ] || fail "c$i: $r"; fi
  done
}

@test "ps: an exec that gets no file descriptor leaves its cells unavailable and n/a" {
  local i r want got failed=0
  for i in 1 2 3 4 5 6 7 8; do
    fake_container "c$i"
    (( i % 2 == 0 )) || : >"$STUB_STATE/cores/c$i"
    mkdir -p "$STUB_STATE/fs/c$i/home/vscode/.claude"
    cp -- "$PM_CLAUDE_MD" "$STUB_STATE/fs/c$i/home/vscode/.claude/CLAUDE.md"
  done
  # fds 10 to 13 only: bash holds two of them while it opens one, so of each
  # round of 5 execs only the first ones get a descriptor
  run --separate-stderr "$BASH" -c 'ulimit -n 14 && exec "$@"' _ \
    env PATH="$PM_PATH" "$BASH" "$PM_SH" ps --agents
  expect_status 0
  [ -z "$stderr" ] || fail "stderr: $stderr"
  for i in 1 2 3 4 5 6 7 8; do
    r=$(ps_row "c$i") want=stopped got=$(ps_cell CONT-HERDR "$r")
    (( i % 2 == 0 )) || want=running
    if [ "$got" = unavailable ]; then
      (( ++failed ))
      [ "$(ps_cell CONFIG-CC "$r")" = n/a,n/a ] || fail "c$i: $r"
    else
      [ "$got" = "$want" ] && [ "$(ps_cell CONFIG-CC "$r")" = identical,n/a ] || fail "c$i: $r"
    fi
  done
  (( failed > 0 && failed < 8 )) || fail "unavailable rows: $failed of 8: $output"
}
