#!/usr/bin/env bats
# stub tests for the completion of pm run --hc (H5 of the v8 spec): the
# _pm_candidates functions of `pm sh` (bash) and `pm zsh` (zsh), called
# with prepared words; the fake podman answers the image list
# run: bats pm/tests/completion.bats

load test_helper

setup() {
  stub_setup
  export STUB_IMAGES=example.org/img:1
}

# lines of pm run that both shells must complete alike
CASES=("pm run -" "pm run --hc -" "pm.sh run --mount x --hc img --"
  "pm run --cc --hc --net n1 --h" "pm run --hc ''" "pm run --hc --mount x ''")

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

@test "H5: bash and zsh return the same candidates for pm run lines" {
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
