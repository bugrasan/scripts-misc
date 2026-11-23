#!/usr/bin/env bats
# stub tests for pm rm and its long-form option --force (pm v9): a fake
# podman logs every call and HOME is a per-test folder; the V numbers are
# the items of the v9 section in pm-backlog.md; pm's own podman call keeps
# podman's short -f, as in v8
# run: bats pm/tests/rm.bats

load test_helper

setup() {
  stub_setup
  # a running container pm-x on the pm network x; stub_setup sets STUB_STATE
  # shellcheck disable=SC2153
  printf '%s\n' x >"$STUB_STATE/containers/pm-x"
  : >"$STUB_STATE/networks/x"
}

@test "V9-05: pm rm --force removes a running container, then its network" {
  run --separate-stderr pm rm --force pm-x
  expect_status 0
  podman_find -x rm -f -- pm-x
  podman_find -x network rm -- x
  has_line "$output" 'ok    container pm-x removed'
  has_line "$output" 'ok    network x removed'
}

@test "V9-05: --force also works after the container" {
  run --separate-stderr pm rm pm-x --force
  expect_status 0
  podman_find -x rm -f -- pm-x
}

@test "V9-05: pm rm rejects -f like any unknown option: usage to stderr, exit 2" {
  local help args
  help=$(pm rm --help)
  for args in '-f pm-x' 'pm-x -f'; do
    # shellcheck disable=SC2086  # split the argument string on purpose
    run --separate-stderr pm rm $args
    expect_status 2
    [ "$stderr" = "$help" ] || fail "stderr for pm rm $args: $stderr"
    [ -z "$output" ]
  done
  [ ! -s "$PODMAN_LOG" ] || { podman_show; fail 'podman was called'; }
}

@test "V9-05: a running container without --force is refused with a --force hint" {
  run --separate-stderr pm rm pm-x
  expect_status 1
  has_line "$stderr" 'error container pm-x is running; stop it with: pm stop pm-x, or use: pm rm --force pm-x'
  if podman_find rm; then fail 'pm removed the container'; fi
}

@test "V9-05: a stopped container needs no --force, and podman rm gets no -f" {
  export STUB_STATUS=exited
  run --separate-stderr pm rm pm-x
  expect_status 0
  podman_find -x rm -- pm-x
}

@test "V9-05: pm rm --help, pm help, and pm readme show --force and no -f" {
  run pm rm --help
  expect_status 0
  [ "${lines[0]}" = 'usage: pm rm [--force] <container>' ]
  has_line "$output" '  --force      stop a running container first'
  # the podman call itself keeps podman's -f
  has_line "$output" 'runs: podman rm [-f] <container>'
  run pm help
  expect_status 0
  has_line "$output" '  rm         [--force] <container>  remove it and its pm network once unused'
  run pm readme
  expect_status 0
  [[ $output == *'pm rm --force pm-myapp'* ]] || fail 'the readme lacks pm rm --force'
  # no -f as an option of pm rm itself
  local args
  for args in 'rm --help' help readme; do
    # shellcheck disable=SC2086  # split the argument string on purpose
    run pm $args
    if grep -nE -- '(^|[^[:alnum:]])pm rm \[?-f|-f, --force|-f \| --force|^ *-f ' <<<"$output"; then
      fail "pm $args shows -f as a pm rm option"
    fi
  done
}
