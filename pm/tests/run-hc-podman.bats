#!/usr/bin/env bats
# integration tests for pm run --hc with real rootless podman; skipped
# unless PM_TEST_PODMAN=1:
#   PM_TEST_PODMAN=1 bats pm/tests/run-hc-podman.bats
# PM_TEST_IMAGE sets the image, which must have hc on its PATH (default:
# ghcr.io/bugrasan/devcontainer-base-ai/base:latest); needs python3
# the tests write only below BATS_TEST_TMPDIR and to
# $HOME/.config/herdr-core/container/<unique-name>-*, and remove their
# containers, networks, state folders, and the image without hc that one
# test commits, also when they fail; pm itself
# also creates $HOME/.config/herdr-core/container in the real HOME when it
# is missing and sets $HOME/.config/herdr-core to mode 700, as it does for
# every pm run --hc; the tests leave both in place
# the hc machine test uses the image's own hc as the host's hc, with a host
# core of its own (state and socket below BATS_TEST_TMPDIR) that teardown
# stops; the other tests run without hc on PATH

# shellcheck disable=SC2030,SC2031
# SC2030, SC2031: each bats test runs in its own subshell

load test_helper

# the image's hc, once per file, for the host side of the machine test
setup_file() {
  [[ ${PM_TEST_PODMAN-} == 1 ]] || return 0
  local img=${PM_TEST_IMAGE:-ghcr.io/bugrasan/devcontainer-base-ai/base:latest} cid
  mkdir -p -- "$BATS_FILE_TMPDIR/hcbin"
  cid=$(podman create "$img" true) || return 0
  podman cp "$cid:/usr/local/bin/hc" "$BATS_FILE_TMPDIR/hcbin/hc" >/dev/null 2>&1 || true
  podman rm -- "$cid" >/dev/null 2>&1 || true
}

setup() {
  [[ ${PM_TEST_PODMAN-} == 1 ]] || skip 'set PM_TEST_PODMAN=1 to run with real rootless podman'
  command -v podman >/dev/null || fail 'podman not found'
  need_python
  IMG=${PM_TEST_IMAGE:-ghcr.io/bugrasan/devcontainer-base-ai/base:latest}
  # unique per test and run: the folder names the container and network
  NAME=pmhc-t$BATS_TEST_NUMBER-$$-$RANDOM
  DIR=$BATS_TEST_TMPDIR/$NAME
  CTR=pm-$NAME
  CTR2=$CTR-2
  NET=$NAME
  HC=$HOME/.config/herdr-core/container
  HOST_HC=0
  SECRETS=()
  NOHC_IMG=''
  mkdir -p -- "$DIR"
}

teardown() {
  [[ -n ${NAME-} ]] || return 0
  # the isolated host core of the machine test
  if (( HOST_HC )); then hc server stop >/dev/null 2>&1 || true; fi
  # the podman secrets a test made
  local s
  for s in "${SECRETS[@]}"; do podman secret rm -- "$s" >/dev/null 2>&1 || true; done
  podman rm -f -t 0 -- "$CTR" >/dev/null 2>&1 || true
  podman rm -f -t 0 -- "$CTR2" >/dev/null 2>&1 || true
  podman rm -f -t 0 -- "$CTR2-2" >/dev/null 2>&1 || true
  # the image without hc, once no container uses it
  [[ -z ${NOHC_IMG-} ]] || podman rmi -f -- "$NOHC_IMG" >/dev/null 2>&1 || true
  podman network rm -- "$NET" >/dev/null 2>&1 || true
  local d
  for d in "$HC/$NAME"-*; do
    [[ -e $d ]] || continue
    # files the container wrote as another user need podman unshare
    rm -rf -- "$d" 2>/dev/null || podman unshare rm -rf -- "$d" || true
  done
}

