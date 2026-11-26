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
  "pm rm -" "pm rm ''" "pm rm pm-x -" "pm.sh rm --force ''" "pm rm -f ''"
  "pm rm --hc-rm -" "pm rm --force pm-x --hc-rm -" "pm rm --hc-rm --force ''" "pm rm pm-x --hc-rm ''"
  "pm rm --help -" "pm rm --help ''"
  "pm ''" "pm hc-add ''" "pm hc-rm -" "pm doctor ''" "pm ps -" "pm ps -a -" "pm ps --agents -")

# candidates: the candidates in $output (after the kind line), sorted, on
# one line
candidates() { sed 1d <<<"$output" | LC_ALL=C sort | tr '\n' ' '; }

# rm_completion <bash_candidates|zsh_candidates>: the pm rm checks of V9-05
rm_completion() {
  run --separate-stderr "$1" pm rm -
  expect_status 0
  [ "$(candidates)" = '--force --hc-rm --help ' ] || fail "pm rm -: $(candidates)"
  run --separate-stderr "$1" pm rm pm-x -
  expect_status 0
  [ "$(candidates)" = '--force --hc-rm ' ] || fail "pm rm pm-x -: $(candidates)"
  # V9-53: each flag once, in any position, and one container
  run --separate-stderr "$1" pm rm --hc-rm -
  expect_status 0
  [ "$(candidates)" = '--force ' ] || fail "pm rm --hc-rm -: $(candidates)"
  run --separate-stderr "$1" pm rm --force pm-x --hc-rm -
  expect_status 0
  [ "$(candidates)" = '' ] || fail "pm rm --force pm-x --hc-rm -: $(candidates)"
  run --separate-stderr "$1" pm rm --hc-rm --force ''
  expect_status 0
  [ "$(candidates)" = 'pm-x ' ] || fail "pm rm --hc-rm --force: $(candidates)"
  run --separate-stderr "$1" pm rm pm-x --hc-rm ''
  expect_status 0
  [ "$(candidates)" = '' ] || fail "pm rm pm-x --hc-rm: $(candidates)"
  # F1-12: nothing follows --help
  run --separate-stderr "$1" pm rm --help -
  expect_status 0
  [ "$(candidates)" = '' ] || fail "pm rm --help -: $(candidates)"
  run --separate-stderr "$1" pm rm --help ''
  expect_status 0
  [ "$(candidates)" = '' ] || fail "pm rm --help: $(candidates)"
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

# v9_completion <bash_candidates|zsh_candidates>: hc-add, hc-rm, doctor,
# and pm ps --agents
v9_completion() {
  # the fake podman lists the fake containers themselves
  unset STUB_PS
  fake_container up pm-up
  fake_container down pm-down
  printf 'exited\n' >"$STUB_STATE/status/down"
  fake_container plain
  run --separate-stderr "$1" pm ''
  expect_status 0
  has_line "$output" hc-add
  has_line "$output" hc-rm
  has_line "$output" doctor
  # V9-50, V9-51: hc-add offers every running container, hc-rm every
  # container, labeled or not
  run --separate-stderr "$1" pm hc-add ''
  expect_status 0
  [ "$(candidates)" = 'plain up ' ] || fail "pm hc-add: $(candidates)"
  run --separate-stderr "$1" pm hc-rm ''
  expect_status 0
  [ "$(candidates)" = 'down plain up ' ] || fail "pm hc-rm: $(candidates)"
  if podman_find ps; then
    [[ " ${CALLS[*]} " != *label=pm-hc* ]] || fail 'completion filters by the pm-hc label'
  fi
  # doctor takes no arguments, only --help
  run --separate-stderr "$1" pm doctor ''
  expect_status 0
  has_line "$output" kind=none
  run --separate-stderr "$1" pm doctor -
  expect_status 0
  [ "$(candidates)" = '--help ' ] || fail "pm doctor -: $(candidates)"
  # ps: --agents, and the other flags after one of them
  run --separate-stderr "$1" pm ps -
  expect_status 0
  [ "$(candidates)" = '--agents --all --help -a ' ] || fail "pm ps -: $(candidates)"
  run --separate-stderr "$1" pm ps -a -
  expect_status 0
  [ "$(candidates)" = '--agents ' ] || fail "pm ps -a -: $(candidates)"
  run --separate-stderr "$1" pm ps --agents -
  expect_status 0
  [ "$(candidates)" = '--all -a ' ] || fail "pm ps --agents -: $(candidates)"
}

@test "v9 bash: hc-add, hc-rm, doctor, and pm ps --agents complete" {
  v9_completion bash_candidates
}

@test "v9 zsh: hc-add, hc-rm, doctor, and pm ps --agents complete" {
  need_zsh
  v9_completion zsh_candidates
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
