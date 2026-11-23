# shared setup and helpers for the pm bats tests; load with: load test_helper
# PM_SH selects the script under test (default: ../pm.sh)
# shellcheck disable=SC2016,SC2034,SC2153,SC2154
# SC2016: single-quoted scripts run in another shell; SC2034, SC2153,
# SC2154: variables shared with bats and the test files, or set by eval

bats_require_minimum_version 1.5.0

PM_TESTS_DIR=$BATS_TEST_DIRNAME
: "${PM_SH:=$(cd -- "$BATS_TEST_DIRNAME/.." && pwd)/pm.sh}"
NODE=$(command -v node || true)
[[ -n $NODE || ! -x /opt/node22/bin/node ]] || NODE=/opt/node22/bin/node
PYTHON=$(command -v python3 || true)
ZSH=$(command -v zsh || true)

# ------------------------------------------------------------------ sandbox

# per-test sandbox for the stub tests: HOME in BATS_TEST_TMPDIR, the fake
# podman first in PATH, and pm itself run with PM_PATH, which puts FAKE_BIN
# (tools a test fakes, e.g. uuidgen) first
stub_setup() {
  T=$BATS_TEST_TMPDIR
  export HOME=$T/home NO_COLOR=1 GIT_CONFIG_NOSYSTEM=1 GIT_CEILING_DIRECTORIES=$T
  unset XDG_CONFIG_HOME CDPATH
  export PODMAN_LOG=$T/podman.log STUB_STATE=$T/podman-state
  export STUB_HASH_LOG=$T/hash.log STUB_PYTHON=$PYTHON
  STUB_BIN=$T/stub-bin FAKE_BIN=$T/fake-bin MIN_BIN=$T/min-bin
  HC=$HOME/.config/herdr-core/container
  P=$T/proj
  mkdir -p "$HOME" "$STUB_BIN" "$FAKE_BIN" "$STUB_STATE/containers" "$STUB_STATE/networks" "$P"
  : >"$PODMAN_LOG"
  cp -- "$PM_TESTS_DIR/stub/podman" "$STUB_BIN/podman"
  chmod 755 "$STUB_BIN/podman"
  export PATH=$STUB_BIN:$PATH
  PM_PATH=$FAKE_BIN:$PATH
  # never reach a real podman
  [[ $(command -v podman) == "$STUB_BIN/podman" ]] || fail 'the fake podman is not first in PATH'
}

# PM_PATH without the optional tools pm may use (git, uuidgen, sha256sum,
# shasum, openssl): the fakes, the fake podman, and basic commands only
use_min_path() {
  local t p
  mkdir -p "$MIN_BIN"
  for t in bash env cat mkdir chmod mv rm ln ls cp tr sed grep head tail cut \
    sort wc dirname basename touch stat id uname sleep od; do
    if p=$(type -P "$t"); then ln -sf -- "$p" "$MIN_BIN/$t"; fi
  done
  PM_PATH=$FAKE_BIN:$STUB_BIN:$MIN_BIN
}

# fake <command> <bash code>: a fake command in FAKE_BIN, seen by pm only
fake() {
  printf '#!%s\n%s\n' "$BASH" "$2" >"$FAKE_BIN/$1"
  chmod 755 "$FAKE_BIN/$1"
}

# fake_hash <tool>: fake sha256sum, shasum, or openssl that logs its call
# to $STUB_HASH_LOG and prints the real digest in that tool's format
fake_hash() {
  need_python
  cp -- "$PM_TESTS_DIR/stub/hash-tool" "$FAKE_BIN/$1"
  chmod 755 "$FAKE_BIN/$1"
}

need_node()   { [[ -n $NODE ]] || skip 'node not found'; }
need_python() { [[ -n $PYTHON ]] || skip 'python3 not found'; }
need_zsh()    { [[ -n $ZSH ]] || skip 'zsh not found'; }
need_git()    { command -v git >/dev/null || skip 'git not found'; }

# ------------------------------------------------------------------ running pm

# pm.sh run with bash and PM_PATH as PATH (a plain PATH where unset)
pm() { env PATH="${PM_PATH:-$PATH}" "$BASH" "$PM_SH" "$@"; }

# pm_internal <function> [<arg>...]: call one of pm.sh's own functions;
# pm.sh is evaluated without its final `main "$@"` line
pm_internal() {
  env PATH="${PM_PATH:-$PATH}" "$BASH" -c \
    'src=$(grep -vxF -- "$2" "$1") && eval "$src" && shift 2 && "$@"' \
    _ "$PM_SH" 'main "$@"' "$@"
}

# ------------------------------------------------------------------ podman log

# podman_load: CALLS gets one logged call per element; podman_call <i>
# sets CALL to the arguments of call i
podman_load() {
  local line
  CALLS=()
  [[ -n ${PODMAN_LOG-} && -f $PODMAN_LOG ]] || return 0
  while IFS= read -r line; do CALLS+=("$line"); done <"$PODMAN_LOG"
}
podman_call() { eval "CALL=(${CALLS[$1]})"; }