# core_ids <state>: wait up to 30 s for a core.json below <state> (in a
# session folder) that has machine_id and id; print "<machine_id> <id>"
core_ids() {
  local state=$1 i f out
  for (( i = 0; i < 60; i++ )); do
    while IFS= read -r f; do
      if out=$(python3 -I -c 'import json, sys
d = json.load(open(sys.argv[1]))
print(d["machine_id"], d["id"])' "$f" 2>/dev/null); then
        printf '%s\n' "$out"
        return 0
      fi
    done < <(find "$state" -name core.json 2>/dev/null)
    sleep 0.5
  done
  printf 'no usable core.json below %s after 30 s:\n' "$state" >&2
  find "$state" -ls >&2 || true
  find "$state" -name core.json -exec cat {} + >&2 || true
  return 1
}

# core_started <state> <marker>: wait up to 30 s for a core.lock below
# <state> newer than the file <marker>; herdr-core rewrites the lock at
# each start, but core.json only when it creates the identity or when a
# stored core.json takes on a new machine-id
core_started() {
  local i
  for (( i = 0; i < 60; i++ )); do
    [[ -z $(find "$1" -name core.lock -newer "$2" 2>/dev/null) ]] || return 0
    sleep 0.5
  done
  find "$1" -ls >&2 || true
  fail "no core started below $1 after 30 s"
}

# running_core_id <container>: the core id that hc server status reports,
# polled for up to 30 s
running_core_id() {
  local i out
  for (( i = 0; i < 60; i++ )); do
    if out=$(podman exec "$1" hc server status --json 2>/dev/null \
      | python3 -I -c 'import json, sys
print(json.load(sys.stdin)["core"]["id"])' 2>/dev/null); then
      printf '%s\n' "$out"
      return 0
    fi
    sleep 0.5
  done
  podman exec "$1" hc server status --json >&2 || true
  fail "hc server status in $1 reports no core id"
}

# core_procs <container>: the command lines of the core processes there,
# hc serve or herdr-core serve, whoever started them; status 1 for none
core_procs() {
  podman exec "$1" sh -c 'for f in /proc/[0-9]*/cmdline; do tr "\000" " " <"$f"; echo; done' \
    2>/dev/null | grep -E '(^|/)(hc|herdr-core) serve( |$)'
}

# core_running <container>: wait up to 30 s for a core process
core_running() {
  local i
  for (( i = 0; i < 60; i++ )); do
    core_procs "$1" >/dev/null && return 0
    sleep 0.5
  done
  podman top "$1" args >&2 || true
  fail "no core process in $1"
}

# init_child <container>: fail unless the init (pid 1, podman-init) has
# exactly one child in podman top, and that child is hc serve
init_child() {
  local top
  top=$(podman top "$1" pid ppid args)
  [[ $(awk '$1 == 1 { print $3 }' <<<"$top") == /run/podman-init ]] || fail "no init as pid 1: $top"
  [[ $(awk '$2 == 1 { print $3, $4, NF }' <<<"$top") == 'hc serve 4' ]] \
    || fail "the init's children are not just hc serve: $top"
}

# bare_agent <container>: what a bare hc run --bg starts there, as hc names
# it (the shell's base name); it starts a core when none runs
bare_agent() {
  podman exec "$1" hc run --bg 2>/dev/null | python3 -I -c 'import json, sys
print(json.load(sys.stdin)["agent"])'
}

# use_host_hc: the image's hc as this host's hc, with a core of its own:
# XDG_STATE_HOME and HC_SOCKET below BATS_TEST_TMPDIR; XDG_RUNTIME_DIR and
# XDG_CONFIG_HOME stay, as podman, which the core runs for the machine
# connection, reads them
use_host_hc() {
  [[ -x $BATS_FILE_TMPDIR/hcbin/hc ]] || fail 'could not take hc from the image'
  export PATH=$BATS_FILE_TMPDIR/hcbin:$PATH
  export XDG_STATE_HOME=$BATS_TEST_TMPDIR/hc-state HC_SOCKET=$BATS_TEST_TMPDIR/hc.sock
  mkdir -p -- "$XDG_STATE_HOME"
  HOST_HC=1
}

# host_machine <name>: "<target> <via>" of that machine in hc machine ls
# --json, or nothing
host_machine() {
  hc machine ls --json | python3 -I -c 'import json, sys
for m in json.load(sys.stdin)["machines"]:
    if m["name"] == sys.argv[1]:
        print(m["target"], m["via"])' "$1"
}

# host_connected <name>: wait up to 30 s until hc here holds a line to
# that machine (state connected in hc machine ls --json)
host_connected() {
  local i
  for (( i = 0; i < 60; i++ )); do
    [[ $(hc machine ls --json | python3 -I -c 'import json, sys
for m in json.load(sys.stdin)["machines"]:
    if m["name"] == sys.argv[1]:
        print(m["state"])' "$1") != connected ]] || return 0
    sleep 0.5
  done
  hc machine ls --json >&2 || true
  fail "hc here holds no line to $1"
}

# core_shell <container>: SHELL in the environment of the running core,
# from /proc/<pid>/environ inside the container
core_shell() {
  podman exec "$1" sh -c '
    for p in /proc/[0-9]*; do
      case $(tr "\000" " " <"$p/cmdline" 2>/dev/null) in
        "hc serve "|*"/hc serve "|"herdr-core serve "|*"/herdr-core serve ") ;;
        *) continue ;;
      esac
      tr "\000" "\n" <"$p/environ" | sed -n "s/^SHELL=//p"
      exit 0
    done
    exit 1'
}

@test "pm run --hc: mounts, the bash config, hc serve as the init's child with no output in podman logs; the identity survives pm rm --force" {
  run --separate-stderr pm run --hc --mount "$DIR" "$IMG"
  expect_status 0
  local f=$DIR/herdr-machine-id id state mounts ids mid core_id core_id2
  id=$(<"$f")
  is_id "$id"
  state=$HC/$NAME-$(sha256_hex "$id")
  [[ -d $state ]] || { ls -la "$HC" >&2; fail "missing $state"; }
  [ "$(file_mode "$state")" = 700 ]

  # the id file is mounted read-only, the state folder read-write
  mounts=$(podman container inspect --format \
    '{{range .Mounts}}{{.Destination}} {{.RW}}{{"\n"}}{{end}}' -- "$CTR")
  has_line "$mounts" '/etc/machine-id false'
  has_line "$mounts" '/home/vscode/.local/state/herdr-core true'
  [ "$(podman exec "$CTR" cat /etc/machine-id)" = "$id" ]
  if podman exec "$CTR" sh -c 'test -w /etc/machine-id'; then fail '/etc/machine-id is writable'; fi
  podman exec "$CTR" touch /home/vscode/.local/state/herdr-core/.pm-test-rw
  [[ -e $state/.pm-test-rw ]]
  rm -f -- "$state/.pm-test-rw"

  # pm wrote exactly the bash line into herdr-core's config; the
  # container's environment keeps no SHELL
  has_line "$output" "ok    $CTR:/home/vscode/.config/herdr-core/config.toml: shell = [ \"/bin/bash\" ]"
  podman exec "$CTR" cat /home/vscode/.config/herdr-core/config.toml >"$BATS_TEST_TMPDIR/config.toml"
  printf 'shell = [ "/bin/bash" ]\n' | cmp - "$BATS_TEST_TMPDIR/config.toml" \
    || fail "config.toml: $(<"$BATS_TEST_TMPDIR/config.toml")"
  [ "$(podman exec "$CTR" sh -c 'echo "${SHELL-unset}"')" = unset ]
  # the core is the main command: hc serve is the init's only child, exec
  # left no sh between them, and hc writes nothing to podman logs; that core
  # has no SHELL, and the config gives a bare hc run --bg bash all the same
  core_running "$CTR"
  init_child "$CTR"
  [ -z "$(podman logs "$CTR" 2>&1)" ] || fail "podman logs: $(podman logs "$CTR" 2>&1)"
  [ -z "$(core_shell "$CTR")" ] || fail "the core runs with SHELL=$(core_shell "$CTR")"
  [ "$(bare_agent "$CTR")" = bash ] || fail "a bare hc run --bg starts: $(bare_agent "$CTR")"
  ids=$(core_ids "$state")
  read -r mid core_id <<<"$ids"
  [ "$mid" = "$id" ] || fail "machine_id $mid, id file $id"
  [ -n "$core_id" ]
  [ "$(running_core_id "$CTR")" = "$core_id" ]

  # pm rm --force keeps the id file and the state folder; a second run
  # reuses them
  run --separate-stderr pm rm --force "$CTR"
  expect_status 0
  [ "$(<"$f")" = "$id" ]
  [[ -d $state ]]
  touch -- "$BATS_TEST_TMPDIR/second-run"
  run --separate-stderr pm run --hc --mount "$DIR" "$IMG"
  expect_status 0
  [[ $stderr != *'new herdr-core state folder'* ]] || fail "$stderr"
  core_running "$CTR"
  core_started "$state" "$BATS_TEST_TMPDIR/second-run"
  ids=$(core_ids "$state")
  read -r mid core_id2 <<<"$ids"
  [ "$mid" = "$id" ]
  [ "$core_id2" = "$core_id" ] || fail "core id changed: $core_id -> $core_id2"
  [ "$(running_core_id "$CTR")" = "$core_id" ]
}

@test "pm run --hc with .devcontainer: dev container paths and a running core" {
  mkdir -- "$DIR/.devcontainer"
  run --separate-stderr pm run --hc --mount "$DIR" "$IMG"
  expect_status 0
  local f=$DIR/.devcontainer/herdr-machine-id id suffix ids mid
  local -a states=("$HC/$NAME"-*)
  id=$(<"$f")
  is_id "$id"
  [[ ! -e $DIR/herdr-machine-id ]]
  [ "${#states[@]}" -eq 1 ]
  [[ -d ${states[0]} ]] || { ls -la "$HC" >&2; fail 'no state folder'; }
  suffix=${states[0]##*/"$NAME"-}
  [[ $suffix =~ ^[0123456789abcdefghijklmnopqrstuv]{52}$ ]] || fail "suffix $suffix"
  if [[ -n $NODE ]]; then [ "$suffix" = "$(ref_id "$DIR")" ]; fi
  core_running "$CTR"
  ids=$(core_ids "${states[0]}")
  read -r mid _ <<<"$ids"
  [ "$mid" = "$id" ] || fail "machine_id $mid, id file $id"
}

@test "pm run: no second container for the same folder; the podman run line it prints works" {
  run --separate-stderr pm run --hc --mount "$DIR" "$IMG"
  expect_status 0
  run --separate-stderr pm run --hc --mount "$DIR" "$IMG" "$CTR2"
  expect_status 1
  has_line "$stderr" "error the folder $DIR or its herdr-core state folder is already mounted by: $CTR; pm does not support a second container on the same folder, for consistency reasons"
  # the container runs: pm bash uses it, pm rm --force and pm run remake it
  has_line "$stderr" "pm run: to use it, open a terminal in it with: pm bash $CTR"
  has_line "$stderr" "pm run: to make it again, remove it with: pm rm --force $CTR, then run pm run again"
  local err=$stderr line
  run podman container exists -- "$CTR2"
  [ "$status" -ne 0 ]
  # the example creates a plain second container as printed
  line=$(grep -m1 '^  podman run ' <<<"$err") || fail "no example in: $err"
  eval "$line" >/dev/null
  podman container exists -- "$CTR2-2"
}

@test "pm run --hc adds a real hc machine with a bare podman; after pm stop and pm start the same core runs" {
  use_host_hc
  run --separate-stderr pm run --hc --mount "$DIR" "$IMG"
  expect_status 0
  has_line "$output" "ok    hc machine $CTR added"
  [ "$(host_machine "$CTR")" = "podman exec -i $CTR sh -c True" ] \
    || fail "machine: $(hc machine ls --json)"
  # the main command runs the core, which has no SHELL; the config gives a
  # bare hc run --bg bash
  core_running "$CTR"
  [ "$(bare_agent "$CTR")" = bash ] || fail "a bare hc run --bg starts: $(bare_agent "$CTR")"
  # hc on the host reaches the container through the via connection
  run --separate-stderr hc exec --on "$CTR" uname -a
  expect_status 0
  [[ $output == Linux* ]] || fail "uname: $output"
  local core_id
  core_id=$(running_core_id "$CTR")

  # pm stop and pm start are plain: the init passes SIGTERM on to hc serve,
  # and the main command brings the same core back, with its state
  run --separate-stderr pm stop "$CTR"
  expect_status 0
  [ "$output" = "$CTR" ] || fail "output: $output"
  [ "$(podman container inspect --format '{{.State.ExitCode}}' -- "$CTR")" != 137 ] \
    || fail 'hc serve needed SIGKILL'
  run --separate-stderr pm start "$CTR"
  expect_status 0
  [ "$output" = "$CTR" ] || fail "output: $output"
  core_running "$CTR"
  init_child "$CTR"
  [ "$(running_core_id "$CTR")" = "$core_id" ]
  # hc here dials the machine again with a backoff of its own
  host_connected "$CTR"
  run --separate-stderr hc exec --on "$CTR" uname -a
  expect_status 0
  [[ $output == Linux* ]] || fail "uname after pm start: $output"

  # pm rm --force --hc-rm removes the container and its machine; --hc-rm
  # asks hc whether or not pm sees a host core (V9-53), so the outcome does
  # not depend on how the host core shows up in ps
  run --separate-stderr pm rm --force --hc-rm "$CTR"
  expect_status 0
  has_line "$output" "ok    hc machine $CTR removed"
  [ -z "$(host_machine "$CTR")" ] || fail "machine left: $(hc machine ls --json)"
}

# host_core_gone: stop the isolated host core and wait up to 30 s until
# pm's own process check sees no host core
host_core_gone() {
  local i
  hc server stop >/dev/null 2>&1 || true
  for (( i = 0; i < 60; i++ )); do
    pm_internal _pm_host_core_running || return 0
    sleep 0.5
  done
  fail 'the host core still runs after hc server stop'
}

@test "F1-07: pm rm without a running host core gives a skip line and starts none; pm rm --hc-rm removes the machine" {
  use_host_hc
  # pm sees every hc core of this user; another one makes this test moot
  if pm_internal _pm_host_core_running; then skip 'an hc core of this user already runs on this host'; fi
  run --separate-stderr pm run --hc --mount "$DIR" "$IMG"
  expect_status 0
  has_line "$output" "ok    hc machine $CTR added"
  host_core_gone

  # V9-52: no host core, so pm rm asks hc nothing and starts no core
  run --separate-stderr pm rm --force "$CTR"
  expect_status 0
  has_line "$output" "ok    container $CTR removed"
  has_line "$output" "skip  hc machine $CTR: hc core on this host not running; not checked"
  [ ! -S "$HC_SOCKET" ] || fail 'pm rm started a host core'
  # the machine stays (listing it starts the core again)
  [ "$(host_machine "$CTR")" = "podman exec -i $CTR sh -c True" ] \
    || fail "machine: $(hc machine ls --json)"

  # V9-53: a new container of that name keeps the machine; with the host
  # core stopped again, pm rm --hc-rm still removes it
  run --separate-stderr pm run --hc --mount "$DIR" "$IMG"
  expect_status 0
  has_line "$stderr" "pm run: note: hc machine $CTR already connects to this container; kept"
  host_core_gone
  run --separate-stderr pm rm --force --hc-rm "$CTR"
  expect_status 0
  has_line "$output" "ok    hc machine $CTR removed"
  [ -z "$(host_machine "$CTR")" ] || fail "machine left: $(hc machine ls --json)"
}

@test "pm run --hc: a failed podman run removes container and network, keeps the identity" {
  run --separate-stderr pm run --hc --mount "$DIR" localhost/pm-test-no-such-image:none
  expect_status 1
  run podman container exists -- "$CTR"
  [ "$status" -ne 0 ]
  run podman network exists -- "$NET"
  [ "$status" -ne 0 ]
  is_id "$(<"$DIR/herdr-machine-id")"
  local -a states=("$HC/$NAME"-*)
  [[ -d ${states[0]} ]]
}

# real_row <name>: the line of the pm ps output in $output for container
# <name>, whose ID is a real 12-digit one
real_row() { grep -m1 -E "^[0123456789abcdef]{12} +$1( |$)" <<<"$output"; }

@test "pm hc-add and pm hc-rm with a real host hc; pm ps shows PM, NETWORK, and the herdr columns" {
  # without hc on PATH, pm run points to pm hc-add
  run --separate-stderr pm run --hc --mount "$DIR" "$IMG"
  expect_status 0
  has_line "$stderr" "pm run: note: no hc on PATH, so $CTR is not added as an hc machine; add it later with: pm hc-add $CTR"
  use_host_hc
  # hc on PATH, but no host core yet: pm ps shows stopped and starts none;
  # the container's core runs already, as its main command
  core_running "$CTR"
  run --separate-stderr pm ps
  expect_status 0
  [ "$(ps_cell HOST-HERDR "$(real_row "$CTR")")" = stopped ] || fail "output: $output"
  [ "$(ps_cell CONT-HERDR "$(real_row "$CTR")")" = running ] || fail "output: $output"
  [ ! -e "$HC_SOCKET" ] || fail 'pm ps started a host core'
  run --separate-stderr pm hc-add "$CTR"
  expect_status 0
  has_line "$output" "ok    hc machine $CTR added"
  [ -S "$HC_SOCKET" ] || fail 'no host core socket after pm hc-add'
  [ "$(host_machine "$CTR")" = "podman exec -i $CTR sh -c True" ] \
    || fail "machine: $(hc machine ls --json)"

  run --separate-stderr pm ps
  expect_status 0
  local r
  r=$(real_row "$CTR") || fail "no row for $CTR in: $output"
  [ "$(ps_cell PM "$r")" = "v9" ]
  [ "$(ps_cell NETWORK "$r")" = "$NET" ]
  [ "$(ps_cell CONT-HERDR "$r")" = running ]
  [ "$(ps_cell HOST-HERDR "$r")" = yes ]
  [ "$(ps_cell PROJECT "$r")" = "$DIR" ]

  # a machine with an absolute podman path is another connection: pm ps
  # shows no, and pm hc-add and pm hc-rm leave it alone
  hc machine rm -- "$CTR" >/dev/null
  hc machine add --name "$CTR" --via "$(command -v podman) exec -i $CTR sh -c" \
    </dev/null >/dev/null
  run --separate-stderr pm ps
  expect_status 0
  [ "$(ps_cell HOST-HERDR "$(real_row "$CTR")")" = no ] || fail "output: $output"
  run --separate-stderr pm hc-add "$CTR"
  expect_status 1
  has_line "$stderr" "error $CTR: hc already has a machine $CTR with another connection; see hc machine ls"
  run --separate-stderr pm hc-rm "$CTR"
  expect_status 1
  [ "$(host_machine "$CTR")" = "$(command -v podman) exec -i $CTR sh -c True" ] \
    || fail "machine: $(hc machine ls --json)"
  hc machine rm -- "$CTR" >/dev/null
  run --separate-stderr pm hc-add "$CTR"
  expect_status 0

  # hc-rm drops the machine and keeps the container; a second hc-rm skips
  run --separate-stderr pm hc-rm "$CTR"
  expect_status 0
  [ "$output" = "ok    hc machine $CTR removed" ] || fail "output: $output"
  [ -z "$(host_machine "$CTR")" ]
  podman container exists -- "$CTR"
  run --separate-stderr pm hc-rm "$CTR"
  expect_status 0
  [ "$output" = "skip  hc machine $CTR: not in hc machine ls" ] || fail "output: $output"
  run --separate-stderr pm ps
  expect_status 0
  [ "$(ps_cell HOST-HERDR "$(real_row "$CTR")")" = no ]

  # a stopped container counts as stopped in CONT-HERDR
  run --separate-stderr pm stop "$CTR"
  expect_status 0
  run --separate-stderr pm ps -a
  expect_status 0
  [ "$(ps_cell CONT-HERDR "$(real_row "$CTR")")" = stopped ]
}

@test "pm run --cc --cp copies the agent files; pm ps --agents compares them, with real secrets" {
  local cc=pmt-cc-$$-$RANDOM cp=pmt-cp-$$-$RANDOM r
  printf 'token' | podman secret create -- "$cc" - >/dev/null
  SECRETS+=("$cc")
  printf 'token' | podman secret create -- "$cp" - >/dev/null
  SECRETS+=("$cp")
  export PM_CC_SECRET=$cc PM_CP_SECRET=$cp
  export PM_CLAUDE_MD=$BATS_TEST_TMPDIR/claude.md PM_CLAUDE_SETTINGS=$BATS_TEST_TMPDIR/claude.json \
    PM_COPILOT_SETTINGS=$BATS_TEST_TMPDIR/copilot.json PM_COPILOT_CONFIG=$BATS_TEST_TMPDIR/config.json
  printf 'rules\n' >"$PM_CLAUDE_MD"
  printf '{"a":1}\n' >"$PM_CLAUDE_SETTINGS"
  printf '{"b":2}\n' >"$PM_COPILOT_SETTINGS"
  printf '{"c":3}\n' >"$PM_COPILOT_CONFIG"

  run --separate-stderr pm run --cc --cp --mount "$DIR" "$IMG"
  expect_status 0
  [ "$(podman exec "$CTR" cat /home/vscode/.claude/CLAUDE.md)" = rules ]
  [ "$(podman exec "$CTR" cat /home/vscode/.copilot/copilot-instructions.md)" = rules ]
  [ "$(podman exec "$CTR" cat /home/vscode/.copilot/settings.json)" = '{"b":2}' ]
  [ "$(podman exec "$CTR" cat /home/vscode/.copilot/config.json)" = '{"c":3}' ]
  # the Copilot CLI rewrites config.json, so pm ps --agents never compares it
  podman exec "$CTR" sh -c 'echo rewritten >/home/vscode/.copilot/config.json'

  run --separate-stderr pm ps --agents
  expect_status 0
  r=$(real_row "$CTR") || fail "no row for $CTR in: $output"
  [ "$(ps_cell SECRET-CC "$r")" = yes ]
  [ "$(ps_cell SECRET-CP "$r")" = yes ]
  [ "$(ps_cell CONFIG-CC "$r")" = identical,identical ]
  [ "$(ps_cell CONFIG-CP "$r")" = identical,identical ]

  printf 'changed\n' >"$PM_CLAUDE_MD"
  rm -- "$PM_COPILOT_SETTINGS"
  run --separate-stderr pm ps --agents
  expect_status 0
  r=$(real_row "$CTR")
  [ "$(ps_cell CONFIG-CC "$r")" = differ,identical ]
  [ "$(ps_cell CONFIG-CP "$r")" = differ,n/a ]

  # a file the container user cannot read is n/a and shifts no other state
  printf 'rules\n' >"$PM_CLAUDE_MD"
  podman exec --user root -- "$CTR" chmod 000 /home/vscode/.claude/CLAUDE.md
  run --separate-stderr pm ps --agents
  expect_status 0
  r=$(real_row "$CTR")
  [ "$(ps_cell CONFIG-CC "$r")" = n/a,identical ] || fail "row: $r"
  [ "$(ps_cell CONFIG-CP "$r")" = identical,n/a ] || fail "row: $r"

  run --separate-stderr pm stop "$CTR"
  expect_status 0
  run --separate-stderr pm ps --agents -a
  expect_status 0
  r=$(real_row "$CTR")
  [ "$(ps_cell SECRET-CC "$r")" = yes ]
  [ "$(ps_cell CONFIG-CC "$r")" = stopped ]
}

@test "pm doctor reports this host's tools, one line each" {
  run --separate-stderr pm doctor
  local line failed=0
  for line in "${lines[@]}"; do
    case $line in
      required|optional) ;;
      'ok     '*|'failed '*) ;;
      *) fail "odd line: $line" ;;
    esac
  done
  # exit 1 exactly when a required check failed
  failed=$(sed -n '/^required$/,/^optional$/p' <<<"$output" | grep -c '^failed ' || true)
  if (( failed )); then [ "$status" -eq 1 ]; else [ "$status" -eq 0 ]; fi
  # this host: bash 5.2 and jq 1.7 are below the minimums, podman 6.2 meets it
  if [[ $(bash --version) == *'version 5.2.'* ]]; then
    grep -qE '^failed bash 5\.2\.[0-9]+ \(needs 5\.3 or later\)$' <<<"$output" || fail "bash line: $output"
  fi
  if [[ $(jq --version 2>/dev/null) == jq-1.7* ]]; then
    grep -qE '^failed jq 1\.7(\.[0-9]+)? \(needs 1\.8 or later\)$' <<<"$output" || fail "jq line: $output"
  fi
  if [[ $(podman --version) == 'podman version 6.2.'* ]]; then
    grep -qE '^ok     podman 6\.2\.[0-9]+ \(needs 6\.2 or later\)$' <<<"$output" || fail "podman line: $output"
  fi
}

@test "pm doctor does not count the core of a keep-id container as the host's" {
  run --separate-stderr pm run --hc --mount "$DIR" "$IMG"
  expect_status 0
  core_running "$CTR"
  # the container's core runs as this user, in another pid namespace
  run --separate-stderr pm doctor
  has_line "$output" 'failed hc core not running (starts on first hc use)'
}

@test "pm ps --agents: a newline in a real create command, and a mount secret" {
  local cc=pmt-cc-$$-$RANDOM cp=pmt-cp-$$-$RANDOM r
  printf 'token' | podman secret create -- "$cc" - >/dev/null
  SECRETS+=("$cc")
  printf 'token' | podman secret create -- "$cp" - >/dev/null
  SECRETS+=("$cp")
  export PM_CC_SECRET=$cc PM_CP_SECRET=$cp
  podman run -d --init --userns=keep-id -e $'NOTE=a\nb' --secret "$cc,type=env,target=X_TOKEN" \
    --name "$CTR" "$IMG" sleep infinity >/dev/null
  podman run -d --init --userns=keep-id --secret "$cp" --name "$CTR2" "$IMG" sleep infinity >/dev/null
  run --separate-stderr pm ps --agents
  expect_status 0
  # one row each, however the create command spells its arguments
  [ "$(grep -c -E " $CTR " <<<"$output")" -eq 1 ] || fail "rows: $output"
  r=$(real_row "$CTR") || fail "no row for $CTR in: $output"
  [ "$(ps_cell SECRET-CC "$r")" = yes ]
  [ "$(ps_cell SECRET-CP "$r")" = no ]
  r=$(real_row "$CTR2") || fail "no row for $CTR2 in: $output"
  [ "$(ps_cell SECRET-CC "$r")" = no ]
  [ "$(ps_cell SECRET-CP "$r")" = yes ]
}

@test "pm ps: CONT-HERDR stopped without a core, unavailable where hc is not on PATH" {
  local r
  # containers not made by pm, so no hc serve runs; with PATH=/usr/bin:/bin
  # the exec of pm ps finds no hc, which the image has in /usr/local/bin
  podman run -d --init --userns=keep-id --name "$CTR" "$IMG" sleep infinity >/dev/null
  podman run -d --init --userns=keep-id -e PATH=/usr/bin:/bin --name "$CTR2" "$IMG" \
    sleep infinity >/dev/null
  run --separate-stderr pm ps
  expect_status 0
  r=$(real_row "$CTR") || fail "no row for $CTR in: $output"
  [ "$(ps_cell CONT-HERDR "$r")" = stopped ] || fail "row: $r"
  # no hc on this host's PATH in this test: HOST-HERDR is unavailable
  [ "$(ps_cell HOST-HERDR "$r")" = unavailable ] || fail "row: $r"
  r=$(real_row "$CTR2") || fail "no row for $CTR2 in: $output"
  [ "$(ps_cell CONT-HERDR "$r")" = unavailable ] || fail "row: $r"
}

@test "pm run --hc: the container ends with its core, as after hc server stop; pm start brings the same core back" {
  run --separate-stderr pm run --hc --mount "$DIR" "$IMG"
  expect_status 0
  local core_id i
  core_id=$(running_core_id "$CTR")
  podman exec "$CTR" hc server stop >/dev/null || true
  for (( i = 0; i < 60; i++ )); do
    [[ $(podman container inspect --format '{{.State.Status}}' -- "$CTR") != exited ]] || break
    sleep 0.5
  done
  [ "$(podman container inspect --format '{{.State.Status}}' -- "$CTR")" = exited ] \
    || fail 'the container runs on without its core'
  run --separate-stderr pm start "$CTR"
  expect_status 0
  [ "$output" = "$CTR" ] || fail "output: $output"
  core_running "$CTR"
  [ "$(running_core_id "$CTR")" = "$core_id" ]
}

@test "pm run --hc with an image without hc: the container exits with 127, pm exits 1 and keeps it for pm rm" {
  # the image without hc and herdr-core; teardown removes what remains
  NOHC_IMG=localhost/$NAME:nohc
  podman run --name "$CTR2" --user 0 "$IMG" rm -f /usr/local/bin/hc /usr/local/bin/herdr-core
  podman commit -q "$CTR2" "$NOHC_IMG" >/dev/null
  podman rm -- "$CTR2" >/dev/null
  # podman run succeeds, but hc serve is not found, so the container stops
  run --separate-stderr pm run --hc --mount "$DIR" "$NOHC_IMG"
  expect_status 1
  [[ $stderr == *"error $CTR:/home/vscode/.config/herdr-core/config.toml: "*'can only create exec sessions on running containers'* ]] \
    || fail "stderr: $stderr"
  [ "$(podman container inspect --format '{{.State.Status}} {{.State.ExitCode}}' -- "$CTR")" = 'exited 127' ]
  podman network exists -- "$NET"
  run --separate-stderr pm rm --force "$CTR"
  expect_status 0
  run podman container exists -- "$CTR"
  [ "$status" -ne 0 ]
  run podman network exists -- "$NET"
  [ "$status" -ne 0 ]
  podman rmi -- "$NOHC_IMG" >/dev/null
}
