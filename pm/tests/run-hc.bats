#!/usr/bin/env bats
# stub tests for pm run --hc (pm v8): a fake podman logs every call, HOME
# is a per-test folder, and no real podman runs; the S and H numbers are
# the IDs of the v8 spec
# run: bats pm/tests/run-hc.bats  (PM_SH=<file> tests another pm.sh)
# shellcheck disable=SC2012,SC2016
# SC2012: ls lists folders the tests named; SC2016: literal $ on purpose

load test_helper

setup() { stub_setup; }

IMG=example.org/img:1
STATE_TARGET=/home/vscode/.local/state/herdr-core

# ------------------------------------------------------------------ S1, S2

@test "S1: --hc works after the operands and when repeated" {
  run --separate-stderr pm run --mount "$P" "$IMG" --hc --hc
  expect_status 0
  run_args
  [ "$(count_v :/etc/machine-id:ro)" -eq 1 ]
  [ "$(count_v ":$STATE_TARGET")" -eq 1 ]
  has_opt -v "$P/herdr-machine-id:/etc/machine-id:ro"
}

@test "S1: --hc after -- is an operand, not the flag" {
  run --separate-stderr pm run --mount "$P" -- "$IMG" --hc
  expect_status 0
  run_args
  has_opt --name --hc
  [ "$(count_v :/etc/machine-id:ro)" -eq 0 ]
  [ -z "$(ls -A "$P")" ]
}

@test "S2: --hc without --mount prints the error, a blank line, and the run help; exit 2" {
  local help args
  help=$(pm run --help)
  for args in "--hc $IMG name" "--hc --net n1 $IMG name" "$IMG --hc"; do
    # shellcheck disable=SC2086  # split the argument string on purpose
    run --separate-stderr pm run $args
    expect_status 2
    [ "$stderr" = "pm run: --hc needs --mount"$'\n\n'"$help" ] || fail "stderr: $stderr"
    [ -z "$output" ]
  done
  [ ! -s "$PODMAN_LOG" ] || { podman_show; fail 'podman was called'; }
}

# ------------------------------------------------------------------ S3, S4, S5

@test "S3: a relative --mount path resolves to the absolute folder" {
  need_python
  cd "$T"
  run --separate-stderr pm run --hc --mount proj/ "$IMG"
  expect_status 0
  [[ -f $P/herdr-machine-id ]]
  run_args
  has_opt -v "$P:/workspaces/proj"
  has_opt -v "$P/herdr-machine-id:/etc/machine-id:ro"
  has_opt -v "$HC/proj-$(sha256_hex "$(<"$P/herdr-machine-id")"):$STATE_TARGET"
}

@test "S3: a symlinked --mount path keeps the link name in all paths" {
  need_node
  mkdir -p "$T/real/.devcontainer"
  ln -s real "$T/link"
  run --separate-stderr pm run --hc --mount "$T/link" "$IMG"
  expect_status 0
  [[ -f $T/real/.devcontainer/herdr-machine-id ]]
  local state
  state=$HC/link-$(ref_id "$T/link")
  [[ -d $state ]] || { ls -A "$HC"; fail "missing $state"; }
  run_args
  has_opt -v "$T/link/.devcontainer/herdr-machine-id:/etc/machine-id:ro"
  has_opt -v "$state:$STATE_TARGET"
}

@test "S4: with .devcontainer, pm uses the dev container's id file and state folder" {
  need_node
  mkdir "$P/.devcontainer"
  run --separate-stderr pm run --hc --mount "$P" "$IMG"
  expect_status 0
  local f=$P/.devcontainer/herdr-machine-id state
  state=$HC/proj-$(ref_id "$P")
  is_id "$(<"$f")"
  [[ -d $state ]] || { ls -A "$HC"; fail "missing $state"; }
  [[ ! -e $P/herdr-machine-id ]]
  run_args
  has_opt -v "$f:/etc/machine-id:ro"
  has_opt -v "$state:$STATE_TARGET"
}

