#!/usr/bin/env bash
# pm – podman helper commands for dev containers, with bash and zsh completion.
# Runs as a command under bash 3.2 or later; `pm help` lists the subcommands.
# Install it on PATH as `pm`; the completion binds to that name.

# refuse to be sourced: `. pm sh` would leak variables, options, and `exit`
# into the calling shell; `return` succeeds in a subshell only when sourced,
# and plain POSIX syntax keeps this block parseable by bash and zsh
if [ -n "${ZSH_VERSION-}" ]; then
  printf '%s\n' 'pm: run this file as a command, do not source it' \
    'load zsh completion with:  eval "$(pm zsh)"' >&2
  return 2 2>/dev/null || exit 2
elif (return 0 2>/dev/null); then
  printf '%s\n' 'pm: run this file as a command, do not source it' \
    'load bash completion with:  eval "$(pm sh)"' >&2
  return 2
fi

# ------------------------------------------------------------------ config

# Secret names and the environment variables they land in inside the container.
# Override any of these by exporting them in your environment.
: "${PM_CC_SECRET:=cc_token}"
: "${PM_CC_TARGET:=CLAUDE_CODE_OAUTH_TOKEN}"
: "${PM_CP_SECRET:=cp_token}"
: "${PM_CP_TARGET:=COPILOT_GITHUB_TOKEN}"

# Local instruction file copied by `pm cp-claude` and `pm cp-copilot`.
: "${PM_CLAUDE_MD:=$HOME/.claude/CLAUDE.md}"

# ------------------------------------------------------------------ helpers

# print a usage block to stderr; callers return 2 afterwards
_pm_usage() { printf '%s\n' "$1" >&2; }

