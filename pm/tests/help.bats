#!/usr/bin/env bats
# stub tests for the short pm run help: usage and options only, with the
# explanations in pm readme (one container per folder, network isolation,
# herdr-core, and the podman commands pm run runs)
# run: bats pm/tests/help.bats

load test_helper

setup() {
  stub_setup
  PM_VERSION_EXPECTED=$(pm --version)
  PM_VERSION_EXPECTED=${PM_VERSION_EXPECTED#pm }
}

@test "R1: pm run --help has at most 25 lines, the usage line, and every option" {
  run --separate-stderr pm run --help
  expect_status 0
  # lines[] drops blank lines, so count the lines of the output itself
  local -a all
  mapfile -t all <<<"$output"
  (( ${#all[@]} <= 25 )) || fail "pm run --help has ${#all[@]} lines"
  [ "${lines[0]}" = 'usage: pm run [--cc] [--cp] [--cm] [--hc] [--mount <dir>] [--net <name>] <image> [<container-name>]' ]
  local o
  for o in --cc --cp --cm --hc '--mount <dir>' '--mnt <dir>' '--net <name>' '<image>' '<container-name>'; do
    grep -qE "^  $o +[a-zA-Z<]" <<<"$output" || fail "no option line for $o"
  done
  # --mount names both mounts, the worktrees one with its target
  local flat
  flat=$(tr -s ' \n' '  ' <<<"$output")
  [[ $flat == *'<dir>/../<foldername>.worktrees at /workspaces/<foldername>.worktrees'* ]] \
    || fail "the --mount lines lack the worktrees target: $output"
}

@test "CMF1-05: every option description in pm run --help starts in the same column" {
  run --separate-stderr pm run --help
  expect_status 0
  local l cols=''
  for l in "${lines[@]}"; do
    # an option line: two spaces, the option (with its argument), spaces
    [[ $l =~ ^(\ \ (--[a-z]+(\ <[a-z-]+>)?|<[a-z-]+>)\ +)[^\ ] ]] || continue
    cols+=" ${#BASH_REMATCH[1]}"
  done
  [[ -n $cols ]] || fail 'no option lines'
  # shellcheck disable=SC2086  # one word per column
  [ "$(printf '%s\n' $cols | sort -u | wc -l)" -eq 1 ] || fail "columns:$cols" "$output"
}

@test "R1: pm run --help ends with a pointer to pm readme" {
  run --separate-stderr pm run --help
  expect_status 0
  local tail
  tail=$(printf '%s\n' "${lines[@]: -2}")
  [[ $tail == *'pm readme'* ]] || fail "last lines: $tail"
  # the moved blocks are gone from the run help
  local s
  for s in 'one container per folder:' 'network isolation:' 'herdr-core:' 'runs:'; do
    if grep -qxF -- "$s" <<<"$output"; then fail "pm run --help still has: $s"; fi
  done
  [[ $output != *'runs: podman'* ]] || fail 'pm run --help still has the runs block'
}

@test "R1: pm readme holds what the run help explained before" {
  run pm readme
  expect_status 0
  local sec s
  sec=$(readme_section "$output" 'NETWORK ISOLATION')
  for s in 'isolate=strict' "pm-script=$PM_VERSION_EXPECTED" 'another driver' \
    'other than strict' 'e.g. bridge, host, none' 'If podman run fails' \
    'any pm-script label'; do
    [[ $sec == *"$s"* ]] || fail "NETWORK ISOLATION lacks: $s"
  done
  [[ $sec != *'with that label'* ]] || fail 'NETWORK ISOLATION implies a matching label value'
  sec=$(readme_section "$output" 'HERDR-CORE')
  for s in '<devcontainerId>' 'sha256' /home/vscode/.local/state/herdr-core \
    'hc server stop' 'hc server restart' 'hc update' 'exactly' \
    'missing or invalid id file' 'skip line' 'on rollback and on pm rm'; do
    [[ $sec == *"$s"* ]] || fail "HERDR-CORE lacks: $s"
  done
  # the example and the paths do not hang off the rollback sentence
  [[ $sec != *'on rollback and on pm rm:'* ]] || fail 'HERDR-CORE: colon after the rollback sentence'
  sec=$(readme_section "$output" 'WHAT PM RUN RUNS')
  for s in "podman network create -o isolate=strict --label pm-script=$PM_VERSION_EXPECTED <network>" \
    'podman run -d --init --userns=keep-id' "sh -c 'exec hc serve >/dev/null 2>&1'" \
    'with --cc: as pm cp-claude' \
    'with --cp: as pm cp-copilot, instructions, settings, and config.json' \
    'with --hc: shell = [ "/bin/bash" ] into ~/.config/herdr-core/config.toml' \
    'hc machine add --name <container-name>' \
    "--via 'podman exec -i <container-name> sh -c'" 'pm bash <container-name>'; do
    [[ $sec == *"$s"* ]] || fail "WHAT PM RUN RUNS lacks: $s"
  done
}

@test "R1: every section the help points to is a readme heading, in readme order" {
  run --separate-stderr pm run --help
  expect_status 0
  # the names after "details in pm readme:", up to the end of the help
  local ptr=${output#*'details in pm readme:'} name
  ptr=$(tr -s ' \n' '  ' <<<"$ptr")
  ptr=${ptr//', and '/,}
  ptr=${ptr//', '/,}
  local -a names
  IFS=, read -r -a names <<<"$ptr"
  (( ${#names[@]} >= 2 )) || fail "no section names in: $ptr"
  run pm readme
  expect_status 0
  local -a heads
  mapfile -t heads < <(grep -E '^[A-Z][A-Z -]*[A-Z]$' <<<"$output")
  local i j last=-1
  for name in "${names[@]}"; do
    name=$(sed 's/^ *//; s/ *$//' <<<"$name")
    j=-1
    for (( i = 0; i < ${#heads[@]}; i++ )); do
      [[ ${heads[i]} == "$name" ]] && { j=$i; break; }
    done
    (( j >= 0 )) || fail "no readme heading: $name"
    (( j > last )) || fail "the pointer names $name out of readme order"
    last=$j
  done
}