# podman_find [-x] <arg>...: the last call that starts with these arguments
# (-x: has exactly these arguments); sets FOUND (its index) and CALL
podman_find() {
  local i k exact=0
  local -a want
  if [[ $1 == -x ]]; then exact=1; shift; fi
  want=("$@")
  podman_load
  for (( i = ${#CALLS[@]} - 1; i >= 0; i-- )); do
    podman_call "$i"
    (( ${#CALL[@]} >= ${#want[@]} )) || continue
    (( ! exact || ${#CALL[@]} == ${#want[@]} )) || continue
    for (( k = 0; k < ${#want[@]}; k++ )); do
      [[ ${CALL[k]} == "${want[k]}" ]] || continue 2
    done
    FOUND=$i
    return 0
  done
  return 1
}

# podman_show: the logged calls, one per line, for failure output
podman_show() {
  local i
  podman_load
  for (( i = 0; i < ${#CALLS[@]}; i++ )); do printf 'podman %s\n' "${CALLS[i]}"; done
}

# run_args: RUN gets the arguments of the last `podman run` call
run_args() {
  podman_find run || { podman_show; fail 'no podman run call'; }
  RUN=("${CALL[@]}")
}

# has_opt <option> <value>: RUN holds option and value as neighbors
has_opt() {
  local i
  for (( i = 0; i < ${#RUN[@]} - 1; i++ )); do
    [[ ${RUN[i]} == "$1" && ${RUN[i+1]} == "$2" ]] && return 0
  done
  printf 'podman run lacks: %q %q\n' "$1" "$2" >&2
  podman_show >&2
  return 1
}

# count_v <suffix>: how many -v values in RUN end in <suffix>
count_v() {
  local i n=0
  for (( i = 0; i < ${#RUN[@]} - 1; i++ )); do
    if [[ ${RUN[i]} == -v && ${RUN[i+1]} == *"$1" ]]; then n=$((n + 1)); fi
  done
  echo "$n"
}

# hc_serve_call <container>: find the exact call that starts the core
hc_serve_call() {
  podman_find -x exec -d -e SHELL=/bin/bash -- "$1" hc serve
}

# no_create: pm created no network and no container
no_create() {
  if podman_find network create || podman_find run; then
    podman_show >&2
    fail 'pm created a network or a container'
  fi
}

# ------------------------------------------------------------------ assertions

fail() { printf '%s\n' "$@" >&2; return 1; }

# expect_status <n>: $status of the last run is n, else show its output
expect_status() {
  (( status == $1 )) && return 0
  printf 'status %s, expected %s\n--- stdout\n%s\n--- stderr\n%s\n' \
    "$status" "$1" "$output" "${stderr-}" >&2
  podman_show >&2
  return 1
}

# has_line <text> <line>: <text> holds <line> as a whole line
has_line() {
  grep -qxF -- "$2" <<<"$1" && return 0
  printf 'missing line: %s\nin:\n%s\n' "$2" "$1" >&2
  return 1
}

# is_id <text>: 32 lowercase hex digits
is_id() { [[ $1 =~ ^[0123456789abcdef]{32}$ ]] || fail "not an id: $1"; }

# file_mode <path>: permission bits in octal, e.g. 700
file_mode() { stat -c %a -- "$1" 2>/dev/null || stat -f %Lp -- "$1"; }

# ------------------------------------------------------------------ oracles

# sha256_hex <text>: lowercase hex sha256 of <text>, without a newline
sha256_hex() {
  printf '%s' "$1" | "$PYTHON" -I -c 'import hashlib, sys
print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
}

# ref_id <folder>: devcontainerId from the spec's JavaScript reference
ref_id() { "$NODE" "$PM_TESTS_DIR/devcontainer-id.js" "$1"; }

# ------------------------------------------------------------------ completion

# bash_candidates <word>...: load `pm sh`, run _pm_candidates for these
# words (the last one is being completed), print kind=<kind> and the
# candidates, one per line
bash_candidates() {
  env PATH="${PM_PATH:-$PATH}" "$BASH" -c '
    eval "$("$BASH" "$1" sh)" || exit 1
    shift
    _pm_words=("$@")
    _pm_candidates
    printf "kind=%s\n" "$_pm_kind"
    printf "%s\n" "${_pm_reply[@]}"' _ "$PM_SH" "$@"
}

# zsh_candidates <word>...: the same with the definitions of `pm zsh`, and
# words and CURRENT as the zsh completion system sets them
zsh_candidates() {
  env PATH="${PM_PATH:-$PATH}" "$ZSH" -f -c '
    eval "$("$1" "$2" zsh)" 2>/dev/null
    shift 2
    words=("$@")
    CURRENT=$#
    _pm_candidates
    print -r -- "kind=$REPLY"
    print -rl -- $reply' zsh "$BASH" "$PM_SH" "$@"
}
