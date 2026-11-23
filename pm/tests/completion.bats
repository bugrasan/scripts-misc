#!/usr/bin/env bats
# stub tests for the completion of pm run --hc (H5 of the v8 spec) and of
# pm rm --force (V9-05): the _pm_candidates functions of `pm sh` (bash) and
# `pm zsh` (zsh), called with prepared words; the fake podman answers the
# image and container lists
# run: bats pm/tests/completion.bats

load test_helper

setup() {
  stub_setup
  export STUB_IMAGES=example.org/img:1 STUB_PS=pm-x
}

# lines that both shells must complete alike
CASES=("pm run -" "pm run --hc -" "pm.sh run --mount x --hc img --"
  "pm run --cc --hc --net n1 --h" "pm run --hc ''" "pm run --hc --mount x ''"
  "pm rm -" "pm rm ''" "pm rm pm-x -" "pm.sh rm --force ''" "pm rm -f ''")

# candidates: the candidates in $output (after the kind line), sorted, on
# one line
candidates() { sed 1d <<<"$output" | sort | tr '\n' ' '; }

# rm_completion <bash_candidates|zsh_candidates>: the pm rm checks of V9-05
rm_completion() {
  run --separate-stderr "$1" pm rm -
  expect_status 0
  [ "$(candidates)" = '--force --help ' ] || fail "pm rm -: $(candidates)"
  run --separate-stderr "$1" pm rm pm-x -
  expect_status 0
  [ "$(candidates)" = '--force ' ] || fail "pm rm pm-x -: $(candidates)"
  run --separate-stderr "$1" pm rm --force ''
  expect_status 0
  [ "$(candidates)" = 'pm-x ' ] || fail "pm rm --force: $(candidates)"
  run --separate-stderr "$1" pm rm ''
  expect_status 0
  [ "$(candidates)" = 'pm-x ' ] || fail "pm rm: $(candidates)"
  # -f is no option of pm rm, so no container follows it
  run --separate-stderr "$1" pm rm -f ''
  expect_status 0
  if grep -qxF pm-x <<<"$output"; then fail 'containers offered after -f'; fi
}

@test "V9-05 bash: pm rm completes --force but not -f, and containers after --force" {
  rm_completion bash_candidates
}

@test "V9-05 zsh: pm rm completes --force but not -f, and containers after --force" {
  need_zsh
  rm_completion zsh_candidates
}

@test "H5 bash: pm run offers --hc among the flags" {
  run --separate-stderr bash_candidates pm run -
  expect_status 0
  has_line "$output" kind=words
  has_line "$output" --hc
  has_line "$output" --cc
  has_line "$output" --mount
}

@test "H5 bash: --hc is not offered again once it is on the line" {
  local words
  for words in 'pm run --hc -' 'pm.sh run --mount x --hc img --' 'pm run --cc --hc --net n1 --h'; do
    # shellcheck disable=SC2086  # split the words on purpose
    run --separate-stderr bash_candidates $words
    expect_status 0
    if grep -qxF -- --hc <<<"$output"; then fail "--hc offered for: $words"; fi
    has_line "$output" --help
  done
}

@test "H5 bash: --hc does not count as the image" {
  run --separate-stderr bash_candidates pm run --hc ''
  expect_status 0
  has_line "$output" kind=words
  has_line "$output" example.org/img:1
}

@test "H5 zsh: pm run offers --hc among the flags" {
  need_zsh
  run --separate-stderr zsh_candidates pm run -
  expect_status 0
  has_line "$output" kind=words
  has_line "$output" --hc
  has_line "$output" --cc
  has_line "$output" --mount
}

@test "H5 zsh: --hc is not offered again once it is on the line" {
  need_zsh
  local words
  for words in 'pm run --hc -' 'pm.sh run --mount x --hc img --' 'pm run --cc --hc --net n1 --h'; do
    # shellcheck disable=SC2086  # split the words on purpose
    run --separate-stderr zsh_candidates $words
    expect_status 0
    if grep -qxF -- --hc <<<"$output"; then fail "--hc offered for: $words"; fi
    has_line "$output" --help
  done
}

@test "H5 zsh: --hc does not count as the image" {
  need_zsh
  run --separate-stderr zsh_candidates pm run --hc ''
  expect_status 0
  has_line "$output" kind=words
  has_line "$output" example.org/img:1
}

@test "H5, V9-05: bash and zsh return the same candidates for pm run and pm rm lines" {
  need_zsh
  local c a b
  local -a w
  for c in "${CASES[@]}"; do
    eval "w=($c)"
    a=$(bash_candidates "${w[@]}" | sort)
    b=$(zsh_candidates "${w[@]}" | sort)
    [ "$a" = "$b" ] || fail "differ for: $c" "--- bash" "$a" "--- zsh" "$b"
  done
}
