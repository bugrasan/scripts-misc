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

# the text of readme section $2 in $1: from its heading to the next one
readme_section() {
  local s=${1#*$'\n'"$2"$'\n'}
  printf '%s\n' "${s%%$'\n'[A-Z]*}"
}

@test "R1: pm run --help has at most 25 lines, the usage line, and every option" {
  run --separate-stderr pm run --help
  expect_status 0
  (( ${#lines[@]} <= 25 )) || fail "pm run --help has ${#lines[@]} lines"
  [ "${lines[0]}" = 'usage: pm run [--cc] [--cp] [--hc] [--mount <dir>] [--net <name>] <image> [<container-name>]' ]
  local o
  for o in --cc --cp --hc '--mount <dir>' '--mnt <dir>' '--net <name>' '<image>' '<container-name>'; do
    grep -qE "^  $o +[a-zA-Z<]" <<<"$output" || fail "no option line for $o"
  done
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
    'other than strict' 'e.g. bridge, host, none' 'If podman run fails'; do
    [[ $sec == *"$s"* ]] || fail "NETWORK ISOLATION lacks: $s"
  done
  sec=$(readme_section "$output" 'HERDR-CORE')
  for s in '<devcontainerId>' 'sha256' /home/vscode/.local/state/herdr-core \
    'hc server stop' 'hc server restart' 'hc update' 'exactly' \
    'missing or invalid id file' 'skip line' 'on rollback and on pm rm'; do
    [[ $sec == *"$s"* ]] || fail "HERDR-CORE lacks: $s"
  done
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
