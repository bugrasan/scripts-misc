#!/usr/bin/env bats
# stub tests for one container per folder (pm v9, owner decision D23): with
# --mount, pm refuses a folder (with --hc, also a herdr-core state folder)
# that a podman container already bind-mounts; a fake podman logs every call
# run: bats pm/tests/one-folder.bats

load test_helper

setup() { stub_setup; }

IMG=example.org/img:1

# example <abs> <base> <name>: the podman run line pm suggests instead
example() {
  printf '  podman run -d --init --userns=keep-id -v %q --name %q %q sleep infinity' \
    "$1:/workspaces/$2" "$3" "$IMG"
}

@test "D23: a folder that a podman container mounts gets no second container, with a runnable example" {
  fake_container devc '' /elsewhere "$P"
  run --separate-stderr pm run --mount "$P" "$IMG"
  expect_status 1
  has_line "$stderr" "error the folder $P is already mounted by: devc; pm does not support a second container on the same folder, for consistency reasons"
  [[ $stderr == *'run podman yourself'* ]] || fail "stderr: $stderr"
  has_line "$stderr" "$(example "$P" proj pm-proj-2)"
  no_create
  # the example runs as printed
  local line
  line=$(grep -m1 '^  podman run ' <<<"$stderr")
  : >"$PODMAN_LOG"
  eval "$line"
  podman_find -x run -d --init --userns=keep-id -v "$P:/workspaces/proj" --name pm-proj-2 "$IMG" sleep infinity
}

@test "D23: every container that mounts the folder is named, and the given name goes into the example" {
  fake_container a '' "$P"
  fake_container b '' "$P"
  run --separate-stderr pm run --mount "$P" "$IMG" mine
  expect_status 1
  has_line "$stderr" "error the folder $P is already mounted by: a, b; pm does not support a second container on the same folder, for consistency reasons"
  has_line "$stderr" "$(example "$P" proj mine-2)"
}

@test "D23: paths with spaces and quotes are quoted in the example" {
  local dir="$T/my 'proj'"
  mkdir -p "$dir"
  fake_container x '' "$dir"
  run --separate-stderr pm run --mount "$dir" "$IMG" c1
  expect_status 1
  has_line "$stderr" "$(example "$dir" "my 'proj'" c1-2)"
  local line
  line=$(grep -m1 '^  podman run ' <<<"$stderr")
  : >"$PODMAN_LOG"
  eval "$line"
  podman_find -x run -d --init --userns=keep-id -v "$dir:/workspaces/my 'proj'" --name c1-2 "$IMG" sleep infinity
}

@test "D23: with --hc, a container that mounts the state folder counts, and pm writes nothing" {
  need_python
  local id=0123456789abcdef0123456789abcdef state
  printf '%s\n' "$id" >"$P/herdr-machine-id"
  state=$HC/proj-$(sha256_hex "$id")
  fake_container other '' "$state"
  run --separate-stderr pm run --hc --mount "$P" "$IMG"
  expect_status 1
  has_line "$stderr" "error the folder $P or its herdr-core state folder is already mounted by: other; pm does not support a second container on the same folder, for consistency reasons"
  [[ ! -e $HOME/.config/herdr-core ]]
  [ "$(ls -A "$P")" = herdr-machine-id ]
  no_create
  [ ! -s "$HC_LOG" ] || { hc_show; fail 'hc was called'; }
}

@test "D23: the dev container's state folder counts as well, before an id file exists" {
  need_node
  mkdir "$P/.devcontainer"
  fake_container devc '' "$HC/proj-$(ref_id "$P")"
  run --separate-stderr pm run --hc --mount "$P" "$IMG"
  expect_status 1
  [[ $stderr == *'already mounted by: devc;'* ]] || fail "stderr: $stderr"
  [ -z "$(ls -A "$P/.devcontainer")" ]
  no_create
}

@test "D23: other paths do not count, and one inspect call covers all containers" {
  fake_container a '' "$T/other"
  fake_container b '' "$P/sub" "/x$P"
  run --separate-stderr pm run --mount "$P" "$IMG"
  expect_status 0
  local i n=0
  podman_load
  for (( i = 0; i < ${#CALLS[@]}; i++ )); do
    podman_call "$i"
    [[ ${CALL[0]} == container && ${CALL[1]} == inspect && ${CALL[3]} == *.Mounts* ]] || continue
    n=$((n + 1))
    [ "${CALL[*]:4}" = 'a b' ] || fail "inspected: ${CALL[*]:4}"
  done
  [ "$n" -eq 1 ] || { podman_show; fail "$n mount inspections"; }
}

@test "D23: without --mount, pm looks at no other container" {
  run --separate-stderr pm run "$IMG" name1
  expect_status 0
  if podman_find ps -a -q; then podman_show; fail 'pm listed containers'; fi
}
