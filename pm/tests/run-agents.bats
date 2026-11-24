#!/usr/bin/env bats
# stub tests for pm run --cc and --cp (pm v9): the secrets must exist before
# pm creates anything, and the agent files are copied after podman run, as
# pm cp-claude and pm cp-copilot copy them; a fake podman logs every call
# run: bats pm/tests/run-agents.bats
# shellcheck disable=SC2030,SC2031
# SC2030, SC2031: each bats test runs in its own subshell

load test_helper

setup() {
  stub_setup
  export PM_CLAUDE_MD=$T/claude.md PM_CLAUDE_SETTINGS=$T/claude-settings.json \
    PM_COPILOT_SETTINGS=$T/copilot-settings.json STUB_SECRETS='cc_token cp_token'
  printf 'rules\n' >"$PM_CLAUDE_MD"
  printf '{"a":1}\n' >"$PM_CLAUDE_SETTINGS"
  printf '{"b":2}\n' >"$PM_COPILOT_SETTINGS"
}

IMG=example.org/img:1

# fs <path>: the fake container pm-proj's copy of <path>
fs() { printf '%s\n' "$STUB_STATE/fs/pm-proj$1"; }

@test "run --cc/--cp: a missing secret is an error before anything is created" {
  local flag secret
  for flag in --cc --cp; do
    secret=${flag#--}_token
    STUB_SECRETS='' run --separate-stderr pm run "$flag" --mount "$P" "$IMG"
    expect_status 1
    has_line "$stderr" "error podman secret $secret is missing; store the token first with: pm secret-${flag#--}"
    no_create
  done
  [ -z "$(ls -A "$P")" ]
}

@test "run --cc --cp: both secrets, then both file sets after podman run" {
  run --separate-stderr pm run --cc --cp --mount "$P" "$IMG"
  expect_status 0
  run_args
  has_opt --secret cc_token,type=env,target=CLAUDE_CODE_OAUTH_TOKEN
  has_opt --secret cp_token,type=env,target=COPILOT_GITHUB_TOKEN
  cmp -- "$PM_CLAUDE_MD" "$(fs /home/vscode/.claude/CLAUDE.md)"
  cmp -- "$PM_CLAUDE_SETTINGS" "$(fs /home/vscode/.claude/settings.json)"
  cmp -- "$PM_CLAUDE_MD" "$(fs /home/vscode/.copilot/copilot-instructions.md)"
  cmp -- "$PM_COPILOT_SETTINGS" "$(fs /home/vscode/.copilot/settings.json)"
  has_line "$output" "ok    $PM_CLAUDE_MD -> pm-proj:/home/vscode/.claude/CLAUDE.md"
  has_line "$output" "ok    $PM_COPILOT_SETTINGS -> pm-proj:/home/vscode/.copilot/settings.json"
}

@test "run --cc --cp --hc: copy cc, copy cp, the hc config, then the machine" {
  run --separate-stderr pm run --cc --cp --hc --mount "$P" "$IMG"
  expect_status 0
  local r cc cp hc
  podman_find run
  r=$FOUND
  podman_find -x cp -- "$PM_CLAUDE_MD" pm-proj:/home/vscode/.claude/CLAUDE.md
  cc=$FOUND
  podman_find -x cp -- "$PM_CLAUDE_MD" pm-proj:/home/vscode/.copilot/copilot-instructions.md
  cp=$FOUND
  podman_find exec -i -- pm-proj sh -c || { podman_show; fail 'no config write'; }
  hc=$FOUND
  (( r < cc && cc < cp && cp < hc )) || { podman_show; fail "order: run $r, cc $cc, cp $cp, config $hc"; }
  no_hc_serve
  hc_find machine add || { hc_show; fail 'no hc machine add'; }
  # the machine comes last in the output
  [[ ${output##*$'\n'} == 'ok    hc machine pm-proj added' ]] || fail "output: $output"
}

@test "run --cc: missing settings are a skip line" {
  rm -- "$PM_CLAUDE_SETTINGS"
  run --separate-stderr pm run --cc --mount "$P" "$IMG"
  expect_status 0
  has_line "$output" "skip  $PM_CLAUDE_SETTINGS: not found"
  [[ ! -e $(fs /home/vscode/.claude/settings.json) ]]
}

@test "run --cc --hc: a failed copy is an error, the later steps still run, exit 1, the container stays" {
  rm -- "$PM_CLAUDE_MD"
  run --separate-stderr pm run --cc --hc --mount "$P" "$IMG"
  expect_status 1
  has_line "$stderr" "error $PM_CLAUDE_MD: not found"
  hc_find machine add || { hc_show; fail 'no hc machine add after the failed copy'; }
  if podman_find rm; then podman_show; fail 'pm removed the container'; fi
  printf 'rules\n' >"$PM_CLAUDE_MD"
  forget_containers
  STUB_CP_RC=125 run --separate-stderr pm run --cc --cp --mount "$P" "$IMG" c2
  expect_status 1
  [[ $stderr == *'error '*'Error: stub: podman cp failed'* ]] || fail "stderr: $stderr"
}

@test "run: the help names the copies in runs:, and the readme mentions them" {
  run pm run --help
  expect_status 0
  [[ $output == *'with --cc: as pm cp-claude'* && $output == *'with --cp: as pm cp-copilot'* ]] \
    || fail "help: $output"
  run pm readme
  expect_status 0
  [[ $output == *'pm run --cc'*'copies'* ]] || fail 'readme lacks the copies'
}

@test "R1: the readme says how to check the keep-id mapping that the copies need" {
  run pm readme
  expect_status 0
  [[ $output == *TROUBLESHOOTING* ]] || fail "readme: $output"
  [[ $output == *'podman run --rm --userns=keep-id <image> id'* ]] || fail "readme: $output"
  [[ $output == *'uid=1000(vscode)'* && $output == *'--userns=keep-id:uid=1000,gid=1000'* ]] \
    || fail "readme: $output"
}

@test "C3: pm run --cp copies the config template to ~/.copilot/config.json" {
  export PM_COPILOT_CONFIG=$T/copilot-config.json
  printf '{"trusted_folders":["/workspaces"]}\n' >"$PM_COPILOT_CONFIG"
  run --separate-stderr pm run --cp --mount "$P" "$IMG"
  expect_status 0
  cmp -- "$PM_COPILOT_CONFIG" "$(fs /home/vscode/.copilot/config.json)"
  has_line "$output" "ok    $PM_COPILOT_CONFIG -> pm-proj:/home/vscode/.copilot/config.json"
}

@test "C3: without PM_COPILOT_CONFIG, ~/.copilot/config.json.template is the source; missing, a skip line" {
  mkdir -p "$HOME/.copilot"
  printf '{"a":"b"}\n' >"$HOME/.copilot/config.json.template"
  run --separate-stderr pm run --cp --mount "$P" "$IMG"
  expect_status 0
  cmp -- "$HOME/.copilot/config.json.template" "$(fs /home/vscode/.copilot/config.json)"
  forget_containers
  rm -rf -- "$STUB_STATE/fs/pm-proj" "$HOME/.copilot"
  run --separate-stderr pm run --cp --mount "$P" "$IMG"
  expect_status 0
  has_line "$output" "skip  $HOME/.copilot/config.json.template: not found"
  [[ ! -e $(fs /home/vscode/.copilot/config.json) ]]
  cmp -- "$PM_COPILOT_SETTINGS" "$(fs /home/vscode/.copilot/settings.json)"
}

@test "C3: pm cp-copilot copies config.json as well, and its help names the source" {
  export PM_COPILOT_CONFIG=$T/copilot-config.json
  printf '{"c":3}\n' >"$PM_COPILOT_CONFIG"
  fake_container pm-x
  run --separate-stderr pm cp-cp pm-x
  expect_status 0
  cmp -- "$PM_COPILOT_CONFIG" "$STUB_STATE/fs/pm-x/home/vscode/.copilot/config.json"
  has_line "$output" "ok    $PM_COPILOT_CONFIG -> pm-x:/home/vscode/.copilot/config.json"
  run pm cp-copilot --help
  expect_status 0
  has_line "$output" "  $PM_COPILOT_CONFIG"
  has_line "$output" '    -> /home/vscode/.copilot/config.json  (skipped when missing)'
  [[ $output == *PM_COPILOT_CONFIG* ]] || fail "help: $output"
}

@test "C3: PM_COPILOT_CONFIG and PM_HC_SHELL are listed with the other PM_* variables" {
  export PM_COPILOT_CONFIG=$T/copilot-config.json PM_HC_SHELL=/bin/zsh
  run pm help
  expect_status 0
  [[ $output == *'environment: '*PM_COPILOT_SETTINGS*PM_COPILOT_CONFIG*PM_HC_SHELL* ]] || fail "pm help: $output"
  run pm readme
  expect_status 0
  has_line "$output" "  PM_COPILOT_CONFIG    $PM_COPILOT_CONFIG"
  has_line "$output" '  PM_HC_SHELL          /bin/zsh'
  run pm run --help
  expect_status 0
  [[ $output == *'with --cp: as pm cp-copilot, instructions, settings, and config.json'* ]] \
    || fail "help: $output"
}