# copy the local instruction file into a container
# $1 = container, $2 = path below /home/vscode/
_pm_put_md() {
  [[ -r $PM_CLAUDE_MD ]] || { printf 'pm: cannot read %s\n' "$PM_CLAUDE_MD" >&2; return 1; }
  podman cp "$PM_CLAUDE_MD" "$1:/home/vscode/$2"
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

# ------------------------------------------------------------------ pm run

pm_run() {
  local cc=0 cp=0 mnt='' image='' name='' npos=0 endflags=0
  # keep-id maps the host UID/GID into the container so bind-mounted files
  # keep their ownership (rootless podman only)
  local opts=(-d --userns=keep-id)

  # flags in any position; `--` ends flag parsing
  while (( $# )); do
    if (( endflags == 0 )); then
      case $1 in
        --cc)  cc=1; shift; continue ;;
        --cp)  cp=1; shift; continue ;;
        --mnt)
          if [[ -z ${2-} ]]; then _pm_usage 'pm run: --mnt needs a directory'; return 2; fi
          mnt=$2; shift 2; continue ;;
        --)    endflags=1; shift; continue ;;
        -*)    _pm_usage "pm run: unknown option $1"; return 2 ;;
      esac
    fi
    case $npos in
      0) image=$1 ;;
      1) name=$1 ;;
      *) _pm_usage "pm run: unexpected argument $1"; return 2 ;;
    esac
    npos=$((npos + 1))
    shift
  done

  if [[ -n $mnt ]]; then
    # podman reads a relative path as a volume name, so resolve it first
    local abs base
    abs=$(cd -- "$mnt" 2>/dev/null && pwd) \
      || { _pm_usage "pm run: no such directory: $mnt"; return 2; }
    base=${abs##*/}
    if [[ -z $base ]]; then _pm_usage "pm run: cannot derive a name from $abs"; return 2; fi
    opts+=(-v "$abs:/workspaces/$base")
    # explicit name wins; otherwise pm- plus the folder name, stripped of
    # characters podman does not accept in a container name
    [[ -n $name ]] || name=pm-${base//[^a-zA-Z0-9_.-]/-}
  fi

  # guard: an image is always required, a name only when --mnt cannot supply one
  if [[ -z $image || -z $name ]]; then
    _pm_usage 'usage: pm run [--cc] [--cp] [--mnt <dir>] <image> [<container-name>]

  --cc              pass the Claude Code token as a podman secret
  --cp              pass the GitHub Copilot token as a podman secret
  --mnt <dir>       mount <dir> at /workspaces/<foldername> and, unless a name
                    is given, call the container pm-<foldername>
  <image>           image to run, e.g. docker.io/library/debian:bookworm
  <container-name>  name for the new container; required without --mnt

runs: podman run -it --userns=keep-id [-v ...] [--secret ...] --name <container-name> <image> bash'
    return 2
  fi

  # one --secret per requested token; podman exposes each as an env var
  (( cc )) && opts+=(--secret "$PM_CC_SECRET,type=env,target=$PM_CC_TARGET")
  (( cp )) && opts+=(--secret "$PM_CP_SECRET,type=env,target=$PM_CP_TARGET")

  podman run "${opts[@]}" --name "$name" "$image" sleep infinity
}

# ------------------------------------------------------------------ pm start

pm_start() {
  if [[ $# -ne 1 || -z $1 ]]; then
    _pm_usage 'usage: pm start <container>

  <container>  container to start; completion lists non-running containers

runs: podman start <container>'
    return 2
  fi
  podman start "$1"
}

# ------------------------------------------------------------------ pm exec

pm_exec() {
  if [[ $# -ne 1 || -z $1 ]]; then
    _pm_usage 'usage: pm exec <container>

  <container>  running container; completion lists running containers only

runs: podman exec -it <container> bash'
    return 2
  fi
  podman exec -it "$1" bash
}

# ------------------------------------------------------------------ pm cp

pm_cp() {
  # guard: exactly three non-empty args
  if [[ $# -ne 3 || -z $1 || -z $2 || -z $3 ]]; then
    _pm_usage 'usage: pm cp <container> <local-file> <dest-name>

  <container>   target container, running or stopped
  <local-file>  file on this machine
  <dest-name>   path below /home/vscode/ inside the container

runs: podman cp <local-file> <container>:/home/vscode/<dest-name>
note: the parent directory of the destination must already exist'
    return 2
  fi
  podman cp "$2" "$1:/home/vscode/$3"
}

# ------------------------------------------------------ pm cp-claude / cp-copilot

pm_cp_claude() {
  if [[ $# -ne 1 || -z $1 ]]; then
    _pm_usage 'usage: pm cp-claude <container>

  <container>  target container, running or stopped

runs: podman cp $PM_CLAUDE_MD <container>:/home/vscode/.claude/CLAUDE.md
note: /home/vscode/.claude must already exist in the container'
    return 2
  fi
  _pm_put_md "$1" .claude/CLAUDE.md
}

pm_cp_copilot() {
  if [[ $# -ne 1 || -z $1 ]]; then
    _pm_usage 'usage: pm cp-copilot <container>

  <container>  target container, running or stopped

runs: podman cp $PM_CLAUDE_MD <container>:/home/vscode/.copilot/copilot-instructions.md
note: /home/vscode/.copilot must already exist in the container'
    return 2
  fi
  _pm_put_md "$1" .copilot/copilot-instructions.md
}

# ------------------------------------------------------------------ bash completion

# Master completion. When a subcommand or argument changes, edit this block
# first, then mirror the change in the zsh block below: both _pm_candidates
# functions must return the same kind and words for the same command line.
_pm_emit_bash() {
  cat <<'PM_BASH'
# bash completion for pm, generated by `pm sh`; needs bash 3.2 or later
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

# candidates for `pm run`: flags, the --mnt directory, or the image
_pm_candidates_run() {
  local n=${#_pm_words[@]} i f pos=0 skip=0
  local cur=${_pm_words[n-1]} prev=${_pm_words[n-2]}
  if [[ $prev == --mnt ]]; then _pm_kind=dirs; return 0; fi

  # flags: offer only the ones not already before the cursor
  if [[ $cur == -* ]]; then
    _pm_kind=words
    for f in --cc --cp --mnt; do
      for (( i = 2; i < n - 1; i++ )); do
        [[ ${_pm_words[i]} == "$f" ]] && continue 2
      done
      _pm_reply[${#_pm_reply[@]}]=$f
    done
    return 0
  fi

  # count positionals before the cursor, skipping flags and the --mnt argument;
  # only the first positional, the image, is completable
  for (( i = 2; i < n - 1; i++ )); do
    if (( skip )); then skip=0; continue; fi
    case ${_pm_words[i]} in
      --mnt) skip=1 ;;
      -*)    ;;
      *)     pos=$((pos + 1)) ;;
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
      _pm_reply=(-h --help)
    else
      _pm_reply=(run start exec cp cp-claude cp-copilot sh zsh sh-file zsh-file help)
    fi
    return 0
  fi

  case $sub in
    run)   _pm_candidates_run ;;
    # only containers that can still be started
    start) (( arg == 1 )) && _pm_list_containers --all \
             --filter status=created --filter status=exited --filter status=stopped ;;
    exec)  (( arg == 1 )) && _pm_list_containers --filter status=running ;;
    # podman cp accepts running and stopped containers; argument 3 lives in
    # the container and cannot be completed from the host
    cp)    if (( arg == 1 )); then _pm_list_containers --all
           elif (( arg == 2 )); then _pm_kind=files; fi ;;
    cp-claude|cp-copilot) (( arg == 1 )) && _pm_list_containers --all ;;
    sh-file|zsh-file) (( arg == 1 )) && { _pm_kind=words; _pm_reply=(--force); } ;;
  esac
  return 0
}

# ask readline for filename handling (trailing slash, quoting);
# compopt exists from bash 4.0, so bash 3.2 lists plain names
_pm_filenames() {
  command -v compopt >/dev/null 2>&1 && compopt -o filenames 2>/dev/null
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

complete -F _pm pm
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

# candidates for `pm run`: flags, the --mnt directory, or the image
_pm_candidates_run() {
  local n=$CURRENT i f pos=0 skip=0
  local cur=${words[n]} prev=${words[n-1]}
  local -a before
  before=( "${(@)words[3,n-1]}" )
  if [[ $prev == --mnt ]]; then REPLY=dirs; return 0; fi

  # flags: offer only the ones not already before the cursor
  if [[ $cur == -* ]]; then
    REPLY=words
    for f in --cc --cp --mnt; do
      (( ${before[(Ie)$f]} )) || reply+=( $f )
    done
    return 0
  fi

  # count positionals before the cursor, skipping flags and the --mnt argument;
  # only the first positional, the image, is completable
  for (( i = 3; i < n; i++ )); do
    if (( skip )); then skip=0; continue; fi
    case ${words[i]} in
      --mnt) skip=1 ;;
      -*)    ;;
      *)     pos=$((pos + 1)) ;;
    esac
  done
  (( pos == 0 )) || return 0
  REPLY=words
  reply=( ${(f)"$(podman image list --format '{{.Repository}}:{{.Tag}}' 2>/dev/null)"} )
  reply=( ${reply:#*"<none>"*} )
}

# set REPLY (words, dirs, files, or none) and reply (unfiltered words)
# from words and CURRENT; words[1] is `pm`
_pm_candidates() {
  local n=$CURRENT
  REPLY=none
  reply=()
  (( n >= 2 )) || return 0
  local cur=${words[n]} sub=${words[2]} arg=$(( n - 2 ))

  if (( n == 2 )); then
    REPLY=words
    if [[ $cur == -* ]]; then
      reply=( -h --help )
    else
      reply=( run start exec cp cp-claude cp-copilot sh zsh sh-file zsh-file help )
    fi
    return 0
  fi

  case $sub in
    run)   _pm_candidates_run ;;
    # only containers that can still be started
    start) (( arg == 1 )) && _pm_list_containers --all \
             --filter status=created --filter status=exited --filter status=stopped ;;
    exec)  (( arg == 1 )) && _pm_list_containers --filter status=running ;;
    # podman cp accepts running and stopped containers; argument 3 lives in
    # the container and cannot be completed from the host
    cp)    if (( arg == 1 )); then _pm_list_containers --all
           elif (( arg == 2 )); then REPLY=files; fi ;;
    cp-claude|cp-copilot) (( arg == 1 )) && _pm_list_containers --all ;;
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
  printf '%s\n' '# zsh completion for pm, generated by `pm zsh`' \
    '# load with:  eval "$(pm zsh)"  after compinit'
  _pm_emit_zsh_defs
  printf '%s\n' 'if (( $+functions[compdef] )); then' \
    '  compdef _pm pm' 'else' \
    "  print -u2 'pm: run compinit before eval \"\$(pm zsh)\"'" 'fi'
}

# `pm zsh-file` output: an autoload file; its first run defines the helpers,
# redefines _pm, and then completes
_pm_emit_zsh_file() {
  printf '%s\n' '#compdef pm' '# zsh completion for pm, generated by `pm zsh-file`'
  _pm_emit_zsh_defs
  printf '%s\n' '_pm "$@"'
}

# ------------------------------------------------------------------ pm sh / zsh

pm_print() {
  local shell=$1
  shift
  if (( $# )); then _pm_usage "usage: pm $shell"; return 2; fi
  if [[ $shell == sh ]]; then _pm_emit_bash; else _pm_emit_zsh_eval; fi
}

# ------------------------------------------------------------------ pm sh-file / zsh-file

# write the completion file; refuses to overwrite without --force and
# creates missing parent directories
pm_write_file() {
  local shell=$1 force=0 target dir tmp
  shift
  while (( $# )); do
    case $1 in
      --force) force=1 ;;
      *) _pm_usage "usage: pm $shell-file [--force]"; return 2 ;;
    esac
    shift
  done

  if [[ $shell == sh ]]; then target=$(_pm_bash_file); else target=$(_pm_zsh_file); fi
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

  if [[ $shell == zsh ]]; then
    printf '%s\n' 'add this line to ~/.zshrc before compinit:'
    printf '  fpath=(%q $fpath)\n' "$dir"
  elif (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2) )); then
    # bash-completion loads per-command files on demand only on bash 4.2+
    printf 'bash-completion loads this file on demand only with bash 4.2 or later (this is %s);\n' "$BASH_VERSION"
    printf '%s\n' 'add this line to ~/.bashrc instead:'
    printf '  . %q\n' "$target"
  fi
  return 0
}

# ------------------------------------------------------------------ usage and dispatch

pm_usage() {
  printf '%s\n' \
    'usage: pm <subcommand> [<args>]' \
    '' \
    '  run        [--cc] [--cp] [--mnt <dir>] <image> [<container-name>]' \
    '  start      <container>' \
    '  exec       <container>' \
    '  cp         <container> <local-file> <dest-name>' \
    '  cp-claude  <container>' \
    '  cp-copilot <container>' \
    '  sh         print bash completion; load it with  eval "$(pm sh)"' \
    '  zsh        print zsh completion; load it with  eval "$(pm zsh)"' \
    '  sh-file    [--force]  write bash completion to:' \
    "               $(_pm_bash_file)" \
    '  zsh-file   [--force]  write zsh completion to:' \
    "               $(_pm_zsh_file)" \
    '  help       show this help; also -h and --help' \
    '' \
    'environment: PM_CC_SECRET, PM_CC_TARGET, PM_CP_SECRET, PM_CP_TARGET, PM_CLAUDE_MD'
}

main() {
  local cmd=${1-}
  (( $# )) && shift
  case $cmd in
    run)            pm_run "$@" ;;
    start)          pm_start "$@" ;;
    exec)           pm_exec "$@" ;;
    cp)             pm_cp "$@" ;;
    cp-claude)      pm_cp_claude "$@" ;;
    cp-copilot)     pm_cp_copilot "$@" ;;
    sh|zsh)         pm_print "$cmd" "$@" ;;
    sh-file)        pm_write_file sh "$@" ;;
    zsh-file)       pm_write_file zsh "$@" ;;
    help|-h|--help) pm_usage ;;
    '')             pm_usage >&2; return 2 ;;
    *)              printf 'pm: unknown subcommand: %s\n\n' "$cmd" >&2
                    pm_usage >&2
                    return 2 ;;
  esac
}

main "$@"

