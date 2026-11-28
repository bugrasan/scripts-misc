#!/usr/bin/env bats
# stub tests for pm version and its alias pm ver (V9-58): both behave like
# pm --version, with their own usage line
# run: bats pm/tests/version.bats

load test_helper

setup() { stub_setup; }

@test "V9-58: pm version, pm ver, and pm --version print the same line" {
  run --separate-stderr pm --version
  expect_status 0
  local want=$output
  [[ $want =~ ^pm\ [0-9]+$ ]] || fail "pm --version: $want"
  local c
  for c in version ver; do
    run --separate-stderr pm "$c"
    expect_status 0
    [ "$output" = "$want" ] || fail "pm $c: $output"
    [ -z "$stderr" ] || fail "pm $c wrote to stderr: $stderr"
  done
}

@test "V9-58: pm version --help and pm ver -h print the usage line, exit 0" {
  local a
  for a in 'version --help' 'version -h' 'ver --help' 'ver -h'; do
    # shellcheck disable=SC2086  # the subcommand and the flag as two words
    run --separate-stderr pm $a
    expect_status 0
    [ "$output" = 'usage: pm version     (alias: pm ver)' ] || fail "pm $a: $output"
  done
  run --separate-stderr pm --version --help
  expect_status 0
  [ "$output" = 'usage: pm --version' ] || fail "pm --version --help: $output"
}

@test "V9-58: other arguments are a usage error, exit 2" {
  local c
  for c in version ver; do
    run --separate-stderr pm "$c" x
    expect_status 2
    [ -z "$output" ] || fail "pm $c x wrote to stdout: $output"
    [ "$stderr" = 'usage: pm version     (alias: pm ver)' ] || fail "pm $c x: $stderr"
  done
  run --separate-stderr pm --version x
  expect_status 2
  [ "$stderr" = 'usage: pm --version' ] || fail "pm --version x: $stderr"
}

@test "V9-58: pm help lists version with its alias and --version" {
  run --separate-stderr pm help
  expect_status 0
  grep -qE '^  version +print the version; alias ver, also --version$' <<<"$output" \
    || fail "pm help lacks version: $output"
  if grep -qE '^  --version ' <<<"$output"; then fail 'pm help keeps the --version line'; fi
}
