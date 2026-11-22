# scripts-misc

A collection of small command-line helpers.

## Scripts

### `gh-auth/gh-auth.sh`

Source this script to set `GH_TOKEN` when GitHub CLI is not already authenticated. It reads a GitHub credential from Git's credential store; if none is available, it prints sign-in instructions.

### `pm/pm.sh`

`pm.sh` provides subcommands for creating and managing Podman development containers, including mounts, networks, file copying, and interactive shells. It can copy Claude Code and GitHub Copilot settings and manage their tokens as Podman secrets. It also provides Bash and Zsh completions; see `pm help` or `pm readme` for usage.
