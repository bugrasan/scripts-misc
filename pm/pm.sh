#!/usr/bin/env bash
# pm – podman helper commands for dev containers, with bash and zsh completion.
# Requires podman 6.0 or later and bash 5.2 or later; runs as a command.
# `pm help` lists the subcommands and `pm readme` shows a quick start.
# Install it on PATH as `pm.sh` and add `alias pm=pm.sh`; the completion binds
# to both names.

# refuse to be sourced: `. pm.sh sh` would leak variables, options, and `exit`
# into the calling shell; `return` succeeds in a subshell only when sourced,
# and plain POSIX syntax keeps this block parseable by bash and zsh
if [ -n "${ZSH_VERSION-}" ]; then
  printf '%s\n' 'pm: run this file as a command with bash; do not source it' \
    'load zsh completion with:  eval "$(pm.sh zsh)"' >&2
  return 2 2>/dev/null || exit 2
elif (return 0 2>/dev/null); then
  printf '%s\n' 'pm: run this file as a command with bash; do not source it' \
    'load bash completion with:  eval "$(pm.sh sh)"' >&2
  return 2
fi

PM_VERSION=9

# an exported CDPATH would make `cd` pick another directory and print it
unset CDPATH

# ------------------------------------------------------------------ config

# Secret names and the environment variables they land in inside the container.
# Override any of these by exporting them in your environment.
: "${PM_CC_SECRET:=cc_token}"
: "${PM_CC_TARGET:=CLAUDE_CODE_OAUTH_TOKEN}"
: "${PM_CP_SECRET:=cp_token}"
: "${PM_CP_TARGET:=COPILOT_GITHUB_TOKEN}"

# Local files copied by `pm cp-claude` and `pm cp-copilot`.
: "${PM_CLAUDE_MD:=$HOME/.claude/CLAUDE.md}"
: "${PM_CLAUDE_SETTINGS:=$HOME/.claude/settings.json.template}"
: "${PM_COPILOT_SETTINGS:=$HOME/.copilot/settings.json.template}"

# ------------------------------------------------------------------ helpers

# print a usage block to stderr; callers return 2 afterwards
_pm_usage() { printf '%s\n' "$1" >&2; }

# true when any argument asks for help
_pm_wants_help() {
  local a
  for a; do [[ $a == -h || $a == --help ]] && return 0; done
  return 1
}

# status lines for copy results; color only on a terminal and without NO_COLOR
_pm_ok() {
  if [[ -t 1 && -z ${NO_COLOR-} ]]; then
    printf '\033[32mok\033[0m    %s\n' "$1"
  else
    printf 'ok    %s\n' "$1"
  fi
}

_pm_err() {
  if [[ -t 2 && -z ${NO_COLOR-} ]]; then
    printf '\033[31merror\033[0m %s\n' "$1" >&2
  else
    printf 'error %s\n' "$1" >&2
  fi
}

_pm_skip() { printf 'skip  %s\n' "$1"; }