@test "S4: devcontainer.json does not change the devcontainerId" {
  need_node
  mkdir "$P/.devcontainer"
  run --separate-stderr pm run --hc --mount "$P" "$IMG" c1
  expect_status 0
  echo '{}' >"$P/.devcontainer/devcontainer.json"
  forget_containers
  run --separate-stderr pm run --hc --mount "$P" "$IMG" c2
  expect_status 0
  [[ $stderr != *'new herdr-core state folder'* ]] || fail "$stderr"
  [ "$(ls -A "$HC")" = "proj-$(ref_id "$P")" ]
}

@test "S4: the devcontainerId of /home/u/src/myapp is the spec's known value" {
  local known=1ua78clarg8t27os619m4mncqe13ct6rpkebs04cjgu0kdraqrog
  run --separate-stderr pm_internal _pm_devcontainer_id /home/u/src/myapp
  expect_status 0
  [ "$output" = "$known" ]
  # the reference agrees, so the other tests can trust it
  need_node
  [ "$(ref_id /home/u/src/myapp)" = "$known" ]
}

@test "S4: devcontainerIds of every control character, quote, and backslash match the reference" {
  need_node
  local s='/x' i h c
  for (( i = 1; i < 32; i++ )); do
    printf -v h '%02x' "$i"
    printf -v c %b "\\x$h"
    s+=$c
  done
  s+=$'"\\/\x7f end \xc3\xbc'
  run --separate-stderr pm_internal _pm_devcontainer_id "$s"
  expect_status 0
  [ "$output" = "$(ref_id "$s")" ]
}

@test "R1-03: the devcontainerId does not depend on a multibyte locale such as GBK" {
  need_node
  command -v localedef >/dev/null || skip 'localedef not found'
  # the last byte of U+4E01 in UTF-8 and the \ after it form one GBK character
  local p=$'/x/\xe4\xb8\x81\\y'
  mkdir -p "$T/locale"
  localedef -c -i zh_CN -f GBK "$T/locale/zh_CN.GBK" >/dev/null 2>&1 || skip 'cannot build a GBK locale'
  [ "$(LOCPATH=$T/locale LC_ALL=zh_CN.GBK locale charmap 2>/dev/null)" = GBK ] || skip 'GBK locale not usable'
  LOCPATH=$T/locale LC_ALL=zh_CN.GBK run --separate-stderr pm_internal _pm_devcontainer_id "$p"
  expect_status 0
  [ "$output" = "$(ref_id "$p")" ]
}

@test "S4: folders with special characters get the reference devcontainerId" {
  need_node
  local -a names=('with space' 'dq"uote' "sq'uote" 'back\slash' $'\xc3\xbcmlaut-\xe6\x97\xa5\xe6\x9c\xac'
    $'tab\tx' $'ctl\001x' $'esc\033x' $'cr\rx' $'nl\nx' 'amp&x' $'del\x7fx')
  local name dir abs state i=0
  for name in "${names[@]}"; do
    i=$((i + 1))
    dir=$T/s/$name
    mkdir -p "$dir/.devcontainer"
    abs=$(cd -- "$dir" && pwd)
    run --separate-stderr pm run --hc --mount "$dir" "$IMG" "c$i"
    expect_status 0
    state=$HC/$name-$(ref_id "$abs")
    [[ -d $state ]] || { ls -A "$HC" | od -c; fail "no state folder for $(printf %q "$name")"; }
    run_args
    has_opt -v "$abs/.devcontainer/herdr-machine-id:/etc/machine-id:ro"
    has_opt -v "$state:$STATE_TARGET"
  done
}

@test "S4: a .devcontainer that is not a folder selects the root case" {
  : >"$P/.devcontainer"
  run --separate-stderr pm run --hc --mount "$P" "$IMG"
  expect_status 0
  is_id "$(<"$P/herdr-machine-id")"
}

