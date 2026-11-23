#!/usr/bin/env bats
# integration tests for pm run --hc with real rootless podman; skipped
# unless PM_TEST_PODMAN=1:
#   PM_TEST_PODMAN=1 bats pm/tests/run-hc-podman.bats
# PM_TEST_IMAGE sets the image, which must have hc on its PATH (default:
# ghcr.io/bugrasan/devcontainer-base-ai/base:latest); needs python3
# the tests write only below BATS_TEST_TMPDIR and to
# $HOME/.config/herdr-core/container/<unique-name>-*, and remove their
# containers, networks, and state folders also when they fail; pm itself
# also creates $HOME/.config/herdr-core/container in the real HOME when it
# is missing and sets $HOME/.config/herdr-core to mode 700, as it does for
# every pm run --hc; the tests leave both in place
# the hc machine test uses the image's own hc as the host's hc, with a host
# core of its own (state and socket below BATS_TEST_TMPDIR) that teardown
# stops; the other tests run without hc on PATH

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
  mkdir -p -- "$DIR"
}

teardown() {
  [[ -n ${NAME-} ]] || return 0
  # the isolated host core of the machine test
  if (( HOST_HC )); then hc server stop >/dev/null 2>&1 || true; fi
  podman rm -f -t 0 -- "$CTR" >/dev/null 2>&1 || true
  podman rm -f -t 0 -- "$CTR2" >/dev/null 2>&1 || true
  podman rm -f -t 0 -- "$CTR2-2" >/dev/null 2>&1 || true
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

# hc_serve_running <container>: wait up to 30 s for a process `hc serve`
hc_serve_running() {
  local i
  for (( i = 0; i < 60; i++ )); do
    if { podman top "$1" args 2>/dev/null
      podman exec "$1" sh -c 'for f in /proc/[0-9]*/cmdline; do tr "\000" " " <"$f"; echo; done' 2>/dev/null
    } | grep -Eq '(^|[[:space:]/])hc serve( |$)'; then
      return 0
    fi
    sleep 0.5
  done
  podman top "$1" args >&2 || true
  fail "no hc serve process in $1"
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

# hc_serve_shell <container>: SHELL in the environment of the running
# hc serve process, from /proc/<pid>/environ inside the container
hc_serve_shell() {
  podman exec "$1" sh -c '
    for p in /proc/[0-9]*; do
      [ "$(tr "\000" " " <"$p/cmdline" 2>/dev/null)" = "hc serve " ] || continue
      tr "\000" "\n" <"$p/environ" | sed -n "s/^SHELL=//p"
      exit 0
    done
    exit 1'
}

@test "pm run --hc: mounts, hc serve, core.json; the identity survives pm rm --force" {
  run --separate-stderr pm run --hc --mount "$DIR" "$IMG"
  expect_status 0
  has_line "$output" "ok    hc serve started in $CTR"
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

  hc_serve_running "$CTR"
  # podman sets no SHELL; pm passes it, as the core starts new shells from it
  local shell
  shell=$(hc_serve_shell "$CTR") || fail 'cannot read the environment of hc serve'
  [ "$shell" = /bin/bash ] || fail "hc serve runs with SHELL=$shell"
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
  hc_serve_running "$CTR"
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
  hc_serve_running "$CTR"
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
  local err=$stderr line
  run podman container exists -- "$CTR2"
  [ "$status" -ne 0 ]
  # the example creates a plain second container as printed
  line=$(grep -m1 '^  podman run ' <<<"$err") || fail "no example in: $err"
  eval "$line" >/dev/null
  podman container exists -- "$CTR2-2"
}

@test "pm run --hc adds a real hc machine; pm start brings hc serve back; pm rm --force drops the machine" {
  use_host_hc
  run --separate-stderr pm run --hc --mount "$DIR" "$IMG"
  expect_status 0
  has_line "$output" "ok    hc machine $CTR added"
  [ "$(host_machine "$CTR")" = "$(command -v podman) exec -i $CTR sh -c True" ] \
    || fail "machine: $(hc machine ls --json)"
  # hc on the host reaches the container through the via connection
  run --separate-stderr hc exec --on "$CTR" uname -a
  expect_status 0
  [[ $output == Linux* ]] || fail "uname: $output"

  # pm start brings the core back, with SHELL=/bin/bash
  run --separate-stderr pm stop "$CTR"
  expect_status 0
  run --separate-stderr pm start "$CTR"
  expect_status 0
  has_line "$output" "ok    hc serve started in $CTR"
  hc_serve_running "$CTR"
  local shell
  shell=$(hc_serve_shell "$CTR") || fail 'cannot read the environment of hc serve'
  [ "$shell" = /bin/bash ] || fail "hc serve runs with SHELL=$shell"

  # pm rm --force removes the container and its machine
  run --separate-stderr pm rm --force "$CTR"
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