# copy files into a running container below /home/vscode/<dir>, creating
# <dir> first; $1 = container, $2 = dir, then triples: source, destination
# file name, required (1) or optional (0); returns 1 if any copy failed
_pm_put_files() {
  local c=$1 dir=$2 rc=0 src dst req out s
  shift 2
  # stderr stays out of the parsed value: podman warnings would corrupt it
  if ! out=$(podman container inspect --format '{{.State.Running}}' -- "$c" 2>/dev/null); then
    out=$(podman container inspect -- "$c" 2>&1 >/dev/null)
    _pm_err "$c: $out"
    return 1
  fi
  if [[ $out != true ]]; then
    _pm_err "$c: container is not running; start it with: pm start $c"
    return 1
  fi
  out=$(podman exec "$c" mkdir -p "/home/vscode/$dir" 2>&1) \
    || { _pm_err "$c: mkdir -p /home/vscode/$dir: $out"; return 1; }

  while (( $# >= 3 )); do
    src=$1 dst=/home/vscode/$dir/$2 req=$3
    shift 3
    if [[ ! -e $src ]]; then
      if (( req )); then _pm_err "$src: not found"; rc=1
      else _pm_skip "$src: not found"; fi
      continue
    fi
    if [[ ! -f $src || ! -r $src ]]; then
      _pm_err "$src: not a readable file"; rc=1
      continue
    fi
    # ./ keeps podman from reading a relative name with ':' as container:path
    s=$src
    [[ $s == /* ]] || s=./$s
    if out=$(podman cp -- "$s" "$c:$dst" 2>&1); then
      _pm_ok "$src -> $c:$dst"
    else
      _pm_err "$src -> $c:$dst: $out"
      rc=1
    fi
  done
  return $rc
}

_pm_need_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  printf 'pm: jq is required for this view\n' >&2
  return 1
}

# completion file targets; bash-completion reads only BASH_COMPLETION_USER_DIR
# when it is set, so its first entry wins over the XDG default
_pm_bash_file() {
  local dir=${BASH_COMPLETION_USER_DIR-}
  dir=${dir%%:*}
  [[ -n $dir ]] || dir=${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion
  printf '%s\n' "$dir/completions/pm.bash"
}

_pm_zsh_file() {
  printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/zsh/site-functions/_pm"
}

# ------------------------------------------------------------------ herdr-core

# sha256 of stdin as 64 lowercase hex digits, from the first tool found;
# each tool prints the digest as its first field
_pm_sha256() {
  local out h
  if command -v sha256sum >/dev/null 2>&1; then out=$(sha256sum)
  elif command -v shasum >/dev/null 2>&1; then out=$(shasum -a 256)
  elif command -v openssl >/dev/null 2>&1; then out=$(openssl dgst -sha256 -r)
  else
    _pm_err 'no sha256 tool found; install sha256sum, shasum, or openssl'
    return 1
  fi || return 1
  read -r h _ <<<"$out"
  # accept only a digest: other output, such as an error text, would give
  # a wrong state folder name or break the base-32 conversion
  if [[ ${#h} != 64 || $h == *[!0123456789abcdef]* ]]; then
    _pm_err "unexpected sha256 output: $out"
    return 1
  fi
  printf '%s\n' "$h"
}

# $1 as a JSON string with the escapes of JSON.stringify, which the
# devcontainer CLI hashes: \\ \" \b \f \n \r \t, other control characters
# as \u00xx; everything else stays as it is; LC_ALL=C works on bytes, as
# a multibyte locale such as GBK can hide a \ inside a character
_pm_json_str() {
  local s=$1 i h c LC_ALL=C
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//$'\b'/\\b}; s=${s//$'\f'/\\f}; s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
  for (( i = 1; i < 32; i++ )); do
    printf -v h '%02x' "$i"
    printf -v c %b "\\x$h"
    s=${s//"$c"/\\u00$h}
  done
  printf '"%s"' "$s"
}

# the devcontainer CLI's ${devcontainerId} for the local folder $1 and the
# config file $1/.devcontainer/devcontainer.json: the sha256 of the sorted
# id labels as JSON, read as a 256-bit number and written in base 32
_pm_devcontainer_id() {
  local d=0123456789abcdefghijklmnopqrstuv json hex out='' i j v
  json="{\"devcontainer.config_file\":$(_pm_json_str "$1/.devcontainer/devcontainer.json"),"
  json+="\"devcontainer.local_folder\":$(_pm_json_str "$1")}"
  hex=$(printf '%s' "$json" | _pm_sha256) || return 1
  # a leading 0 makes 65 hex digits: 13 groups of 20 bits, 4 digits each
  hex=0$hex
  for (( i = 0; i < 65; i += 5 )); do
    v=$(( 16#${hex:i:5} ))
    for (( j = 15; j >= 0; j -= 5 )); do out+=${d:$(( (v >> j) & 31 )):1}; done
  done
  printf '%s\n' "$out"
}

# prepare the herdr-core identity of the mount folder $1 as the dev
# container template's initializeCommand does: keep or write the id file,
# then create the state folder; sets _pm_hc_file and _pm_hc_state
_pm_hc_prepare() {
  local abs=$1 rel f id='' old=0 new=0 h tmp rc=0
  local cfg=$HOME/.config/herdr-core
  # the dev container keeps the id file in .devcontainer, else the root
  if [[ -d $abs/.devcontainer ]]; then rel=.devcontainer/herdr-machine-id
  else rel=herdr-machine-id; fi
  f=$abs/$rel

  # never touch what is not a regular file or cannot be read
  if [[ -e $f || -L $f ]]; then
    [[ -f $f ]] || { _pm_err "$f: not a regular file"; return 1; }
    [[ -r $f ]] || { _pm_err "$f: not readable"; return 1; }
    id=$(<"$f")
    old=1
  fi
  # valid: 32 lowercase hex digits once $(<) dropped trailing newlines
  if [[ ${#id} != 32 || $id == *[!0123456789abcdef]* ]]; then
    # a new id as the template makes it: uuidgen, else the kernel's uuid,
    # without dashes and lowercased
    id=$(uuidgen 2>/dev/null) || id=$(cat /proc/sys/kernel/random/uuid 2>/dev/null) || id=''
    id=${id//-/}
    id=${id,,}
    if [[ ${#id} != 32 || $id == *[!0123456789abcdef]* ]]; then
      _pm_err 'cannot make a herdr-core machine-id with uuidgen or /proc/sys/kernel/random/uuid'
      return 1
    fi
    # a temp file and mv, so a failed write never leaves a partial file
    tmp=${f%/*}/.herdr-machine-id.$$
    if ! printf '%s\n' "$id" >"$tmp" || ! mv -f -- "$tmp" "$f"; then
      rm -f -- "$tmp"
      _pm_err "cannot write $f"
      return 1
    fi
    if (( old )); then
      printf 'pm run: note: replaced the invalid herdr-core machine-id: %s\n' "$f" >&2
    else
      printf 'pm run: note: wrote a new herdr-core machine-id: %s\n' "$f" >&2
    fi
  fi

  # the id belongs to this host; note when git would pick the file up
  if command -v git >/dev/null 2>&1 \
    && [[ $(git -C "$abs" rev-parse --is-inside-work-tree 2>/dev/null) == true ]]; then
    git -C "$abs" check-ignore -q -- "$rel" 2>/dev/null || rc=$?
    if (( rc == 1 )); then
      printf 'pm run: note: git does not ignore %s; add it to .gitignore\n' "$f" >&2
    fi
  fi

  # state folder per devcontainerId, else per id; $HOME/.config even with
  # XDG_CONFIG_HOME set, as the dev container mounts it from there
  if [[ $rel == .devcontainer/* ]]; then h=$(_pm_devcontainer_id "$abs") || return 1
  else h=$(printf '%s' "$id" | _pm_sha256) || return 1; fi
  _pm_hc_state=$cfg/container/${abs##*/}-$h
  [[ -d $_pm_hc_state ]] || new=1
  # mode 700 as the template sets it: the state holds terminal output, which
  # may contain secrets; `--` comes first, as BSD chmod stops parsing options
  # at the mode and would take a later `--` for a file
  if ! mkdir -p -- "$_pm_hc_state" || ! chmod -- 700 "$cfg" "$_pm_hc_state"; then
    _pm_err "cannot prepare the herdr-core state folder $_pm_hc_state"
    return 1
  fi
  if (( new )); then
    printf 'pm run: note: new herdr-core state folder: %s\n' "$_pm_hc_state" >&2
  fi
  _pm_hc_file=$f
}

# ------------------------------------------------------------------ pm run

pm_run() {
  local cc=0 cp=0 hc=0 mnt='' net='' image='' name='' npos=0 endflags=0
  local help="usage: pm run [--cc] [--cp] [--hc] [--mount <dir>] [--net <name>] <image> [<container-name>]

  --cc              pass the Claude Code token as a podman secret
  --cp              pass the GitHub Copilot token as a podman secret
  --hc              give the container a stable herdr-core identity and start
                    the herdr-core core in it; needs --mount, see herdr-core
  --mount <dir>     mount <dir> at /workspaces/<foldername> and, if it exists,
  --mnt <dir>       <dir>/../<foldername>.worktrees at
                    /workspaces/<foldername>.worktrees; unless a name is given,
                    call the container pm-<foldername>
  --net <name>      network name; default with --mount: the folder name with
                    characters podman rejects replaced by -, and pm- in front
                    when it starts with no letter or digit or is reserved by
                    podman (e.g. bridge, host, none)
  <image>           image to run, e.g. mcr.microsoft.com/devcontainers/base:bookworm
  <container-name>  name for the new container; required without --mount

network isolation:
  with --mount or --net, the container joins a bridge network created with
  -o isolate=strict and the label pm-script=$PM_VERSION; pm reuses an
  existing network with that label and notes other containers on it; it
  refuses a network without the label, with another driver, or with an
  isolate value other than strict
  without --mount and --net, the container uses podman's default network
  mode and is not isolated
  pm rm removes the network once no container uses it
  if podman run fails, pm removes the container and network it created

herdr-core:
  with --hc, an id file and a state folder on the host keep the identity;
  with a <dir>/.devcontainer folder, at the dev container template's paths:
    id file       <dir>/.devcontainer/herdr-machine-id
    state folder  ~/.config/herdr-core/container/<foldername>-<devcontainerId>
  without it:
    id file       <dir>/herdr-machine-id
    state folder  ~/.config/herdr-core/container/<foldername>-<sha256 of id>
  pm writes a missing or invalid id file, creates a missing state folder,
  mounts the id file at /etc/machine-id (read-only) and the state folder at
  /home/vscode/.local/state/herdr-core, and after podman run starts the
  core with: podman exec -d -e SHELL=/bin/bash <container> hc serve
  only one core runs per state folder, and hc in every container that
  mounts it uses that core; pm notes podman containers that already mount
  it, but does not detect containers of other engines, such as Docker
  pm keeps the id file and the state folder on rollback and on pm rm

runs: podman network create -o isolate=strict --label pm-script=$PM_VERSION <network>
      podman run -d --init --userns=keep-id --label pm-script=$PM_VERSION
      [--network <network>] [-v ...] [--secret ...] --name <container-name>
      <image> sleep infinity
      with --hc: podman exec -d -e SHELL=/bin/bash <container-name> hc serve
then: pm bash <container-name>"
  # --init forwards signals to `sleep infinity`, so pm stop does not wait
  # for the SIGKILL timeout; keep-id maps the host UID/GID into the
  # container so bind-mounted files keep their ownership (rootless podman
  # only); the label records the pm version that created the container
  local opts=(-d --init --userns=keep-id --label "pm-script=$PM_VERSION")
  # characters podman accepts in container and network names; explicit
  # lists avoid locale-dependent ranges
  local alnum='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
  local ok=$alnum'_.-'

  _pm_wants_help "$@" && { printf '%s\n' "$help"; return 0; }
  # flags in any position; `--` ends flag parsing
  while (( $# )); do
    if (( endflags == 0 )); then
      case $1 in
        --cc)  cc=1; shift; continue ;;
        --cp)  cp=1; shift; continue ;;
        --hc)  hc=1; shift; continue ;;
        --mount|--mnt|--mount=*|--mnt=*)
          if [[ -n $mnt ]]; then _pm_usage "pm run: --mount given twice"$'\n\n'"$help"; return 2; fi
          if [[ $1 == *=* ]]; then mnt=${1#*=}; shift
          else mnt=${2-}; shift; (( $# )) && shift; fi
          if [[ -z $mnt ]]; then _pm_usage "pm run: --mount needs a directory"$'\n\n'"$help"; return 2; fi
          continue ;;
        --net|--net=*)
          if [[ -n $net ]]; then _pm_usage "pm run: --net given twice"$'\n\n'"$help"; return 2; fi
          if [[ $1 == *=* ]]; then net=${1#*=}; shift
          else net=${2-}; shift; (( $# )) && shift; fi
          # podman's rule: a letter or digit, then letters, digits, _ . -
          if [[ $net != ["$alnum"]* || $net == *[^"$ok"]* ]]; then
            _pm_usage "pm run: invalid network name '$net'"$'\n\n'"$help"
            return 2
          fi
          continue ;;
        --)    endflags=1; shift; continue ;;
        -*)    _pm_usage "pm run: unknown option $1"$'\n\n'"$help"; return 2 ;;
      esac
    fi
    case $npos in
      0) image=$1 ;;
      1) name=$1 ;;
      *) _pm_usage "pm run: unexpected argument $1"$'\n\n'"$help"; return 2 ;;
    esac
    npos=$((npos + 1))
    shift
  done

  # the herdr-core paths derive from the mounted folder
  if (( hc )) && [[ -z $mnt ]]; then
    _pm_usage "pm run: --hc needs --mount"$'\n\n'"$help"
    return 2
  fi

  if [[ -n $mnt ]]; then
    # podman reads a relative path as a volume name, so resolve it first
    local abs base wt
    abs=$(cd -- "$mnt" 2>/dev/null && pwd) \
      || { _pm_usage "pm run: no such directory: $mnt"$'\n\n'"$help"; return 2; }
    base=${abs##*/}
    if [[ -z $base ]]; then _pm_usage "pm run: cannot derive a name from $abs"; return 2; fi
    opts+=(-v "$abs:/workspaces/$base")
    # sibling worktrees folder: mounted when present, noted when missing
    wt=${abs%/*}/$base.worktrees
    if [[ ! -d $wt ]]; then
      # for a symlinked <dir>, `..` resolves physically, as git does
      local phys
      phys=$(cd -P -- "$abs/.." 2>/dev/null && pwd)/$base.worktrees
      [[ -d $phys ]] && wt=$phys
    fi
    if [[ -d $wt ]]; then
      opts+=(-v "$wt:/workspaces/$base.worktrees")
    else
      printf 'pm run: note: no worktrees folder %s; not mounted\n' "$wt" >&2
    fi
    # explicit names win; otherwise the folder name, stripped of characters
    # podman does not accept, names the network and, after pm-, the container
    [[ -n $name ]] || name=pm-${base//[^$ok]/-}
    if [[ -z $net ]]; then
      net=${base//[^$ok]/-}
      # podman wants a letter or digit first and refuses network mode names
      case $net in
        none|host|bridge|private|slirp4netns|pasta|container|ns|default) net=pm-$net ;;
        ["$alnum"]*) ;;
        *) net=pm-$net ;;
      esac
    fi
  fi

  # guard: an image is always required, a name only when --mount cannot supply one
  if [[ -z $image || -z $name ]]; then _pm_usage "$help"; return 2; fi
  if podman container exists -- "$name" 2>/dev/null; then
    _pm_err "container $name exists; remove it with: pm rm $name"
    return 1
  fi

  # herdr-core files are ready before pm creates anything in podman
  if (( hc )); then
    _pm_hc_prepare "$abs" || return 1
    opts+=(-v "$_pm_hc_file:/etc/machine-id:ro"
      -v "$_pm_hc_state:/home/vscode/.local/state/herdr-core")
    # one core per state folder: hc in every container that mounts it uses
    # the core that holds its lock, so name the containers that mount it
    # already; podman matches a bind source only in the source:target form,
    # and podman ps sees no containers of other engines, such as Docker
    local hcusers
    hcusers=$(podman ps -a --filter "volume=$_pm_hc_state:/home/vscode/.local/state/herdr-core" \
      --format '{{.Names}}' 2>/dev/null)
    [[ -z $hcusers ]] || printf 'pm run: note: the herdr-core state folder %s is already mounted by: %s; only one hc serve can run for it, and hc in every such container uses that core\n' \
      "$_pm_hc_state" "${hcusers//$'\n'/, }" >&2
  fi

  # one --secret per requested token; podman exposes each as an env var
  (( cc )) && opts+=(--secret "$PM_CC_SECRET,type=env,target=$PM_CC_TARGET")
  (( cp )) && opts+=(--secret "$PM_CP_SECRET,type=env,target=$PM_CP_TARGET")

  # own isolated network: reuse one that pm created, refuse others
  _pm_run_net=''
  if [[ -n $net ]]; then
    local sep=$'\x1f' info n label driver iso users
    # inspect also matches ID prefixes, so compare the returned name
    info=$(podman network inspect --format \
      "{{.Name}}$sep{{index .Labels \"pm-script\"}}$sep{{.Driver}}$sep{{index .Options \"isolate\"}}" \
      -- "$net" 2>/dev/null)
    IFS=$sep read -r n label driver iso <<<"$info"
    if [[ -n $info && $n == "$net" ]]; then
      if [[ -z $label ]]; then
        _pm_err "network $net exists but was not created by pm; choose another with --net"
        return 1
      fi
      # blank isolate: not set, podman 6 documents strict as the default
      if [[ $driver != bridge || ( -n $iso && $iso != strict ) ]]; then
        _pm_err "network $net is not an isolated bridge (driver $driver, isolate ${iso:-unset}); choose another with --net"
        return 1
      fi
      users=$(podman ps -a --filter "network=$net" --format '{{.Names}}' 2>/dev/null)
      [[ -z $users ]] || printf 'pm run: note: network %s is shared with: %s\n' "$net" "${users//$'\n'/, }" >&2
    else
      podman network create -o isolate=strict --label "pm-script=$PM_VERSION" -- "$net" >/dev/null \
        || return 1
      _pm_run_net=$net
    fi
    opts+=(--network "$net")
  fi

  # Ctrl-C during a long image pull must not leave the new network behind
  _pm_run_name=$name
  trap '_pm_run_rollback; exit 130' INT
  if ! podman run "${opts[@]}" --name "$name" "$image" sleep infinity; then
    trap - INT
    _pm_run_rollback
    return 1
  fi
  trap - INT

  # hc serve runs the core in the foreground, hence -d, and sleep infinity
  # stays the main process; podman sets no SHELL, and the core starts new
  # shells from its own, else /bin/sh; on failure the container stays, as
  # it runs fine without the core
  if (( hc )); then
    local out
    if out=$(podman exec -d -e SHELL=/bin/bash -- "$name" hc serve 2>&1); then
      _pm_ok "hc serve started in $name"
    else
      _pm_err "$name: hc serve: $out"
      return 1
    fi
  fi
}

# undo a failed pm run: the container it left in created state, then the
# network this call created; uses _pm_run_name and _pm_run_net
_pm_run_rollback() {
  local out
  podman container exists -- "$_pm_run_name" 2>/dev/null \
    && podman rm -f -- "$_pm_run_name" >/dev/null 2>&1
  [[ -n ${_pm_run_net-} ]] || return 0
  out=$(podman network rm -- "$_pm_run_net" 2>&1) \
    || _pm_err "network $_pm_run_net: $out"
}

# ------------------------------------------------------------------ pm start / stop / bash

pm_start() {
  local help='usage: pm start <container>

  <container>  container to start; completion lists non-running containers

runs: podman start <container>
note: containers keep the labels, mounts, and secrets they were created with'
  _pm_wants_help "$@" && { printf '%s\n' "$help"; return 0; }
  if [[ $# -ne 1 || -z $1 || $1 == -* ]]; then _pm_usage "$help"; return 2; fi
  podman start -- "$1"
}

pm_stop() {
  local help='usage: pm stop <container>

  <container>  container to stop; completion lists running containers

runs: podman stop <container>'
  _pm_wants_help "$@" && { printf '%s\n' "$help"; return 0; }
  if [[ $# -ne 1 || -z $1 || $1 == -* ]]; then _pm_usage "$help"; return 2; fi
  podman stop -- "$1"
}

pm_bash() {
  local help='usage: pm bash <container>

opens an interactive bash terminal in a running container

  <container>  running container; completion lists running containers only

runs: podman exec -it <container> bash'
  _pm_wants_help "$@" && { printf '%s\n' "$help"; return 0; }
  if [[ $# -ne 1 || -z $1 || $1 == -* ]]; then _pm_usage "$help"; return 2; fi
  podman exec -it -- "$1" bash
}

# ------------------------------------------------------------------ pm rm / net

pm_rm() {
  local help='usage: pm rm [--force] <container>

removes a container, then each network pm created for it once no other
container uses that network

  --force      stop a running container first
  <container>  container to remove; completion lists all containers

runs: podman rm [-f] <container>
      podman network rm <network>'
  local force=0 c='' a out state net label users rc=0
  local -a lines rmopt=()
  _pm_wants_help "$@" && { printf '%s\n' "$help"; return 0; }
  # pm's force options are long only, so -f falls under unknown options
  for a; do
    case $a in
      --force) force=1 ;;
      -*)      _pm_usage "$help"; return 2 ;;
      *)       [[ -z $c ]] || { _pm_usage "$help"; return 2; }; c=$a ;;
    esac
  done
  [[ -n $c ]] || { _pm_usage "$help"; return 2; }

  # read state and networks first: both vanish with the container
  # stderr stays out of the parsed lines: podman warnings would corrupt them
  if ! out=$(podman container inspect --format \
    '{{.State.Status}}{{range $k, $v := .NetworkSettings.Networks}}{{"\n"}}{{$k}}{{end}}' \
    -- "$c" 2>/dev/null); then
    out=$(podman container inspect -- "$c" 2>&1 >/dev/null)
    _pm_err "container $c: $out"
    return 1
  fi
  mapfile -t lines <<<"$out"
  state=${lines[0]}
  if [[ $state == running || $state == paused ]] && (( ! force )); then
    _pm_err "container $c is $state; stop it with: pm stop $c, or use: pm rm --force $c"
    return 1
  fi
  (( force )) && rmopt=(-f)
  if out=$(podman rm "${rmopt[@]}" -- "$c" 2>&1); then
    _pm_ok "container $c removed"
  else
    _pm_err "container $c: $out"
    return 1
  fi

  # only networks with the pm-script label; podman's own stay untouched
  for net in "${lines[@]:1}"; do
    [[ -n $net ]] || continue
    label=$(podman network inspect --format '{{index .Labels "pm-script"}}' "$net" 2>/dev/null) \
      || continue
    [[ -n $label ]] || continue
    users=$(podman ps -a --filter "network=$net" --format '{{.Names}}' 2>/dev/null)
    if [[ -n $users ]]; then
      _pm_skip "network $net: still used by ${users//$'\n'/, }"
      continue
    fi
    if out=$(podman network rm -- "$net" 2>&1); then
      _pm_ok "network $net removed"
    else
      _pm_err "network $net: $out"
      rc=1
    fi
  done
  return $rc
}

pm_net() {
  local help="usage: pm net

lists all networks with the containers attached to each

  NETWORK     network name; a name in parentheses groups containers that
              use no named network by their network mode, e.g. (pasta)
  ISOLATE     value of the network's isolate option; blank when not set,
              and podman 6 documents strict as the default
  CONTAINERS  name (state); podman's states, e.g. running, created (never
              started), exited (stopped), paused"
  local sep=$'\x1f' names ids n iso name state mode list key w=7 iw=7 i
  local -a nets isos keys arr
  local -A members=() known=()
  _pm_wants_help "$@" && { printf '%s\n' "$help"; return 0; }
  (( $# == 0 )) || { _pm_usage "$help"; return 2; }

  names=$(podman network ls --format '{{.Name}}') || return 1
  if [[ -n $names ]]; then
    # shellcheck disable=SC2086  # names is a newline-separated list
    while IFS=$sep read -r n iso; do
      nets+=("$n") isos+=("$iso")
      known[$n]=1
    done < <(podman network inspect --format "{{.Name}}$sep{{index .Options \"isolate\"}}" $names)
  fi

  ids=$(podman ps -a -q) || return 1
  if [[ -n $ids ]]; then
    # shellcheck disable=SC2086  # ids is a newline-separated list
    while IFS=$sep read -r name state mode list; do
      # no named network: group by network mode instead
      [[ -n $list ]] || list=$mode
      IFS=, read -r -a arr <<<"$list"
      for key in "${arr[@]}"; do
        [[ -n $key ]] || continue
        [[ -v members[$key] ]] || keys+=("$key")
        members[$key]+="${members[$key]:+, }$name ($state)"
      done
    done < <(podman container inspect --format \
      "{{.Name}}$sep{{.State.Status}}$sep{{.HostConfig.NetworkMode}}$sep{{range \$k, \$v := .NetworkSettings.Networks}}{{\$k}},{{end}}" $ids)
  fi

  # pseudo rows for modes and names that are not networks, e.g. (pasta)
  for key in "${keys[@]}"; do
    [[ -v known[$key] ]] && continue
    nets+=("($key)") isos+=('')
    members["($key)"]=${members[$key]}
  done

  for (( i = 0; i < ${#nets[@]}; i++ )); do
    (( ${#nets[i]} > w )) && w=${#nets[i]}
    (( ${#isos[i]} > iw )) && iw=${#isos[i]}
  done
  printf "%-${w}s  %-${iw}s  %s\n" NETWORK ISOLATE CONTAINERS
  for (( i = 0; i < ${#nets[@]}; i++ )); do
    printf "%-${w}s  %-${iw}s  %s\n" "${nets[i]}" "${isos[i]}" "${members[${nets[i]}]-}"
  done
}

# ------------------------------------------------------------------ pm ps

# table of containers; $1 = 1 for all, 0 for running only
_pm_ps_table() {
  local all=$1 ids fmt sep=$'\x1f' id name status pm folder mounts project
  local m w=4 pw=2 i n
  local -a ms r_id r_name r_status r_pm r_project
  if (( all )); then ids=$(podman ps -a -q) || return 1
  else ids=$(podman ps -q) || return 1; fi

  if [[ -n $ids ]]; then
    # one inspect call for every container; fields split by the unit
    # separator, so empty fields survive `read`
    fmt="{{printf \"%.12s\" .ID}}$sep{{.Name}}$sep{{.State.Status}}$sep"
    fmt+="{{index .Config.Labels \"pm-script\"}}$sep"
    fmt+="{{index .Config.Labels \"devcontainer.local_folder\"}}$sep"
    fmt+='{{range .Mounts}}{{.Destination}}={{.Source}};{{end}}'
    # shellcheck disable=SC2086  # ids is a newline-separated list
    while IFS=$sep read -r id name status pm folder mounts; do
      # project: devcontainer label, else the host folder mounted at
      # /workspaces/<name>, ignoring the worktrees mount
      project=$folder
      if [[ -z $project ]]; then
        IFS=';' read -r -a ms <<<"$mounts"
        for m in "${ms[@]}"; do
          if [[ ${m%%=*} == /workspaces/* && ${m%%=*} != *.worktrees ]]; then
            project=${m#*=}
            break
          fi
        done
      fi
      n=${#r_id[@]}
      r_id[n]=$id r_name[n]=$name r_status[n]=$status r_pm[n]=$pm r_project[n]=$project
      (( ${#name} > w )) && w=${#name}
      (( ${#pm} > pw )) && pw=${#pm}
    done < <(podman container inspect --format "$fmt" $ids)
  fi

  printf "%-12s  %-${w}s  %-10s  %-${pw}s  %s\n" 'CONTAINER ID' NAME STATUS PM PROJECT
  for (( i = 0; i < ${#r_id[@]}; i++ )); do
    printf "%-12s  %-${w}s  %-10s  %-${pw}s  %s\n" \
      "${r_id[i]}" "${r_name[i]}" "${r_status[i]}" "${r_pm[i]}" "${r_project[i]}"
  done
}

# podman inspect JSON for one container, or for all when $1 is empty
_pm_inspect_json() {
  local ids
  if [[ -n $1 ]]; then podman container inspect -- "$1"; return; fi
  ids=$(podman ps -a -q) || return 1
  if [[ -z $ids ]]; then printf '[]\n'; return 0; fi
  # shellcheck disable=SC2086  # ids is a newline-separated list
  podman container inspect $ids
}

pm_ps() {
  local help='usage: pm ps [-a | --all]
       pm ps <container>
       pm ps labels | mounts | ns | id [<container>]

  (none)       table of running containers
  -a, --all    the same table for all containers
  <container>  full podman inspect JSON of one container
  labels       labels; devcontainer.metadata is parsed into JSON
  mounts       mounts: type, source, destination, rw
  ns           namespace IDs, as podman ps --ns shows them
  id           the full container ID; name/id pairs for all containers

without <container>, labels, mounts, ns, and id cover all containers

table columns:
  PM       value of the pm-script label: the pm version that created it
  PROJECT  label devcontainer.local_folder, else the host folder mounted
           at /workspaces/<foldername>

needs: jq for every view except the table
note: a container named labels, mounts, ns, or id cannot be shown with
      pm ps <container>'
  local view c json

  _pm_wants_help "$@" && { printf '%s\n' "$help"; return 0; }
  case ${1-} in
    '')        (( $# == 0 )) || { _pm_usage "$help"; return 2; }
               _pm_ps_table 0; return ;;
    -a|--all)  (( $# == 1 )) || { _pm_usage "$help"; return 2; }
               _pm_ps_table 1; return ;;
    -*)        _pm_usage "pm ps: unknown option $1"$'\n\n'"$help"; return 2 ;;
    labels|mounts|ns|id)
               view=$1 c=${2-}
               [[ $# -le 2 && $c != -* ]] || { _pm_usage "$help"; return 2; } ;;
    *)         (( $# == 1 )) || { _pm_usage "$help"; return 2; }
               view=full c=$1 ;;
  esac

  _pm_need_jq || return 1
  case $view in
    full)
      json=$(_pm_inspect_json "$c") || return 1
      printf '%s\n' "$json" | jq '.[0]' ;;
    labels)
      json=$(_pm_inspect_json "$c") || return 1
      printf '%s\n' "$json" | jq '
        .[] | { name: .Name,
                labels: ((.Config.Labels // {})
                  | with_entries(
                      if .key == "devcontainer.metadata"
                      then .value |= (try fromjson catch .)
                      else . end)) }' ;;
    mounts)
      json=$(_pm_inspect_json "$c") || return 1
      printf '%s\n' "$json" | jq '
        .[] | { name: .Name,
                mounts: [ (.Mounts // [])[]
                  | { type: .Type, source: .Source,
                      destination: .Destination, rw: .RW } ] }' ;;
    id)
      json=$(_pm_inspect_json "$c") || return 1
      if [[ -n $c ]]; then
        printf '%s\n' "$json" | jq -r '.[0].Id'
      else
        printf '%s\n' "$json" | jq '.[] | { name: .Name, id: .Id }'
      fi ;;
    ns)
      # podman ps --ns is the only source of namespace IDs; resolve the
      # container to its full ID first so names and ID prefixes both work
      local id=''
      if [[ -n $c ]]; then
        json=$(_pm_inspect_json "$c") || return 1
        id=$(printf '%s\n' "$json" | jq -r '.[0].Id') || return 1
      fi
      json=$(podman ps -a --ns --format json) || return 1
      printf '%s\n' "$json" | jq --arg id "$id" '
        .[] | select($id == "" or .Id == $id)
        | { name: .Names[0], namespaces: (.Namespaces // {}) }' ;;
  esac
}

# ------------------------------------------------------------------ pm cp

pm_cp() {
  local help='usage: pm cp <container> <local-file> <dest-name>

  <container>   target container, running or stopped
  <local-file>  file on this machine
  <dest-name>   path below /home/vscode/ inside the container

runs: podman cp <local-file> <container>:/home/vscode/<dest-name>
note: the parent directory of the destination must already exist'
  _pm_wants_help "$@" && { printf '%s\n' "$help"; return 0; }
  # guard: exactly three non-empty args, no options
  if [[ $# -ne 3 || -z $1 || -z $2 || -z $3 || $1 == -* ]]; then _pm_usage "$help"; return 2; fi
  # ./ keeps podman from reading a relative name with ':' as container:path
  local src=$2
  [[ $src == /* ]] || src=./$src
  podman cp -- "$src" "$1:/home/vscode/$3"
}

# ------------------------------------------------------ pm cp-claude / cp-copilot

pm_cp_claude() {
  local help="usage: pm cp-claude <container>     (alias: pm cp-cc)

copies into a running container:
  $PM_CLAUDE_MD
    -> /home/vscode/.claude/CLAUDE.md
  $PM_CLAUDE_SETTINGS
    -> /home/vscode/.claude/settings.json  (skipped when missing)

  <container>  running container; completion lists running containers only

creates /home/vscode/.claude first with: podman exec <container> mkdir -p
sources: PM_CLAUDE_MD and PM_CLAUDE_SETTINGS"
  _pm_wants_help "$@" && { printf '%s\n' "$help"; return 0; }
  if [[ $# -ne 1 || -z $1 || $1 == -* ]]; then _pm_usage "$help"; return 2; fi
  _pm_put_files "$1" .claude \
    "$PM_CLAUDE_MD" CLAUDE.md 1 \
    "$PM_CLAUDE_SETTINGS" settings.json 0
}

pm_cp_copilot() {
  local help="usage: pm cp-copilot <container>     (alias: pm cp-cp)

copies into a running container:
  $PM_CLAUDE_MD
    -> /home/vscode/.copilot/copilot-instructions.md
  $PM_COPILOT_SETTINGS
    -> /home/vscode/.copilot/settings.json  (skipped when missing)

  <container>  running container; completion lists running containers only

creates /home/vscode/.copilot first with: podman exec <container> mkdir -p
sources: PM_CLAUDE_MD and PM_COPILOT_SETTINGS"
  _pm_wants_help "$@" && { printf '%s\n' "$help"; return 0; }
  if [[ $# -ne 1 || -z $1 || $1 == -* ]]; then _pm_usage "$help"; return 2; fi
  _pm_put_files "$1" .copilot \
    "$PM_CLAUDE_MD" copilot-instructions.md 1 \
    "$PM_COPILOT_SETTINGS" settings.json 0
}

# ------------------------------------------------------ pm secret-cc / secret-cp

# prompt for a token without echo and store it as a podman secret
# $1 = subcommand, $2 = secret name, $3 = target env var, $4 = label, rest = args
pm_secret() {
  local sub=$1 secret=$2 target=$3 label=$4 tok
  shift 4
  local help="usage: pm $sub

prompts for the $label token without echo and stores it as the podman
secret $secret; pm run --${sub#secret-} exposes it as \$$target

  - not recommended: any agent in the container can read its own
    environment variables, including this token
  - an existing secret of that name is replaced, so this adds and rotates
  - podman documents that existing containers keep the old token; only
    containers created afterwards are sure to get the new one

runs: podman secret create [--replace] $secret -"
  _pm_wants_help "$@" && { printf '%s\n' "$help"; return 0; }
  if (( $# )); then _pm_usage "$help"; return 2; fi

  printf '%s token (input hidden): ' "$label" >&2
  IFS= read -r -s tok
  printf '\n' >&2
  # trim surrounding whitespace from the pasted value
  tok=${tok#"${tok%%[![:space:]]*}"}
  tok=${tok%"${tok##*[![:space:]]}"}
  if [[ -z $tok ]]; then
    printf 'pm: empty token; nothing changed\n' >&2
    return 1
  fi
  # --replace only when the secret exists: podman 4.9.3 fails with
  # "no secret data with ID" when --replace meets a new name
  local replace=()
  podman secret exists "$secret" 2>/dev/null && replace=(--replace)
  printf '%s' "$tok" | podman secret create "${replace[@]}" "$secret" - >/dev/null || return 1
  printf 'pm: stored podman secret %s\n' "$secret"
}

# ------------------------------------------------------------------ bash completion

# Master completion. When a subcommand or argument changes, edit this block
# first, then mirror the change in the zsh block below: both _pm_candidates
# functions must return the same kind and words for the same command line.
_pm_emit_bash() {
  cat <<'PM_BASH'
# bash completion for pm and pm.sh, generated by `pm sh`; needs bash 5.2 or later
# load with:  eval "$(pm sh)"

# rebuild the words from the line start up to the cursor into _pm_words;
# bash 4+ splits COMP_WORDS at ':' (COMP_WORDBREAKS), so tokens with no
# whitespace between them are glued back and image names stay whole
_pm_line_words() {
  local line=${COMP_LINE:0:COMP_POINT} i w ws
  _pm_words=()
  for (( i = 0; i <= COMP_CWORD; i++ )); do
    ws=${line%%[![:space:]]*}
    line=${line#"$ws"}
    if (( i == COMP_CWORD )); then w=$line; else w=${COMP_WORDS[i]-}; fi
    if (( ${#_pm_words[@]} == 0 )) || [[ -n $ws ]]; then
      _pm_words[${#_pm_words[@]}]=$w
    else
      _pm_words[${#_pm_words[@]}-1]+=$w
    fi
    line=${line:${#w}}
  done
  return 0
}

# fill _pm_reply with container names; arguments are `podman ps` flags
_pm_list_containers() {
  _pm_kind=words
  _pm_reply=( $(podman ps "$@" --format '{{.Names}}' 2>/dev/null) )
}

# candidates for `pm run`: flags, the --mount directory, the --net
# network, or the image
_pm_candidates_run() {
  local n=${#_pm_words[@]} i f w pos=0 skip=0
  local cur=${_pm_words[n-1]} prev=${_pm_words[n-2]}
  if [[ $prev == --mount || $prev == --mnt ]]; then _pm_kind=dirs; return 0; fi
  if [[ $prev == --net ]]; then
    _pm_kind=words
    _pm_reply=( $(podman network ls --filter label=pm-script --format '{{.Name}}' 2>/dev/null) )
    return 0
  fi

  # flags: offer only the ones not already before the cursor;
  # --mount and --mnt are one flag
  if [[ $cur == -* ]]; then
    _pm_kind=words
    for f in --cc --cp --hc --mount --mnt --net --help; do
      for (( i = 2; i < n - 1; i++ )); do
        w=${_pm_words[i]%%=*}
        [[ $w == "$f" ]] && continue 2
        [[ $f == --m*t && ( $w == --mount || $w == --mnt ) ]] && continue 2
      done
      _pm_reply[${#_pm_reply[@]}]=$f
    done
    return 0
  fi

  # count positionals before the cursor, skipping flags and the arguments
  # of --mount and --net; only the first positional, the image, is completable
  for (( i = 2; i < n - 1; i++ )); do
    if (( skip )); then skip=0; continue; fi
    case ${_pm_words[i]} in
      --mount|--mnt|--net) skip=1 ;;
      -*)            ;;
      *)             pos=$((pos + 1)) ;;
    esac
  done
  (( pos == 0 )) || return 0
  _pm_kind=words
  _pm_reply=( $(podman image list --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -vF '<none>') )
}

# set _pm_kind (words, dirs, files, or none) and _pm_reply (unfiltered words)
# from _pm_words; the last element is the word being completed
_pm_candidates() {
  local n=${#_pm_words[@]}
  _pm_kind=none
  _pm_reply=()
  (( n >= 2 )) || return 0
  local cur=${_pm_words[n-1]} sub=${_pm_words[1]} arg=$(( n - 2 ))

  if (( n == 2 )); then
    _pm_kind=words
    if [[ $cur == -* ]]; then
      _pm_reply=(-h --help --version)
    else
      _pm_reply=(run start stop bash rm ps net cp cp-claude cp-cc cp-copilot cp-cp
        secret-cc secret-cp readme sh zsh sh-file zsh-file help)
    fi
    return 0
  fi

  [[ $sub == run ]] && { _pm_candidates_run; return 0; }

  # flags of the other subcommands, offered for the first argument only;
  # pm rm also takes --force after the container
  if [[ $cur == -* ]]; then
    if [[ $sub == rm ]] && (( arg == 2 )) && [[ ${_pm_words[2]} != -* ]]; then
      _pm_kind=words; _pm_reply=(--force); return 0
    fi
    (( arg == 1 )) || return 0
    _pm_kind=words
    case $sub in
      ps)               _pm_reply=(-a --all --help) ;;
      rm)               _pm_reply=(--force --help) ;;
      sh-file|zsh-file) _pm_reply=(--force --help) ;;
      *)                _pm_reply=(--help) ;;
    esac
    return 0
  fi

  case $sub in
    # only containers that can still be started
    start) (( arg == 1 )) && _pm_list_containers --all \
             --filter status=created --filter status=exited --filter status=stopped ;;
    stop|bash) (( arg == 1 )) && _pm_list_containers --filter status=running ;;
    # the container follows an optional --force
    rm)    if (( arg == 1 )) || [[ $arg == 2 && ${_pm_words[2]} == --force ]]; then
             _pm_list_containers --all
           fi ;;
    # view keywords plus container names, then names after a keyword
    ps)    if (( arg == 1 )); then
             _pm_kind=words
             _pm_reply=(labels mounts ns id $(podman ps --all --format '{{.Names}}' 2>/dev/null))
           elif (( arg == 2 )); then
             case ${_pm_words[2]} in
               labels|mounts|ns|id) _pm_list_containers --all ;;
             esac
           fi ;;
    # podman cp accepts running and stopped containers; argument 3 lives in
    # the container and cannot be completed from the host
    cp)    if (( arg == 1 )); then _pm_list_containers --all
           elif (( arg == 2 )); then _pm_kind=files; fi ;;
    # these run mkdir in the container, so it must be running
    cp-claude|cp-cc|cp-copilot|cp-cp)
           (( arg == 1 )) && _pm_list_containers --filter status=running ;;
    sh-file|zsh-file) (( arg == 1 )) && { _pm_kind=words; _pm_reply=(--force); } ;;
  esac
  return 0
}

# ask readline for filename handling (trailing slash, quoting)
_pm_filenames() {
  compopt -o filenames 2>/dev/null
  return 0
}

_pm() {
  local -a _pm_words _pm_reply
  local _pm_kind cur prefix i n IFS=$'\n'
  _pm_line_words
  _pm_candidates
  cur=${_pm_words[${#_pm_words[@]}-1]}
  COMPREPLY=()
  case $_pm_kind in
    words)
      COMPREPLY=( $(compgen -W "${_pm_reply[*]}" -- "$cur") )
      # readline replaces only the text after the last ':', so strip that
      # prefix from each reply, else the image repo gets duplicated
      if [[ $cur == *:* && ${COMP_WORDBREAKS-} == *:* ]]; then
        prefix=${cur%"${cur##*:}"} n=${#COMPREPLY[@]}
        for (( i = 0; i < n; i++ )); do COMPREPLY[i]=${COMPREPLY[i]#"$prefix"}; done
      fi ;;
    dirs)  COMPREPLY=( $(compgen -d -- "$cur") ); _pm_filenames ;;
    files) COMPREPLY=( $(compgen -f -- "$cur") ); _pm_filenames ;;
  esac
  return 0
}

complete -F _pm pm pm.sh
PM_BASH
}

# ------------------------------------------------------------------ zsh completion

# Native zsh port of the bash block above; change it only after the bash block.
# words and CURRENT come from the zsh completion system; reply holds the
# unfiltered words and REPLY the kind, as _pm_reply and _pm_kind do in bash.
_pm_emit_zsh_defs() {
  cat <<'PM_ZSH'
# fill reply with container names; arguments are `podman ps` flags
_pm_list_containers() {
  REPLY=words
  reply=( ${(f)"$(podman ps "$@" --format '{{.Names}}' 2>/dev/null)"} )
}

# candidates for `pm run`: flags, the --mount directory, the --net
# network, or the image
_pm_candidates_run() {
  local n=$CURRENT i f pos=0 skip=0
  local cur=${words[n]} prev=${words[n-1]}
  local -a before
  # flag names only, so --net=x counts as --net
  before=( "${(@)${(@)words[3,n-1]}%%=*}" )
  if [[ $prev == --mount || $prev == --mnt ]]; then REPLY=dirs; return 0; fi
  if [[ $prev == --net ]]; then
    REPLY=words
    reply=( ${(f)"$(podman network ls --filter label=pm-script --format '{{.Name}}' 2>/dev/null)"} )
    return 0
  fi

  # flags: offer only the ones not already before the cursor;
  # --mount and --mnt are one flag
  if [[ $cur == -* ]]; then
    REPLY=words
    for f in --cc --cp --hc --mount --mnt --net --help; do
      (( ${before[(Ie)$f]} )) && continue
      [[ $f == --m*t ]] && (( ${before[(Ie)--mount]} || ${before[(Ie)--mnt]} )) && continue
      reply+=( $f )
    done
    return 0
  fi

  # count positionals before the cursor, skipping flags and the arguments
  # of --mount and --net; only the first positional, the image, is completable
  for (( i = 3; i < n; i++ )); do
    if (( skip )); then skip=0; continue; fi
    case ${words[i]} in
      --mount|--mnt|--net) skip=1 ;;
      -*)            ;;
      *)             pos=$((pos + 1)) ;;
    esac
  done
  (( pos == 0 )) || return 0
  REPLY=words
  reply=( ${(f)"$(podman image list --format '{{.Repository}}:{{.Tag}}' 2>/dev/null)"} )
  reply=( ${reply:#*"<none>"*} )
}

# set REPLY (words, dirs, files, or none) and reply (unfiltered words)
# from words and CURRENT; words[1] is `pm` or `pm.sh`
_pm_candidates() {
  local n=$CURRENT
  REPLY=none
  reply=()
  (( n >= 2 )) || return 0
  local cur=${words[n]} sub=${words[2]} arg=$(( n - 2 ))

  if (( n == 2 )); then
    REPLY=words
    if [[ $cur == -* ]]; then
      reply=( -h --help --version )
    else
      reply=( run start stop bash rm ps net cp cp-claude cp-cc cp-copilot cp-cp
        secret-cc secret-cp readme sh zsh sh-file zsh-file help )
    fi
    return 0
  fi

  [[ $sub == run ]] && { _pm_candidates_run; return 0; }

  # flags of the other subcommands, offered for the first argument only;
  # pm rm also takes --force after the container
  if [[ $cur == -* ]]; then
    if [[ $sub == rm ]] && (( arg == 2 )) && [[ ${words[3]} != -* ]]; then
      REPLY=words; reply=( --force ); return 0
    fi
    (( arg == 1 )) || return 0
    REPLY=words
    case $sub in
      ps)               reply=( -a --all --help ) ;;
      rm)               reply=( --force --help ) ;;
      sh-file|zsh-file) reply=( --force --help ) ;;
      *)                reply=( --help ) ;;
    esac
    return 0
  fi

  case $sub in
    # only containers that can still be started
    start) (( arg == 1 )) && _pm_list_containers --all \
             --filter status=created --filter status=exited --filter status=stopped ;;
    stop|bash) (( arg == 1 )) && _pm_list_containers --filter status=running ;;
    # the container follows an optional --force
    rm)    if (( arg == 1 )) || [[ $arg == 2 && ${words[3]} == --force ]]; then
             _pm_list_containers --all
           fi ;;
    # view keywords plus container names, then names after a keyword
    ps)    if (( arg == 1 )); then
             REPLY=words
             reply=( labels mounts ns id ${(f)"$(podman ps --all --format '{{.Names}}' 2>/dev/null)"} )
           elif (( arg == 2 )); then
             case ${words[3]} in
               labels|mounts|ns|id) _pm_list_containers --all ;;
             esac
           fi ;;
    # podman cp accepts running and stopped containers; argument 3 lives in
    # the container and cannot be completed from the host
    cp)    if (( arg == 1 )); then _pm_list_containers --all
           elif (( arg == 2 )); then REPLY=files; fi ;;
    # these run mkdir in the container, so it must be running
    cp-claude|cp-cc|cp-copilot|cp-cp)
           (( arg == 1 )) && _pm_list_containers --filter status=running ;;
    sh-file|zsh-file) (( arg == 1 )) && { REPLY=words; reply=( --force ); } ;;
  esac
  return 0
}

_pm() {
  local REPLY
  local -a reply
  _pm_candidates
  case $REPLY in
    words) compadd -a reply ;;
    dirs)  _path_files -/ ;;
    files) _files ;;
  esac
}
PM_ZSH
}

# `pm zsh` output: definitions plus registration, which needs compinit
_pm_emit_zsh_eval() {
  printf '%s\n' '# zsh completion for pm and pm.sh, generated by `pm zsh`' \
    '# load with:  eval "$(pm zsh)"  after compinit'
  _pm_emit_zsh_defs
  printf '%s\n' 'if (( $+functions[compdef] )); then' \
    '  compdef _pm pm pm.sh' 'else' \
    "  print -u2 'pm: run compinit before eval \"\$(pm zsh)\"'" 'fi'
}

# `pm zsh-file` output: an autoload file; its first run defines the helpers,
# redefines _pm, and then completes
_pm_emit_zsh_file() {
  printf '%s\n' '#compdef pm pm.sh' '# zsh completion for pm, generated by `pm zsh-file`'
  _pm_emit_zsh_defs
  printf '%s\n' '_pm "$@"'
}

# ------------------------------------------------------------------ pm sh / zsh

pm_print() {
  local shell=$1
  shift
  if _pm_wants_help "$@"; then
    if [[ $shell == sh ]]; then
      printf '%s\n' 'usage: pm sh' '' 'prints bash completion; load it with:  eval "$(pm sh)"'
    else
      printf '%s\n' 'usage: pm zsh' '' 'prints zsh completion; load it after compinit with:  eval "$(pm zsh)"'
    fi
    return 0
  fi
  if (( $# )); then _pm_usage "usage: pm $shell"; return 2; fi
  if [[ $shell == sh ]]; then _pm_emit_bash; else _pm_emit_zsh_eval; fi
}

# ------------------------------------------------------------------ pm sh-file / zsh-file

# write the completion file; refuses to overwrite without --force and
# creates missing parent directories
pm_write_file() {
  local shell=$1 force=0 target dir tmp
  shift
  if [[ $shell == sh ]]; then target=$(_pm_bash_file); else target=$(_pm_zsh_file); fi
  local help="usage: pm $shell-file [--force]

writes the completion file to:
  $target

  --force  overwrite an existing file"
  _pm_wants_help "$@" && { printf '%s\n' "$help"; return 0; }
  while (( $# )); do
    case $1 in
      --force) force=1 ;;
      *) _pm_usage "$help"; return 2 ;;
    esac
    shift
  done

  if [[ -d $target ]]; then
    printf 'pm: %s is a directory\n' "$target" >&2
    return 1
  fi
  if [[ -e $target ]] && (( ! force )); then
    printf 'pm: %s exists; use --force to overwrite\n' "$target" >&2
    return 1
  fi
  dir=${target%/*}
  mkdir -p -- "$dir" || { printf 'pm: cannot create %s\n' "$dir" >&2; return 1; }

  # write a temp file first so a failed write never leaves a partial file
  tmp=$dir/.${target##*/}.$$
  if [[ $shell == sh ]]; then _pm_emit_bash >"$tmp"; else _pm_emit_zsh_file >"$tmp"; fi
  if [[ $? -ne 0 ]] || ! mv -f -- "$tmp" "$target"; then
    rm -f -- "$tmp"
    printf 'pm: cannot write %s\n' "$target" >&2
    return 1
  fi
  printf 'pm: wrote %s\n' "$target"
  # bash-completion looks files up by command name, so pm.sh needs its own
  if [[ $shell == sh ]]; then
    if ln -sf -- "${target##*/}" "$dir/pm.sh"; then
      printf 'pm: linked %s -> %s\n' "$dir/pm.sh" "${target##*/}"
    else
      printf 'pm: cannot link %s; pm.sh completes after pm was completed once\n' "$dir/pm.sh" >&2
    fi
  fi

  if [[ $shell == zsh ]]; then
    printf '%s\n' 'add this line to ~/.zshrc before compinit:'
    printf '  fpath=(%q $fpath)\n' "$dir"
  fi
  return 0
}

# ------------------------------------------------------------------ usage, readme, and dispatch

pm_usage() {
  printf '%s\n' \
    "pm $PM_VERSION – podman helpers for dev containers" \
    '' \
    'requires: podman 6.0 or later, bash 5.2 or later' \
    '' \
    'usage: pm <subcommand> [<args>]' \
    '       pm <subcommand> --help' \
    '' \
    '  run        [--cc] [--cp] [--hc] [--mount <dir>] [--net <name>] <image> [<container-name>]' \
    '  start      <container>' \
    '  stop       <container>' \
    '  bash       <container>    interactive bash terminal in a running container' \
    '  rm         [--force] <container>  remove it and its pm network once unused' \
    '  ps         [-a] | <container> | labels|mounts|ns|id [<container>]' \
    '  net        networks and their containers' \
    '  cp         <container> <local-file> <dest-name>' \
    '  cp-claude  <container>    alias cp-cc; CLAUDE.md and settings' \
    '  cp-copilot <container>    alias cp-cp; instructions and settings' \
    '  secret-cc                 store the Claude Code token as a podman secret' \
    '  secret-cp                 store the GitHub Copilot token as a podman secret' \
    '  readme     quick start' \
    '  sh         print bash completion; load it with  eval "$(pm sh)"' \
    '  zsh        print zsh completion; load it with  eval "$(pm zsh)"' \
    '  sh-file    [--force]  write bash completion to:' \
    "               $(_pm_bash_file)" \
    '  zsh-file   [--force]  write zsh completion to:' \
    "               $(_pm_zsh_file)" \
    '  help       show this help; also -h and --help' \
    '  --version  print the version' \
    '' \
    'environment: PM_CC_SECRET, PM_CC_TARGET, PM_CP_SECRET, PM_CP_TARGET,' \
    '             PM_CLAUDE_MD, PM_CLAUDE_SETTINGS, PM_COPILOT_SETTINGS'
}

pm_readme() {
  if _pm_wants_help "$@"; then
    printf '%s\n' 'usage: pm readme' '' 'prints a quick start'
    return 0
  fi
  if (( $# )); then _pm_usage 'usage: pm readme'; return 2; fi
  cat <<EOF
pm $PM_VERSION – podman helpers for dev containers

INSTALL

  install -m 755 pm.sh ~/.local/bin/pm.sh   # any directory on PATH
  alias pm=pm.sh                            # in ~/.bashrc or ~/.zshrc
  eval "\$(pm sh)"                           # bash completion, in ~/.bashrc
  eval "\$(pm zsh)"                          # zsh completion, in ~/.zshrc after compinit

  pm sh-file and pm zsh-file write the completion to a file instead.
  requires: podman 6.0 or later, bash 5.2 or later; jq for the pm ps
  detail views

STORE THE AGENT TOKENS (once, and again to rotate them)

  pm secret-cc        Claude Code token -> podman secret $PM_CC_SECRET
  pm secret-cp        GitHub Copilot token -> podman secret $PM_CP_SECRET

  Any agent in the container can read these tokens from its environment,
  see pm secret-cc --help. Recreate a container to be sure it gets a new token.

QUICK START

  # create pm-myapp with ~/src/myapp at /workspaces/myapp, plus
  # ~/src/myapp.worktrees at /workspaces/myapp.worktrees when it exists
  pm run --cc --mount ~/src/myapp mcr.microsoft.com/devcontainers/base:bookworm

  pm cp-cc pm-myapp   # copy CLAUDE.md and the settings template
  pm bash pm-myapp    # open an interactive bash terminal
  pm ps               # running containers; pm ps -a lists all
  pm stop pm-myapp
  pm start pm-myapp
  pm rm --force pm-myapp   # stops and removes it, then its network myapp

  # without a mount the container name is required
  pm run mcr.microsoft.com/devcontainers/base:bookworm scratch

NETWORK ISOLATION

  With --mount or --net, the container joins a bridge network created with
  -o isolate=strict, which blocks traffic to and from all other bridge
  networks. The network is named after the folder (characters podman
  rejects become -, pm- goes in front when needed) or after --net <name>.
  pm reuses a network it created earlier and refuses any other network.
  Without --mount and --net, the container uses podman's default network
  mode and is not isolated. pm rm removes the network once no container
  uses it; pm net lists all networks with their containers.

GIT WORKTREES

  git links worktrees with absolute host paths by default, and those paths
  do not exist in the container. With git 2.48 or later, link them with
  relative paths:

  git config --global worktree.useRelativePaths true
  git worktree add ../myapp.worktrees/feature-x
  git worktree repair --relative-paths   # convert existing worktrees

  This enables the relativeWorktrees repository extension, so older git
  versions cannot work with such a repository.

HERDR-CORE

  pm run --hc gives the container a stable herdr-core identity and starts
  the core in it with podman exec -d -e SHELL=/bin/bash <container> hc serve;
  podman sets no SHELL, and the core starts new shells from its own. The
  identity lives on the host in an id file, mounted read-only at
  /etc/machine-id, and a state folder, mounted at
  /home/vscode/.local/state/herdr-core:

  pm run --hc --mount ~/src/myapp <image>   # an image with hc on its PATH

  with ~/src/myapp/.devcontainer, the paths of the dev container template:
    ~/src/myapp/.devcontainer/herdr-machine-id
    ~/.config/herdr-core/container/myapp-<devcontainerId>
  without it:
    ~/src/myapp/herdr-machine-id
    ~/.config/herdr-core/container/myapp-<sha256 of the id>

  To start over, delete the id file and the state folder. The dev container
  and a pm container of one project share the identity and the state, so
  run only one at a time: only one core runs per state folder, hc in every
  container that mounts it uses that core, and pm notes podman containers
  that already mount it; it does not detect containers of other engines,
  such as a dev container under Docker. The devcontainerId depends on the
  folder path, so it matches only when VS Code opened the same path as
  --mount, and only for .devcontainer/devcontainer.json; a config in
  .devcontainer/<name>/devcontainer.json gets another devcontainerId, so
  that dev container shares the id file but not the state folder. Keep the
  id file out of git; pm notes when git does not ignore it.

INSPECT

  pm ps pm-myapp          full inspect JSON
  pm ps labels pm-myapp   labels; also mounts, ns, and id
  pm ps labels            labels of all containers

CONFIGURATION (environment variable and current value)

  PM_CC_SECRET         $PM_CC_SECRET
  PM_CC_TARGET         $PM_CC_TARGET
  PM_CP_SECRET         $PM_CP_SECRET
  PM_CP_TARGET         $PM_CP_TARGET
  PM_CLAUDE_MD         $PM_CLAUDE_MD
  PM_CLAUDE_SETTINGS   $PM_CLAUDE_SETTINGS
  PM_COPILOT_SETTINGS  $PM_COPILOT_SETTINGS

Every subcommand prints its details with --help, e.g. pm run --help.
EOF
}

main() {
  local cmd=${1-}
  (( $# )) && shift
  case $cmd in
    run)                  pm_run "$@" ;;
    start)                pm_start "$@" ;;
    stop)                 pm_stop "$@" ;;
    bash)                 pm_bash "$@" ;;
    rm)                   pm_rm "$@" ;;
    ps)                   pm_ps "$@" ;;
    net)                  pm_net "$@" ;;
    cp)                   pm_cp "$@" ;;
    cp-claude|cp-cc)      pm_cp_claude "$@" ;;
    cp-copilot|cp-cp)     pm_cp_copilot "$@" ;;
    secret-cc)            pm_secret secret-cc "$PM_CC_SECRET" "$PM_CC_TARGET" 'Claude Code' "$@" ;;
    secret-cp)            pm_secret secret-cp "$PM_CP_SECRET" "$PM_CP_TARGET" 'GitHub Copilot' "$@" ;;
    readme)               pm_readme "$@" ;;
    sh|zsh)               pm_print "$cmd" "$@" ;;
    sh-file)              pm_write_file sh "$@" ;;
    zsh-file)             pm_write_file zsh "$@" ;;
    help|-h|--help)       if (( $# )) && ! _pm_wants_help "$@"; then pm_usage >&2; return 2; fi
                          pm_usage ;;
    --version)            if _pm_wants_help "$@"; then printf '%s\n' 'usage: pm --version'; return 0; fi
                          if (( $# )); then _pm_usage 'usage: pm --version'; return 2; fi
                          printf 'pm %s\n' "$PM_VERSION" ;;
    '')                   pm_usage >&2; return 2 ;;
    *)                    printf 'pm: unknown subcommand: %s\n\n' "$cmd" >&2
                          pm_usage >&2
                          return 2 ;;
  esac
}

main "$@"
