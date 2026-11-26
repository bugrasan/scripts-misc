#!/usr/bin/env bats
# integration tests for pm run --cm and pm cm with real rootless podman and
# the internet; skipped unless PM_TEST_PODMAN=1 and PM_TEST_NET=1, and
# PM_TEST_CHEZMOI_REPO names a public chezmoi repo to apply:
#   PM_TEST_PODMAN=1 PM_TEST_NET=1 PM_TEST_CHEZMOI_REPO=<site/user/repo> \
#     bats pm/tests/cm-podman.bats
# PM_TEST_IMAGE sets the image, which needs sh and curl (default:
# ghcr.io/bugrasan/devcontainer-base-ai/base:latest); the tests write only
# below BATS_TEST_TMPDIR and remove their containers and networks, also
# when they fail

# shellcheck disable=SC2030,SC2031,SC2016
# SC2030, SC2031: each bats test runs in its own subshell
# SC2016: $HOME expands in the container

load test_helper

setup() {
  [[ ${PM_TEST_PODMAN-} == 1 ]] || skip 'set PM_TEST_PODMAN=1 to run with real rootless podman'
  [[ ${PM_TEST_NET-} == 1 ]] || skip 'set PM_TEST_NET=1: the chezmoi installer and repo need the internet'
  [[ -n ${PM_TEST_CHEZMOI_REPO-} ]] || skip 'set PM_TEST_CHEZMOI_REPO to a public chezmoi repo'
  command -v podman >/dev/null || fail 'podman not found'
  IMG=${PM_TEST_IMAGE:-ghcr.io/bugrasan/devcontainer-base-ai/base:latest}
  NAME=pmcm-t$BATS_TEST_NUMBER-$$-$RANDOM
  DIR=$BATS_TEST_TMPDIR/$NAME
  CTR=pm-$NAME
  NET=$NAME
  mkdir -p -- "$DIR"
}

teardown() {
  [[ -n ${NAME-} ]] || return 0
  podman rm -f -t 0 -- "$CTR" >/dev/null 2>&1 || true
  podman rm -f -t 0 -- "$CTR-2" >/dev/null 2>&1 || true
  podman network rm -- "$NET" >/dev/null 2>&1 || true
}

# applied <container>: chezmoi wrote at least one file into the home, and
# --one-shot left no chezmoi binary and no source state behind
applied() {
  local out
  out=$(podman exec -- "$1" sh -c '
    test ! -e "$HOME/.local/bin/chezmoi" || { echo "chezmoi binary left"; exit 1; }
    test ! -e "$HOME/.local/share/chezmoi" || { echo "source state left"; exit 1; }
    echo ok' 2>&1) || fail "$1: $out"
  [ "$out" = ok ] || fail "$1: $out"
}

@test "pm run --cm applies PM_CHEZMOI_REPO in the container and leaves no chezmoi" {
  PM_CHEZMOI_REPO=$PM_TEST_CHEZMOI_REPO run --separate-stderr pm run --cm --mount "$DIR" "$IMG"
  expect_status 0
  has_line "$output" "ok    chezmoi $PM_TEST_CHEZMOI_REPO applied in $CTR"
  applied "$CTR"
}

@test "pm cm applies the repo to a running container; a bad repo is an error with chezmoi's output" {
  run --separate-stderr pm run --mount "$DIR" "$IMG"
  expect_status 0
  PM_CHEZMOI_REPO=$PM_TEST_CHEZMOI_REPO run --separate-stderr pm cm "$CTR"
  expect_status 0
  applied "$CTR"
  PM_CHEZMOI_REPO=example.invalid/nobody/none run --separate-stderr pm cm "$CTR"
  expect_status 1
  [[ $stderr == "error $CTR: chezmoi example.invalid/nobody/none: "?* ]] || fail "stderr: $stderr"
}