@test "S5: without .devcontainer, the state folder is named after the sha256 of the id" {
  need_python
  run --separate-stderr pm run --hc --mount "$P" "$IMG"
  expect_status 0
  local id state
  id=$(<"$P/herdr-machine-id")
  is_id "$id"
  state=$HC/proj-$(sha256_hex "$id")
  [[ ${state##*-} =~ ^[0123456789abcdef]{64}$ ]]
  [ "$(ls -A "$HC")" = "${state##*/}" ]
  run_args
  has_opt -v "$P/herdr-machine-id:/etc/machine-id:ro"
  has_opt -v "$state:$STATE_TARGET"
}

# ------------------------------------------------------------------ S6

@test "S6: a missing id file is written as 32 lowercase hex digits and a newline" {
  run --separate-stderr pm run --hc --mount "$P" "$IMG"
  expect_status 0
  local f=$P/herdr-machine-id id
  id=$(<"$f")
  is_id "$id"
  [ "$(cat -- "$f"; printf x)" = "$id"$'\nx' ]
  has_line "$stderr" "pm run: note: wrote a new herdr-core machine-id: $f"
  # no temp file is left
  [ "$(ls -A "$P")" = herdr-machine-id ]
}

@test "S6: a valid id file stays unchanged, also with trailing newlines" {
  need_python
  local f=$P/herdr-machine-id content i=0
  for content in 0123456789abcdef0123456789abcdef $'0123456789abcdef0123456789abcdef\n\n\n'; do
    i=$((i + 1))
    printf '%s' "$content" >"$f"
    cp -- "$f" "$T/before"
    forget_containers
    run --separate-stderr pm run --hc --mount "$P" "$IMG" "c$i"
    expect_status 0
    cmp -- "$f" "$T/before"
    [[ $stderr != *machine-id:* ]] || fail "$stderr"
  done
  [[ -d $HC/proj-$(sha256_hex 0123456789abcdef0123456789abcdef) ]]
}

@test "S6: an invalid id file is replaced" {
  local f=$P/herdr-machine-id content i=0
  local -a bad=(
    0123456789ABCDEF0123456789ABCDEF
    0123456789abcdef0123456789abcde
    0123456789abcdef0123456789abcdef0
    $'0123456789abcdef0123456789abcdef\r\n'
    ' 0123456789abcdef0123456789abcdef'
    01234567-89ab-cdef-0123-456789abcdef
    $'0123456789abcdef0123456789abcdef\n0123456789abcdef0123456789abcdef'
    ''
  )
  for content in "${bad[@]}"; do
    i=$((i + 1))
    printf '%s' "$content" >"$f"
    forget_containers
    run --separate-stderr pm run --hc --mount "$P" "$IMG" "c$i"
    expect_status 0
    is_id "$(<"$f")" || fail "case $i"
    has_line "$stderr" "pm run: note: replaced the invalid herdr-core machine-id: $f"
  done
}

@test "S6: an id file path that is a folder or a dangling link is an error and stays" {
  mkdir "$P/herdr-machine-id"
  : >"$P/herdr-machine-id/keep"
  run --separate-stderr pm run --hc --mount "$P" "$IMG" c1
  expect_status 1
  [[ $stderr == *error* ]]
  [[ -e $P/herdr-machine-id/keep ]]
  [ "$(ls -A "$P")" = herdr-machine-id ]
  [[ ! -e $HOME/.config/herdr-core ]]
  no_create

  mkdir "$T/dl"
  ln -s missing "$T/dl/herdr-machine-id"
  run --separate-stderr pm run --hc --mount "$T/dl" "$IMG" c2
  expect_status 1
  [[ $stderr == *error* ]]
  [ "$(readlink "$T/dl/herdr-machine-id")" = missing ]
  [ "$(ls -A "$T/dl")" = herdr-machine-id ]
  no_create
}

@test "S6: an unreadable id file is an error and stays" {
  (( EUID != 0 )) || skip 'root can read any file'
  local f=$P/herdr-machine-id
  printf 'keep' >"$f"
  chmod 000 "$f"
  run --separate-stderr pm run --hc --mount "$P" "$IMG"
  chmod 600 "$f"
  expect_status 1
  [ "$(<"$f")" = keep ]
  no_create
}

@test "S6: a new id is uuidgen's output without dashes, lowercased" {
  fake uuidgen 'echo 0123ABCD-4567-89EF-0123-456789ABCDEF'
  run --separate-stderr pm run --hc --mount "$P" "$IMG"
  expect_status 0
  [ "$(cat -- "$P/herdr-machine-id"; printf x)" = $'0123abcd456789ef0123456789abcdef\nx' ]
}

@test "S6: without uuidgen, the id comes from /proc/sys/kernel/random/uuid" {
  [[ -r /proc/sys/kernel/random/uuid ]] || skip 'no /proc/sys/kernel/random/uuid'
  use_min_path
  fake_hash sha256sum
  run --separate-stderr pm run --hc --mount "$P" "$IMG"
  expect_status 0
  is_id "$(<"$P/herdr-machine-id")"
}

@test "S6: a failing uuidgen falls back to /proc/sys/kernel/random/uuid" {
  [[ -r /proc/sys/kernel/random/uuid ]] || skip 'no /proc/sys/kernel/random/uuid'
  # the output of a failed uuidgen must not become the id
  fake uuidgen 'echo 0123ABCD-4567-89EF-0123-456789ABCDEF; exit 1'
  run --separate-stderr pm run --hc --mount "$P" "$IMG"
  expect_status 0
  is_id "$(<"$P/herdr-machine-id")"
  [ "$(<"$P/herdr-machine-id")" != 0123abcd456789ef0123456789abcdef ]
}

@test "S6: an unusable new id is an error and writes nothing" {
  fake uuidgen 'echo not-a-uuid'
  run --separate-stderr pm run --hc --mount "$P" "$IMG"
  expect_status 1
  [[ $stderr == *error* ]]
  [ -z "$(ls -A "$P")" ]
  no_create
}

@test "S6: a failed write leaves neither a partial nor a temp file" {
  local f=$P/herdr-machine-id
  fake mv 'exit 1'
  run --separate-stderr pm run --hc --mount "$P" "$IMG" c1
  expect_status 1
  [[ $stderr == *error* ]]
  [ -z "$(ls -A "$P")" ]
  # an invalid file stays as it was
  printf 'old' >"$f"
  run --separate-stderr pm run --hc --mount "$P" "$IMG" c2
  expect_status 1
  [ "$(<"$f")" = old ]
  [ "$(ls -A "$P")" = herdr-machine-id ]
  no_create
}

# ------------------------------------------------------------------ S7

@test "S7: pm creates the state folder, sets mode 700, and notes the new folder" {
  need_python
  mkdir -p "$HOME/.config/herdr-core"
  chmod 755 "$HOME/.config/herdr-core"
  run --separate-stderr pm run --hc --mount "$P" "$IMG"
  expect_status 0
  local state
  state=$HC/proj-$(sha256_hex "$(<"$P/herdr-machine-id")")
  [ "$(file_mode "$HOME/.config/herdr-core")" = 700 ]
  [ "$(file_mode "$state")" = 700 ]
  has_line "$stderr" "pm run: note: new herdr-core state folder: $state"
}

@test "S7: an existing state folder gets mode 700 and no note" {
  need_python
  local state
  printf '0123456789abcdef0123456789abcdef\n' >"$P/herdr-machine-id"
  state=$HC/proj-$(sha256_hex 0123456789abcdef0123456789abcdef)
  mkdir -p "$state"
  chmod 755 "$state"
  run --separate-stderr pm run --hc --mount "$P" "$IMG"
  expect_status 0
  [ "$(file_mode "$state")" = 700 ]
  [[ $stderr != *'new herdr-core state folder'* ]] || fail "$stderr"
}

@test "S7: XDG_CONFIG_HOME does not move the state folder" {
  export XDG_CONFIG_HOME=$T/xdg
  run --separate-stderr pm run --hc --mount "$P" "$IMG"
  expect_status 0
  [ "$(ls -A "$HC" | wc -l)" -eq 1 ]
  [[ ! -e $T/xdg ]]
}

@test "S7: a failed mkdir is an error and creates nothing in podman" {
  mkdir -p "$HOME/.config"
  : >"$HOME/.config/herdr-core"
  run --separate-stderr pm run --hc --mount "$P" "$IMG"
  expect_status 1
  [[ $stderr == *error* ]]
  no_create
}

@test "S7: chmod also works with BSD-style option parsing" {
  local real
  real=$(type -P chmod)
  # GNU chmod with POSIXLY_CORRECT stops at the first operand, as BSD does
  fake chmod "POSIXLY_CORRECT=1 exec $(printf %q "$real") \"\$@\""
  run --separate-stderr pm run --hc --mount "$P" "$IMG"
  expect_status 0
  [ "$(file_mode "$HOME/.config/herdr-core")" = 700 ]
  [ "$(file_mode "$HC/$(ls -A "$HC")")" = 700 ]
}

@test "S7: a failed chmod is an error and creates nothing in podman" {
  fake chmod 'exit 1'
  run --separate-stderr pm run --hc --mount "$P" "$IMG"
  expect_status 1
  [[ $stderr == *error* ]]
  no_create
}

# ------------------------------------------------------------------ S8

@test "S8: an existing container stops pm before it writes any herdr-core file" {
  : >"$STUB_STATE/containers/pm-proj"
  run --separate-stderr pm run --hc --mount "$P" "$IMG"
  expect_status 1
  has_line "$stderr" 'error container pm-proj exists; remove it with: pm rm pm-proj'
  [ -z "$(ls -A "$P")" ]
  [[ ! -e $HOME/.config/herdr-core ]]
  no_create
}

@test "S8: a failed podman run rolls back podman but keeps the id file and state folder" {
  export STUB_RUN_RC=125
  run --separate-stderr pm run --hc --mount "$P" "$IMG"
  expect_status 1
  podman_find -x rm -f -- pm-proj
  podman_find -x network rm -- proj
  if podman_find exec; then fail 'unexpected podman exec'; fi
  is_id "$(<"$P/herdr-machine-id")"
  [ "$(ls -A "$HC" | wc -l)" -eq 1 ]
}

@test "S8: pm rm keeps the id file and state folder" {
  run --separate-stderr pm run --hc --mount "$P" "$IMG"
  expect_status 0
  local id state
  id=$(<"$P/herdr-machine-id")
  state=$(ls -A "$HC")
  run --separate-stderr pm rm --force pm-proj
  expect_status 0
  podman_find -x rm -f -- pm-proj
  [ "$(<"$P/herdr-machine-id")" = "$id" ]
  [ "$(ls -A "$HC")" = "$state" ]
}

# ------------------------------------------------------------------ S9

@test "S9: sha256sum comes first" {
  need_python
  fake_hash sha256sum
  fake_hash shasum
  fake_hash openssl
  run --separate-stderr pm run --hc --mount "$P" "$IMG"
  expect_status 0
  [ "$(<"$STUB_HASH_LOG")" = sha256sum ]
  [[ -d $HC/proj-$(sha256_hex "$(<"$P/herdr-machine-id")") ]]
}

@test "S9: shasum -a 256 without sha256sum (dev container case)" {
  need_node
  use_min_path
  fake_hash shasum
  fake_hash openssl
  mkdir "$P/.devcontainer"
  run --separate-stderr pm run --hc --mount "$P" "$IMG"
  expect_status 0
  [ "$(<"$STUB_HASH_LOG")" = 'shasum -a 256' ]
  [[ -d $HC/proj-$(ref_id "$P") ]]
}

@test "S9: openssl dgst -sha256 -r when it is the only tool" {
  need_python
  use_min_path
  fake_hash openssl
  run --separate-stderr pm run --hc --mount "$P" "$IMG"
  expect_status 0
  [ "$(<"$STUB_HASH_LOG")" = 'openssl dgst -sha256 -r' ]
  [[ -d $HC/proj-$(sha256_hex "$(<"$P/herdr-machine-id")") ]]
}

@test "S9: no sha256 tool is an error and creates nothing in podman" {
  use_min_path
  printf '0123456789abcdef0123456789abcdef\n' >"$P/herdr-machine-id"
  run --separate-stderr pm run --hc --mount "$P" "$IMG"
  expect_status 1
  has_line "$stderr" 'error no sha256 tool found; install sha256sum, shasum, or openssl'
  [ "$(<"$P/herdr-machine-id")" = 0123456789abcdef0123456789abcdef ]
  no_create
}

# ------------------------------------------------------------------ S10, S11

@test "S10: podman run gets both herdr-core mounts next to the workspace mount" {
  need_python
  run --separate-stderr pm run --hc --mount "$P" "$IMG"
  expect_status 0
  run_args
  has_opt -v "$P:/workspaces/proj"
  has_opt -v "$P/herdr-machine-id:/etc/machine-id:ro"
  has_opt -v "$HC/proj-$(sha256_hex "$(<"$P/herdr-machine-id")"):$STATE_TARGET"
  [ "${RUN[*]: -3}" = "$IMG sleep infinity" ]
}

@test "S10: without --hc, pm run writes no herdr-core file and adds no mount" {
  run --separate-stderr pm run --mount "$P" "$IMG"
  expect_status 0
  [ -z "$(ls -A "$P")" ]
  [[ ! -e $HOME/.config/herdr-core ]]
  run_args
  [ "$(count_v :/etc/machine-id:ro)" -eq 0 ]
  if podman_find exec; then fail 'unexpected podman exec'; fi
}

@test "S11: after podman run, pm starts hc serve detached with SHELL=/bin/bash" {
  run --separate-stderr pm run --hc --mount "$P" "$IMG"
  expect_status 0
  local r
  podman_find run
  r=$FOUND
  hc_serve_call pm-proj || { podman_show; fail 'no podman exec -d -e SHELL=/bin/bash -- pm-proj hc serve'; }
  (( FOUND > r ))
  has_line "$output" 'ok    hc serve started in pm-proj'
}

@test "S11: a failed hc serve is an error with its output; the container stays" {
  export STUB_EXEC_RC=127
  export STUB_EXEC_ERR='Error: crun: executable file `hc` not found in $PATH'
  run --separate-stderr pm run --hc --mount "$P" "$IMG"
  expect_status 1
  has_line "$stderr" "error pm-proj: hc serve: $STUB_EXEC_ERR"
  if podman_find rm || podman_find network rm; then podman_show; fail 'pm rolled back'; fi
  [[ -e $STUB_STATE/containers/pm-proj ]]
}

# ------------------------------------------------------------------ S12

@test "S12: git notes an id file that it does not ignore" {
  need_git
  git init -q "$P"
  mkdir "$P/.devcontainer"
  run --separate-stderr pm run --hc --mount "$P" "$IMG"
  expect_status 0
  has_line "$stderr" "pm run: note: git does not ignore $P/.devcontainer/herdr-machine-id; add it to .gitignore"
}

@test "S12: no note for an ignored id file, outside a work tree, or without git" {
  need_git
  git init -q "$P"
  echo herdr-machine-id >"$P/.gitignore"
  run --separate-stderr pm run --hc --mount "$P" "$IMG" c1
  expect_status 0
  [[ $stderr != *'git does not ignore'* ]] || fail "$stderr"

  mkdir "$T/plain"
  run --separate-stderr pm run --hc --mount "$T/plain" "$IMG" c2
  expect_status 0
  [[ $stderr != *'git does not ignore'* ]] || fail "$stderr"

  rm -- "$P/.gitignore"
  use_min_path
  fake_hash sha256sum
  forget_containers
  run --separate-stderr pm run --hc --mount "$P" "$IMG" c3
  expect_status 0
  [[ $stderr != *'git does not ignore'* ]] || fail "$stderr"
}

@test "S12: pm asks git check-ignore about the relative path; other statuses stay silent" {
  export FAKE_GIT_LOG=$T/git.log FAKE_GIT_RC=128
  fake git 'printf "%s\n" "$*" >>"$FAKE_GIT_LOG"
case " $* " in
  *" rev-parse "*)    echo true ;;
  *" check-ignore "*) exit "$FAKE_GIT_RC" ;;
esac'
  run --separate-stderr pm run --hc --mount "$P" "$IMG" c1
  expect_status 0
  [[ $stderr != *'git does not ignore'* ]] || fail "$stderr"
  has_line "$(cat -- "$FAKE_GIT_LOG")" "-C $P check-ignore -q -- herdr-machine-id"

  export FAKE_GIT_RC=1
  forget_containers
  run --separate-stderr pm run --hc --mount "$P" "$IMG" c2
  expect_status 0
  has_line "$stderr" "pm run: note: git does not ignore $P/herdr-machine-id; add it to .gitignore"
}

# ------------------------------------------------------------------ H1 to H4

@test "H1, V9-01: pm --version prints pm 9, and pm run labels with pm-script=9" {
  run pm --version
  expect_status 0
  [ "$output" = 'pm 9' ]
  run --separate-stderr pm run --hc --mount "$P" "$IMG"
  expect_status 0
  run_args
  has_opt --label pm-script=9
}

@test "H2: pm run --help shows --hc and a herdr-core section" {
  run --separate-stderr pm run --help
  expect_status 0
  [ "${lines[0]}" = 'usage: pm run [--cc] [--cp] [--hc] [--mount <dir>] [--net <name>] <image> [<container-name>]' ]
  grep -qE '^  --hc +[a-z]' <<<"$output" || fail 'no option line for --hc'
  has_line "$output" 'herdr-core:'
  local section=${output#*$'\n'herdr-core:$'\n'} s
  section=${section%%$'\n'runs:*}
  for s in '<dir>/.devcontainer/herdr-machine-id' '<dir>/herdr-machine-id' \
    '.config/herdr-core/container/<foldername>-<devcontainerId>' sha256 \
    /etc/machine-id "$STATE_TARGET" \
    'podman exec -d -e SHELL=/bin/bash <container> hc serve' \
    'hc machine' 'pm-hc=<container-name>' 'pm start' rollback 'pm rm'; do
    [[ $section == *"$s"* ]] || fail "the herdr-core section lacks: $s"
  done
  # the runs block lists the start command and the hc machine too
  has_line "$output" '      with --hc: podman exec -d -e SHELL=/bin/bash <container-name> hc serve'
  [[ $output == *'hc machine add --name <container-name>'* ]] || fail 'runs: lacks hc machine add'
  # D23: one container per folder, with its limits
  has_line "$output" 'one container per folder:'
  section=${output#*$'\n'one container per folder:$'\n'}
  section=${section%%$'\n\n'*}
  for s in 'podman containers' Docker 'as spelled' 'podman run'; do
    [[ $section == *"$s"* ]] || fail "the one container per folder section lacks: $s"
  done
}

@test "H3: pm help lists --hc in the run line" {
  run pm help
  expect_status 0
  has_line "$output" '  run        [--cc] [--cp] [--hc] [--mount <dir>] [--net <name>] <image> [<container-name>]'
}

@test "H4: pm readme has a HERDR-CORE section" {
  run pm readme
  expect_status 0
  has_line "$output" HERDR-CORE
  local section=${output#*$'\n'HERDR-CORE$'\n'} s
  section=${section%%$'\n'[A-Z]*}
  for s in --hc /etc/machine-id .devcontainer/herdr-machine-id \
    .config/herdr-core/container/ 'one at a time' 'VS Code' git \
    'podman exec -d -e SHELL=/bin/bash <container> hc serve' \
    'only one core runs per state folder' .devcontainer/devcontainer.json \
    '.devcontainer/<name>/devcontainer.json' 'hc exec --on' 'pm-hc=' \
    'pm start' 'pm rm'; do
    [[ $section == *"$s"* ]] || fail "the HERDR-CORE section lacks: $s"
  done
  # D23: one container per folder, with its limits
  has_line "$output" 'ONE CONTAINER PER FOLDER'
  section=${output#*$'\n'ONE CONTAINER PER FOLDER$'\n'}
  section=${section%%$'\n'[A-Z]*}
  for s in 'podman containers' Docker 'as spelled' 'podman run'; do
    [[ $section == *"$s"* ]] || fail "the ONE CONTAINER PER FOLDER section lacks: $s"
  done
}

@test "H2 to H4: help texts and the readme use no m-dash" {
  local args
  for args in 'run --help' help readme; do
    # shellcheck disable=SC2086  # split the argument string on purpose
    run pm $args
    expect_status 0
    [[ $output != *$'\xe2\x80\x94'* ]] || fail "m-dash in pm $args"
  done
}
