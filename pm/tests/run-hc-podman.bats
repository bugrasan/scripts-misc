#!/usr/bin/env bats
# integration tests for pm run --hc with real rootless podman; skipped
# unless PM_TEST_PODMAN=1:
#   PM_TEST_PODMAN=1 bats pm/tests/run-hc-podman.bats
# PM_TEST_IMAGE sets the image, which must have hc on its PATH (default:
# ghcr.io/bugrasan/devcontainer-base-ai/base:latest); needs python3
# the tests write only below BATS_TEST_TMPDIR and to
# $HOME/.config/herdr-core/container/<unique-name>-*, and remove their
# containers, networks, and state folders also when they fail

load test_helper

setup() {
  [[ ${PM_TEST_PODMAN-} == 1 ]] || skip 'set PM_TEST_PODMAN=1 to run with real rootless podman'
  command -v podman >/dev/null || fail 'podman not found'
  need_python
  IMG=${PM_TEST_IMAGE:-ghcr.io/bugrasan/devcontainer-base-ai/base:latest}
  # unique per test and run: the folder names the container and network
  NAME=pmhc-t$BATS_TEST_NUMBER-$$-$RANDOM
  DIR=$BATS_TEST_TMPDIR/$NAME
  CTR=pm-$NAME
  NET=$NAME
  HC=$HOME/.config/herdr-core/container
  mkdir -p -- "$DIR"
}

teardown() {
  [[ -n ${NAME-} ]] || return 0
  podman rm -f -t 0 -- "$CTR" >/dev/null 2>&1 || true
  podman network rm -- "$NET" >/dev/null 2>&1 || true
  local d
  for d in "$HC/$NAME"-*; do
    [[ -e $d ]] || continue
    # files the container wrote as another user need podman unshare
    rm -rf -- "$d" 2>/dev/null || podman unshare rm -rf -- "$d" || true
  done
}

# core_ids <state> [<newer-than>]: wait up to 30 s for a core.json below
# <state>, newer than the file <newer-than> when given, that has machine_id
# and id; print "<machine_id> <id>"
core_ids() {
  local state=$1 i f out
  local -a newer=()
  [[ -z ${2-} ]] || newer=(-newer "$2")
  for (( i = 0; i < 60; i++ )); do
    while IFS= read -r f; do
      if out=$(python3 -I -c 'import json, sys
d = json.load(open(sys.argv[1]))
print(d["machine_id"], d["id"])' "$f" 2>/dev/null); then
        printf '%s\n' "$out"
        return 0
      fi
    done < <(find "$state" -name core.json "${newer[@]}" 2>/dev/null)
    sleep 0.5
  done
  printf 'no usable core.json below %s after 30 s:\n' "$state" >&2
  find "$state" -ls >&2 || true
  find "$state" -name core.json -exec cat {} + >&2 || true
  return 1
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

@test "pm run --hc: mounts, hc serve, core.json; the identity survives pm rm -f" {
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
  ids=$(core_ids "$state")
  read -r mid core_id <<<"$ids"
  [ "$mid" = "$id" ] || fail "machine_id $mid, id file $id"
  [ -n "$core_id" ]

  # pm rm -f keeps the id file and the state folder; a second run reuses them
  run --separate-stderr pm rm -f "$CTR"
  expect_status 0
  [ "$(<"$f")" = "$id" ]
  [[ -d $state ]]
  touch -- "$BATS_TEST_TMPDIR/second-run"
  run --separate-stderr pm run --hc --mount "$DIR" "$IMG"
  expect_status 0
  [[ $stderr != *'new herdr-core state folder'* ]] || fail "$stderr"
  hc_serve_running "$CTR"
  ids=$(core_ids "$state" "$BATS_TEST_TMPDIR/second-run")
  read -r mid core_id2 <<<"$ids"
  [ "$mid" = "$id" ]
  [ "$core_id2" = "$core_id" ] || fail "core id changed: $core_id -> $core_id2"
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
