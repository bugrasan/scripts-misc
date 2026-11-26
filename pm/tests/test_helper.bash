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
  export PODMAN_LOG=$T/podman.log STUB_STATE=$T/podman-state HC_LOG=$T/hc.log
  export STUB_HASH_LOG=$T/hash.log STUB_PYTHON=$PYTHON
  STUB_BIN=$T/stub-bin FAKE_BIN=$T/fake-bin MIN_BIN=$T/min-bin
  HC=$HOME/.config/herdr-core/container
  P=$T/proj
  mkdir -p "$HOME" "$STUB_BIN" "$FAKE_BIN" "$P"
  mkdir -p "$STUB_STATE"/{containers,networks,status,mounts,labels,pmscript,create,secrets,cores,nohc,nosha,fs,cbin}
  # what the fake podman needs to run pm's in-container scripts
  STUB_SH=$(command -v sh) STUB_BASH=$BASH STUB_HASH_TOOL=$PM_TESTS_DIR/stub/hash-tool
  export STUB_SH STUB_BASH STUB_HASH_TOOL
  : >"$PODMAN_LOG"
  : >"$HC_LOG"
  # the fake podman, and a fake host hc so that no real one is ever reached
  cp -- "$PM_TESTS_DIR/stub/podman" "$STUB_BIN/podman"
  cp -- "$PM_TESTS_DIR/stub/hc" "$STUB_BIN/hc"
  chmod 755 "$STUB_BIN/podman" "$STUB_BIN/hc"
  export PATH=$STUB_BIN:$PATH
  PM_PATH=$FAKE_BIN:$PATH
  # never reach a real podman
  [[ $(command -v podman) == "$STUB_BIN/podman" ]] || fail 'the fake podman is not first in PATH'
  # no host core by default, whatever runs on the test host; a test that
  # wants one fakes ps again: fake ps "printf '%s hc serve\n' $$"
  fake ps 'true'
}

# host_core_up: pm sees a running hc core on this host (a process in its
# own pid namespace)
host_core_up() { fake ps "printf '%s hc serve\n' $$"; }

# PM_PATH without the optional tools pm may use (git, uuidgen, sha256sum,
# shasum, openssl): the fakes, the fake podman, and basic commands only
use_min_path() {
  local t p
  mkdir -p "$MIN_BIN"
  for t in bash env cat mkdir chmod mv rm ln ls cp tr sed grep head tail cut \
    sort wc dirname basename touch stat id uname sleep od readlink ps rmdir; do
    if p=$(type -P "$t"); then ln -sf -- "$p" "$MIN_BIN/$t"; fi
  done
  PM_PATH=$FAKE_BIN:$STUB_BIN:$MIN_BIN
}

# fake <command> <bash code>: a fake command in FAKE_BIN, seen by pm only
fake() {
  printf '#!%s\n%s\n' "$BASH" "$2" >"$FAKE_BIN/$1"
  chmod 755 "$FAKE_BIN/$1"
}

# fake_bash <version>: the bash on PM_PATH reports this version; any other
# call runs the real bash, so #!/usr/bin/env bash scripts keep working
fake_bash() {
  fake bash "if [[ \${1-} == --version ]]; then
  echo 'GNU bash, version $1(1)-release (x86_64-pc-linux-gnu)'
  exit 0
fi
exec $(printf %q "$BASH") \"\$@\""
}

