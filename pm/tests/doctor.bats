#!/usr/bin/env bats
# stub tests for pm doctor (pm v9): fake tools report their versions; the
# fake podman answers --version; no real podman or hc runs
# run: bats pm/tests/doctor.bats

load test_helper

setup() {
  stub_setup
  # a host that meets every requirement, which each test then breaks
  fake_bash 5.3.0
  fake_tool jq jq-1.8.0
  fake_tool zsh 'zsh 5.9 (x86_64-pc-linux-gnu)'
  fake_tool git 'git version 2.47.1'
  fake_tool uuidgen 'uuidgen from util-linux 2.40'
  # the host core: a process of this user in the test's pid namespace
  fake ps "printf '%s hc serve\n' $$"
}

@test "doctor: all tools in place, exit 0, one ok line per check" {
  run --separate-stderr pm doctor
  expect_status 0
  [ "$output" = "required
ok     bash 5.3.0 (needs 5.3 or later)
ok     podman 6.2.0 (needs 6.2 or later)
ok     jq 1.8.0 (needs 1.8 or later)
ok     sha256 tool: sha256sum
ok     uuid source: uuidgen
optional
ok     zsh 5.9 (needs 5.9 or later)
ok     hc 0.1.21 (needs 0.1.21 or later)
ok     git 2.47.1
ok     hc core running" ] || fail "output: $output"
}

@test "doctor: an old bash, podman, or jq fails with exit 1" {
  fake_bash 5.2.21
  fake_tool jq jq-1.7.1
  export STUB_PODMAN_VERSION=6.1.9
  run --separate-stderr pm doctor
  expect_status 1
  has_line "$output" 'failed bash 5.2.21 (needs 5.3 or later)'
  has_line "$output" 'failed podman 6.1.9 (needs 6.2 or later)'
  has_line "$output" 'failed jq 1.7.1 (needs 1.8 or later)'
}

@test "doctor: versions compare number by number" {
  local a b
  while read -r a b; do
    run pm_internal _pm_version_ge "$a" "$b"
    [ "$status" -eq 0 ] || fail "$a should be at least $b"
  done <<'EOF'
5.3 5.3
5.3.0 5.3
5.10 5.9
6.2.1 6.2
0.1.21 0.1.21
1.10 1.8
EOF
  while read -r a b; do
    run pm_internal _pm_version_ge "$a" "$b"
    [ "$status" -ne 0 ] || fail "$a should be below $b"
  done <<'EOF'
5.2.21 5.3
0.1.3 0.1.21
1.7.1 1.8
6.1.99 6.2
'' 1.0
EOF
}

@test "doctor: missing required tools fail; missing optional ones do not change the exit status" {
  use_min_path
  rm -- "$STUB_BIN/hc"
  fake ps 'true'
  for t in zsh git uuidgen jq; do rm -f -- "$FAKE_BIN/$t"; done
  run --separate-stderr pm doctor
  expect_status 1
  has_line "$output" 'failed jq not found (needs 1.8 or later)'
  has_line "$output" 'failed sha256 tool: none of sha256sum, shasum, openssl'
  has_line "$output" 'failed zsh not found (needs 5.9 or later)'
  has_line "$output" 'failed hc not found (needs 0.1.21 or later)'
  has_line "$output" 'failed git not found'
  has_line "$output" 'failed hc core not running (starts on first hc use)'
  # where /proc gives uuids, that is enough
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    has_line "$output" 'ok     uuid source: /proc/sys/kernel/random/uuid'
  fi
}

@test "doctor: optional failures alone keep exit 0" {
  fake_tool zsh 'zsh 5.8.1 (x86_64-pc-linux-gnu)'
  export FAKE_HC_VERSION=0.1.20
  fake ps 'true'
  run --separate-stderr pm doctor
  expect_status 0
  has_line "$output" 'failed zsh 5.8.1 (needs 5.9 or later)'
  has_line "$output" 'failed hc 0.1.20 (needs 0.1.21 or later)'
  has_line "$output" 'failed hc core not running (starts on first hc use)'
}

@test "doctor: without uuidgen and the kernel's uuid file, the uuid check fails" {
  rm -- "$FAKE_BIN/uuidgen"
  use_min_path
  run --separate-stderr pm_internal _pm_doctor_uuid "$T/no-such-file"
  [ "$status" -ne 0 ]
  [ "$output" = "failed uuid source: neither uuidgen nor $T/no-such-file" ]
}

@test "doctor: on macOS, the core that launchd starts (--hc-launchd) counts as running" {
  fake ps "printf '%s %s\n' $$ '/Applications/Herdr.app/Contents/MacOS/hc --hc-launchd /tmp/hc.sock'"
  run --separate-stderr pm doctor
  expect_status 0
  has_line "$output" 'ok     hc core running'
  # other hc processes are no core
  fake ps "printf '%s %s\n' $$ 'hc attach t3' $$ 'hc --hc-launchdx'"
  run --separate-stderr pm doctor
  has_line "$output" 'failed hc core not running (starts on first hc use)'
}

@test "doctor: the core check reads processes and never asks hc" {
  run --separate-stderr pm doctor
  expect_status 0
  # the fake hc logs `--version ` for its one call
  [ "$(cat -- "$HC_LOG")" = '--version ' ] || { hc_show; fail 'pm doctor asked hc more than --version'; }
}

@test "doctor: pm help, the readme, and the header leave the minimums to pm doctor" {
  run pm help
  expect_status 0
  [[ $output != *requires* && $output != *'bash 5'* ]] || fail "pm help: $output"
  has_line "$output" '  doctor                    check the tools pm needs'
  run pm readme
  expect_status 0
  [[ $output != *requires:* && $output != *'bash 5'* && $output == *'pm doctor'* ]] || fail 'readme'
  run head -n 8 -- "$PM_SH"
  [[ $output != *Requires* ]] || fail "header: $output"
}

@test "doctor: arguments other than --help are a usage error" {
  run --separate-stderr pm doctor x
  expect_status 2
  [[ $stderr == 'usage: pm doctor'* ]] || fail "stderr: $stderr"
  run --separate-stderr pm doctor --help
  expect_status 0
  [[ $output == 'usage: pm doctor'* && $output == *'never starts'* ]] || fail "output: $output"
}
