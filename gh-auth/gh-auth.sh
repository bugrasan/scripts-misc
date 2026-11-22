#!/usr/bin/env bash
# Usage: source ./gh-auth.sh
# Exports GH_TOKEN unless `gh auth` already works.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && { echo "must be sourced" >&2; exit 1; }

{ set +x; } 2>/dev/null  # don't leak token under xtrace

if gh auth status --hostname github.com >/dev/null 2>&1; then
  return 0
fi

_t=$(GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/echo GCM_INTERACTIVE=never \
     git credential fill <<<$'protocol=https\nhost=github.com\n\n' 2>/dev/null \
     | awk -F= '/^password=/{sub(/^password=/,""); print; exit}')

if [[ -n "$_t" ]]; then
  export GH_TOKEN="$_t"
  unset _t
  return 0
fi

unset _t
echo "gh-auth: no credential. Sign in via VS Code Accounts, or run: gh auth login" >&2
return 1