# fake_tool <name> <line>: a fake tool that prints <line> for --version
fake_tool() { fake "$1" "printf '%s\n' $(printf %q "$2")"; }

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
# pm.sh is evaluated without its final `main "$@"` line; grep reads it as
# bytes, as in a test locale such as GBK it drops lines with an n-dash
pm_internal() {
  env PATH="${PM_PATH:-$PATH}" "$BASH" -c \
    'src=$(LC_ALL=C grep -a -vxF -- "$2" "$1") && eval "$src" && shift 2 && "$@"' \
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

# no_hc_serve: fail when pm ran hc serve through podman exec; the core of
# a pm run --hc container is its main command, HC_MAIN (owner decision 1)
no_hc_serve() {
  local i
  podman_load
  for (( i = 0; i < ${#CALLS[@]}; i++ )); do
    podman_call "$i"
    [[ ${CALL[0]} != exec || " ${CALL[*]} " != *'hc serve'* ]] && continue
    podman_show >&2
    fail 'pm ran hc serve through podman exec'
  done
}

# the main command of a pm run --hc container after sh -c; without --hc it
# is sleep infinity
HC_MAIN='exec hc serve >/dev/null 2>&1'

# main_is <image> <arg>...: the last podman run ends with <image> and the
# main command <arg>..., argument by argument
main_is() {
  local -a want=("$@")
  local k n=$#
  run_args
  for (( k = 1; k <= n; k++ )); do
    (( ${#RUN[@]} > k )) && [[ ${RUN[${#RUN[@]}-k]} == "${want[n-k]}" ]] && continue
    printf 'podman run does not end with: %s\n' "$*" >&2
    podman_show >&2
    return 1
  done
}

# fake_container <name> [<pm-hc label> [<mount>...]]: a fake container as
# podman run leaves it, without a podman call in the log; a mount is
# <source> or <source>:<target>; pm no longer reads the label (V9-49), so
# tests pass one only to show that it has no effect
fake_container() {
  printf '\n' >"$STUB_STATE/containers/$1"
  [[ -z ${2-} ]] || printf '%s\n' "$2" >"$STUB_STATE/labels/$1"
  (( $# <= 2 )) || printf '%s\n' "${@:3}" >"$STUB_STATE/mounts/$1"
}

# forget_containers: drop all fake containers, so that the next pm run on
# the same folder is no second container
forget_containers() {
  local d
  for d in containers status mounts labels pmscript create secrets cores nohc nosha; do
    rm -f -- "$STUB_STATE/$d"/*
  done
  # their files go with them
  rm -rf -- "${STUB_STATE:?}"/fs/* "${STUB_STATE:?}"/cbin/*
}

# hc_find [-x] <arg>...: podman_find on the calls of the fake hc
hc_find() { PODMAN_LOG=$HC_LOG podman_find "$@"; }
hc_show() { PODMAN_LOG=$HC_LOG podman_show | sed 's/^podman /hc /'; }

# pm_via <container>: the connection command pm gives hc for a container,
# with a bare podman (owner decision 4)
pm_via() { printf 'podman exec -i %s sh -c\n' "$1"; }

# hc_machine <name> <target> [<via: true|false>]: one machine as hc machine
# ls --json lists it (keys sorted, compact)
hc_machine() {
  printf '{"host":"h","id":"0123","name":%s,"session":null,"state":"connected","target":%s,"temporary":false,"version":"0.1.21","via":%s}' \
    "$(json_str "$1")" "$(json_str "$2")" "${3:-true}"
}

# json_str <text>: <text> as a JSON string (quotes and backslashes only)
json_str() { local s=${1//\\/\\\\}; printf '"%s"' "${s//\"/\\\"}"; }

# ps_row <id>: the line of pm ps output ($output) for a fake container,
# whose ID is its name
ps_row() { grep -m1 -E "^$1 " <<<"$output"; }

# ps_cell <column> <row>: the cell of <row> below <column> of the header
# (the first line of $output), trailing blanks removed; the cells line up
# with the header words, and the next column starts the next cell
ps_cell() {
  local head=${output%%$'\n'*} c pos start=-1 next=-1
  [[ $head == *"$1"* ]] || return 1
  pos=${head%%"$1"*}
  start=${#pos}
  for c in 'CONTAINER ID' NAME STATUS PM NETWORK CONT-HERDR HOST-HERDR SECRET-CC \
    CONFIG-CC SECRET-CP CONFIG-CP PROJECT; do
    [[ $head == *"$c"* ]] || continue
    pos=${head%%"$c"*}
    if (( ${#pos} > start && ( next < 0 || ${#pos} < next ) )); then next=${#pos}; fi
  done
  if (( next < 0 )); then c=${2:start}; else c=${2:start:next-start}; fi
  printf '%s\n' "${c%"${c##*[![:space:]]}"}"
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
