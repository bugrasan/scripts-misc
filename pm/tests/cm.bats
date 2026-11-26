#!/usr/bin/env bats
# stub tests for pm run --cm and pm cm (pm v9): the chezmoi one-shot runs
# inside the container, with the repo of PM_CHEZMOI_REPO as an argument,
# before the --cc and --cp copies; a fake podman logs every call
# run: bats pm/tests/cm.bats
# shellcheck disable=SC2030,SC2031,SC2016
# SC2030, SC2031: each bats test runs in its own subshell
# SC2016: the in-container script is matched as literal text

load test_helper

setup() {
  stub_setup
  unset PM_CHEZMOI_REPO
  export PM_CLAUDE_MD=$T/claude.md PM_CLAUDE_SETTINGS=$T/none.json \
    PM_COPILOT_SETTINGS=$T/none.json PM_COPILOT_CONFIG=$T/none.json \
    STUB_SECRETS='cc_token cp_token'
  printf 'rules\n' >"$PM_CLAUDE_MD"
}

IMG=example.org/img:1
DEFAULT_REPO=codeberg.org/bugrasan/dotfiles

# cm_call <container>: the last chezmoi exec into <container>; sets FOUND
# and CALL, SCRIPT to the script after -c
cm_call() {
  local i
  podman_load
  for (( i = ${#CALLS[@]} - 1; i >= 0; i-- )); do
    podman_call "$i"
    [[ ${CALL[0]} == exec && " ${CALL[*]} " == *" -- $1 sh -c "* \
      && ${CALL[*]} == *get.chezmoi.io/lb* ]] || continue
    FOUND=$i
    local k
    for (( k = 0; k < ${#CALL[@]}; k++ )); do
      [[ ${CALL[k]} != -c ]] || { SCRIPT=${CALL[k+1]}; break; }
    done
    return 0
  done
  return 1
}

# the text of readme section $2 in $1: from its heading to the next one
readme_section() {
  local s=${1#*$'\n'"$2"$'\n'}
  printf '%s\n' "${s%%$'\n'[A-Z]*}"
}

@test "C7: pm run --cm runs the chezmoi one-shot in the container with the default repo" {
  run --separate-stderr pm run --cm --mount "$P" "$IMG"
  expect_status 0
  cm_call pm-proj || { podman_show; fail 'no chezmoi exec'; }
  # the repo is the last argument, after the script and its $0
  [ "${CALL[${#CALL[@]}-1]}" = "$DEFAULT_REPO" ]
  [ "${CALL[${#CALL[@]}-2]}" = sh ]
  has_line "$output" "ok    chezmoi $DEFAULT_REPO applied in pm-proj"
}

@test "CMF1-02: the real script runs: the installer from curl gets init --one-shot --apply -- <repo>, in the home" {
  local repo='example.org/u/dots"; touch pwned; echo "' h=$STUB_STATE/fs/pm-proj/home/vscode
  PM_CHEZMOI_REPO=$repo run --separate-stderr pm run --cm --mount "$P" "$IMG"
  expect_status 0
  [ "$(cat "$h/installer-args")" = "$(printf '%s\n' init --one-shot --apply -- "$repo")" ] \
    || fail "installer args: $(cat "$h/installer-args")"
  [ "$(cat "$h/installer-pwd")" = "$h" ] || fail "installer ran in: $(cat "$h/installer-pwd")"
  [[ ! -e $h/pwned && ! -e /pwned ]] || fail 'the repo ran as script text'
  has_line "$output" "ok    chezmoi $repo applied in pm-proj"
}

@test "CMF1-02: the home of the container user, not /home/vscode" {
  fake_container box
  fake_home box /root
  run --separate-stderr pm cm box
  expect_status 0
  [ "$(cat "$STUB_STATE/fs/box/root/installer-pwd")" = "$STUB_STATE/fs/box/root" ]
}

@test "CMF1-01: a failing curl is an error with its output, exit 1, and no installer runs" {
  STUB_CM_CURL=fail run --separate-stderr pm run --cm --mount "$P" "$IMG"
  expect_status 1
  has_line "$stderr" "error pm-proj: chezmoi $DEFAULT_REPO failed with exit 6; its last output:"
  has_line "$stderr" '      curl: (6) Could not resolve host: get.chezmoi.io/lb'
  [[ ! -e $STUB_STATE/fs/pm-proj/home/vscode/installer-args ]] || fail 'the installer ran'
  [[ $output != *'ok    chezmoi'* ]] || fail "output: $output"
}

@test "CMF1-01: without curl in the container, an error, exit 1" {
  fake_container box
  STUB_CM_CURL=missing run --separate-stderr pm cm box
  expect_status 1
  has_line "$stderr" "error box: chezmoi $DEFAULT_REPO failed with exit 127; its last output:"
  [[ $stderr == *curl*'not found'* ]] || fail "stderr: $stderr"
}

@test "CMF1-07: a failing installer shows its last 20 output lines, indented, one per line" {
  fake_container box
  STUB_CM_INSTALL_RC=3 STUB_CM_INSTALL_LINES=25 run --separate-stderr pm cm box
  expect_status 1
  [ "${stderr%%$'\n'*}" = "error box: chezmoi $DEFAULT_REPO failed with exit 3; its last output:" ] \
    || fail "stderr: $stderr"
  local i
  for (( i = 6; i <= 25; i++ )); do has_line "$stderr" "      line $i"; done
  [[ $stderr != *'line 5'$'\n'* ]] || fail "more than 20 lines: $stderr"
  [ "$(wc -l <<<"$stderr")" -eq 21 ] || fail "stderr: $stderr"
}

@test "C7: the script fetches the installer inside the container, from the home, as the user asked" {
  run --separate-stderr pm run --cm --mount "$P" "$IMG"
  expect_status 0
  cm_call pm-proj || { podman_show; fail 'no chezmoi exec'; }
  [ "$SCRIPT" = 'cd "$HOME" && s=$(curl -fsLS get.chezmoi.io/lb) && sh -c "$s" -- init --one-shot --apply -- "$1"' ] \
    || fail "script: $SCRIPT"
  # podman exec, so curl runs in the container, never on the host
  [ "${CALL[0]}" = exec ]
}

@test "C8: PM_CHEZMOI_REPO picks the repo; it reaches the container as an argument, not as script text" {
  local repo='example.org/u/dots"; touch /tmp/pwned; echo "'
  PM_CHEZMOI_REPO=$repo run --separate-stderr pm run --cm --mount "$P" "$IMG"
  expect_status 0
  cm_call pm-proj || { podman_show; fail 'no chezmoi exec'; }
  [ "${CALL[${#CALL[@]}-1]}" = "$repo" ]
  [[ $SCRIPT != *pwned* && $SCRIPT != *example.org* ]] || fail "repo in the script: $SCRIPT"
}

@test "D13: pm run --cm --cc --cp --hc: chezmoi first, then the copies, then the hc config" {
  run --separate-stderr pm run --hc --cp --cc --cm --mount "$P" "$IMG"
  expect_status 0
  local r cm cc cp hc
  podman_find run
  r=$FOUND
  cm_call pm-proj || { podman_show; fail 'no chezmoi exec'; }
  cm=$FOUND
  podman_find -x cp -- "$PM_CLAUDE_MD" pm-proj:/home/vscode/.claude/CLAUDE.md
  cc=$FOUND
  podman_find -x cp -- "$PM_CLAUDE_MD" pm-proj:/home/vscode/.copilot/copilot-instructions.md
  cp=$FOUND
  podman_find exec -i -- pm-proj sh -c || { podman_show; fail 'no config write'; }
  hc=$FOUND
  (( r < cm && cm < cc && cc < cp && cp < hc )) \
    || { podman_show; fail "order: run $r, chezmoi $cm, cc $cc, cp $cp, config $hc"; }
}

@test "D15: a failed chezmoi step is an error with its output; the later steps run, exit 1, the container stays" {
  STUB_CM_CURL=fail run --separate-stderr pm run --cm --cc --mount "$P" "$IMG"
  expect_status 1
  has_line "$stderr" "error pm-proj: chezmoi $DEFAULT_REPO failed with exit 6; its last output:"
  podman_find -x cp -- "$PM_CLAUDE_MD" pm-proj:/home/vscode/.claude/CLAUDE.md \
    || { podman_show; fail 'no --cc copy after the failed chezmoi step'; }
  if podman_find rm; then podman_show; fail 'pm removed the container'; fi
}

@test "C7: --cm in any position before --, repeated, runs chezmoi once; without --cm, no chezmoi" {
  run --separate-stderr pm run --mount "$P" "$IMG" --cm c1 --cm
  expect_status 0
  cm_call c1 || { podman_show; fail 'no chezmoi exec'; }
  local n
  n=$(grep -c 'get.chezmoi.io/lb' "$PODMAN_LOG")
  [ "$n" -eq 1 ] || fail "chezmoi ran $n times"
  forget_containers
  : >"$PODMAN_LOG"
  run --separate-stderr pm run --mount "$P" "$IMG" c2
  expect_status 0
  if grep -q 'get.chezmoi.io' "$PODMAN_LOG"; then podman_show; fail 'chezmoi without --cm'; fi
}

@test "CMF1-10: after --, --cm is the container name, not the flag" {
  run --separate-stderr pm run "$IMG" -- --cm
  run_args
  has_opt --name --cm || { podman_show; fail 'no --name --cm'; }
  if grep -q 'get.chezmoi.io' "$PODMAN_LOG"; then podman_show; fail 'chezmoi after --'; fi
}

@test "D14: pm cm <container> runs the one-shot in a running container, by name or ID" {
  fake_container box
  fake_id 0123abcd box
  run --separate-stderr pm cm box
  expect_status 0
  cm_call box || { podman_show; fail 'no chezmoi exec'; }
  [ "${CALL[${#CALL[@]}-1]}" = "$DEFAULT_REPO" ]
  has_line "$output" "ok    chezmoi $DEFAULT_REPO applied in box"
  : >"$PODMAN_LOG"
  PM_CHEZMOI_REPO=example.org/u/d run --separate-stderr pm cm 0123abcd
  expect_status 0
  cm_call box || { podman_show; fail 'no chezmoi exec into the name of the ID'; }
  [ "${CALL[${#CALL[@]}-1]}" = example.org/u/d ]
  has_line "$output" 'ok    chezmoi example.org/u/d applied in box'
}

@test "D14: pm cm on a stopped or missing container is an error and runs nothing" {
  fake_container box
  printf 'exited\n' >"$STUB_STATE/status/box"
  run --separate-stderr pm cm box
  expect_status 1
  has_line "$stderr" 'error container box is exited; start it with: pm start box'
  if grep -q 'get.chezmoi.io' "$PODMAN_LOG"; then podman_show; fail 'chezmoi on a stopped container'; fi
  run --separate-stderr pm cm nope
  expect_status 1
  [[ $stderr == 'error container nope: '* ]] || fail "stderr: $stderr"
}

@test "D14: pm cm with a failing one-shot is an error with its output, exit 1" {
  fake_container box
  STUB_CM_CURL=fail run --separate-stderr pm cm box
  expect_status 1
  has_line "$stderr" "error box: chezmoi $DEFAULT_REPO failed with exit 6; its last output:"
  has_line "$stderr" '      curl: (6) Could not resolve host: get.chezmoi.io/lb'
}

@test "D14: pm cm usage errors exit 2; --help names the command and PM_CHEZMOI_REPO" {
  local a
  for a in '' '-x' 'a b'; do
    # shellcheck disable=SC2086  # split the words on purpose
    run --separate-stderr pm cm $a
    expect_status 2
    [[ $stderr == 'usage: pm cm <container>'* ]] || fail "pm cm $a: $stderr"
  done
  run --separate-stderr pm cm --help
  expect_status 0
  [ "${lines[0]}" = 'usage: pm cm <container>' ]
  [[ $output == *PM_CHEZMOI_REPO* && $output == *get.chezmoi.io/lb* && $output == *--one-shot* ]] \
    || fail "help: $output"
  # CMF1-10: --help anywhere, and nothing runs
  fake_container box
  run --separate-stderr pm cm box --help
  expect_status 0
  [ "${lines[0]}" = 'usage: pm cm <container>' ]
  if grep -q 'get.chezmoi.io' "$PODMAN_LOG"; then podman_show; fail 'chezmoi with --help'; fi
}

@test "CMF1-06: the runs: line of pm cm --help and the readme pass the repo as an argument" {
  local want='s=$(curl -fsLS get.chezmoi.io/lb) && sh -c "$s" -- init --one-shot --apply -- "$1"'
  run --separate-stderr pm cm --help
  expect_status 0
  [[ $output == *"$want"* && $output == *"' sh <repo>"* ]] || fail "help: $output"
  run pm readme
  expect_status 0
  local sec
  sec=$(readme_section "$output" CHEZMOI)
  [[ $sec == *"$want"* && $sec == *"' sh <repo>"* ]] || fail "readme: $sec"
}

@test "C9: pm run --help has a --cm line and stays short; pm help lists cm and PM_CHEZMOI_REPO" {
  run --separate-stderr pm run --help
  expect_status 0
  grep -qE '^  --cm +[a-z]' <<<"$output" || fail "no --cm line: $output"
  (( ${#lines[@]} <= 25 )) || fail "pm run --help has ${#lines[@]} lines"
  run pm help
  expect_status 0
  grep -qE '^  cm +<container> ' <<<"$output" || fail "pm help lacks cm: $output"
  [[ $output == *'[--cm]'* ]] || fail "pm help run line lacks [--cm]"
  [[ $output == *'environment: '*PM_CHEZMOI_REPO* ]] || fail "pm help: $output"
}

@test "C9: the readme has a CHEZMOI section, the run steps, and PM_CHEZMOI_REPO in the table" {
  PM_CHEZMOI_REPO=example.org/u/d run pm readme
  expect_status 0
  local sec s
  sec=$(readme_section "$output" CHEZMOI)
  for s in 'pm run --cm' 'pm cm <container>' 'inside the container' get.chezmoi.io/lb \
    '--one-shot' '--force' 'overwrite' 'before the --cc and --cp copies' PM_CHEZMOI_REPO \
    "$DEFAULT_REPO"; do
    [[ $sec == *"$s"* ]] || fail "CHEZMOI lacks: $s" "$sec"
  done
  sec=$(readme_section "$output" 'WHAT PM RUN RUNS')
  [[ $sec == *'with --cm:'* ]] || fail "WHAT PM RUN RUNS lacks --cm: $sec"
  has_line "$output" '  PM_CHEZMOI_REPO      example.org/u/d'
  unset PM_CHEZMOI_REPO
  run pm readme
  has_line "$output" "  PM_CHEZMOI_REPO      $DEFAULT_REPO"
}

# cm_completion <bash_candidates|zsh_candidates>
cm_completion() {
  unset STUB_PS
  fake_container up
  fake_container down
  printf 'exited\n' >"$STUB_STATE/status/down"
  run --separate-stderr "$1" pm ''
  expect_status 0
  has_line "$output" cm
  run --separate-stderr "$1" pm run -
  expect_status 0
  has_line "$output" --cm
  run --separate-stderr "$1" pm run --cm -
  expect_status 0
  if grep -qxF -- --cm <<<"$output"; then fail '--cm offered twice'; fi
  has_line "$output" --cc
  run --separate-stderr "$1" pm cm ''
  expect_status 0
  [ "$(sed 1d <<<"$output" | LC_ALL=C sort | tr '\n' ' ')" = 'up ' ] || fail "pm cm: $output"
  run --separate-stderr "$1" pm cm up ''
  expect_status 0
  has_line "$output" kind=none
  run --separate-stderr "$1" pm cm -
  expect_status 0
  [ "$(sed 1d <<<"$output" | tr '\n' ' ')" = '--help ' ] || fail "pm cm -: $output"
  # CMF1-10: nothing follows --help
  run --separate-stderr "$1" pm cm --help ''
  expect_status 0
  [ "$(sed 1d <<<"$output" | tr '\n' ' ')" = '' ] || fail "pm cm --help: $output"
  run --separate-stderr "$1" pm cm --help -
  expect_status 0
  [ "$(sed 1d <<<"$output" | tr '\n' ' ')" = '' ] || fail "pm cm --help -: $output"
}

@test "C9 bash: completion offers cm, --cm once, and running containers for pm cm" {
  cm_completion bash_candidates
}

@test "C9 zsh: completion offers cm, --cm once, and running containers for pm cm" {
  need_zsh
  cm_completion zsh_candidates
}

@test "C9: bash and zsh complete pm cm and pm run --cm alike" {
  need_zsh
  unset STUB_PS
  fake_container up
  local c a b
  local -a w
  for c in "pm ''" "pm run -" "pm run --cm -" "pm run --cm ''" "pm cm ''" "pm cm -" "pm cm up ''" "pm cm --help ''" "pm cm --help -"; do
    eval "w=($c)"
    a=$(bash_candidates "${w[@]}" | sort)
    b=$(zsh_candidates "${w[@]}" | sort)
    [ "$a" = "$b" ] || fail "differ for: $c" "--- bash" "$a" "--- zsh" "$b"
  done
}
