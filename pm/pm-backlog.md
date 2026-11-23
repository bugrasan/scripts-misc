# pm – feature backlog

Podman helper for personal dev containers: one bash script, `pm.sh`, called through `alias pm=pm.sh`, with bash and zsh completion.
Basic cases only, because the script is for personal use.
IDs: V<version>-<number>, for example V7-01.
The version lives in the constant `PM_VERSION` in `pm.sh`; `pm --version` prints it.
Requires podman 6.0 or later and bash 5.2 or later (from V7-18 on).

## v1 to v6 (done)

- V1-01 to V5-01 – run, start, exec, cp, the `--cc`/`--cp` secrets, cp-claude/cp-copilot, `--mnt`, and keep-id; delivered as the sourced `pm-*` functions in pm-run-v1.bash to pm-run-v5.bash
- v6 – the `pm` dispatcher replaced the `pm-*` functions (V6-07); it ran as a command, not sourced; its V6-01 to V6-06 and V6-08 items were carried into v7

## v7 (delivered in pm.sh, PM_VERSION=7)

- V7-01 the help of cp-claude and cp-copilot lists each source and destination path, with resolved values
- V7-02 `pm readme` – quick start: install, tokens, examples, inspect, and the current values of the `PM_*` variables; needs no podman
- V7-03 `pm ps` and `pm ps -a` – table with CONTAINER ID, NAME, STATUS, PM (value of the `pm-script` label), and PROJECT (label `devcontainer.local_folder`, else the host folder mounted at `/workspaces/<name>`); one `podman container inspect` call
- V7-04 `pm ps <container>` (full inspect JSON), `pm ps labels|mounts|ns|id [<container>]`; without a container they cover all containers; `ns` comes from `podman ps --ns`; needs jq
- V7-05 `pm --version` prints `pm 7`
- V7-06 `pm run` adds `--label pm-script=<version>`; podman sets labels only at creation (`podman update` has no label option), so `pm start` cannot add it
- V7-07 `pm secret-cc` and `pm secret-cp` – hidden prompt, trims whitespace, stores the podman secret; the help warns that agents can read their env vars
- V7-08 renamed to `pm.sh`; completion registers `pm` and `pm.sh`; `pm sh-file` adds the symlink `completions/pm.sh -> pm.bash`
- V7-09 every subcommand accepts `-h`/`--help` in any position (help to stdout, exit 0); wrong arguments print usage to stderr with exit 2; options are no longer passed through to podman (`pm stop -a` is rejected)
- V7-10 cp-claude and cp-copilot also copy `~/.claude/settings.json.template` and `~/.copilot/settings.json.template` as `settings.json` (optional; skipped when missing); `PM_CLAUDE_SETTINGS` and `PM_COPILOT_SETTINGS` override the sources
- V7-11 aliases `cp-cc` and `cp-cp`
- V7-12 `pm exec` renamed to `pm bash` (interactive bash terminal); no alias for the old name
- V7-13 `pm stop`
- V7-14 completion updated in both shells for all of the above
- V7-15 `--mount` with alias `--mnt`; also accepts `--mount=<dir>`; rejects a second `--mount`
- V7-16 `--mount` also mounts `<dir>/../<name>.worktrees` at `/workspaces/<name>.worktrees` when it exists (logical parent first, then the physical parent for a symlinked dir); prints a note when it is missing
- V7-17 cp-claude and cp-copilot create the target folder with `podman exec mkdir -p`, so the container must be running; results print as green `ok` and red `error` lines (color only on a terminal and with `NO_COLOR` empty or unset)
- V7-18 requirement note: podman 6.0 or later, bash 5.2 or later, in the header, `pm help`, and `pm readme`; code kept only for older bash removed (compopt guard, bash 4.2 hint in `pm sh-file`)
- V7-19 `pm run` always passes `--init`, so `pm stop` no longer waits 10 seconds for SIGKILL (0.2 s in a test)
- V7-20 readme section on git worktrees: `worktree.useRelativePaths` (git 2.48 or later) and `git worktree repair --relative-paths`
- V7-21 `pm run` creates a bridge network with `-o isolate=strict` and label `pm-script=<version>`, named after the folder (sanitized; `pm-` prefix when it starts with no letter or digit or is a podman network mode name) or `--net <name>`/`--net=<name>`; without `--mount` and `--net`, podman's default network mode, not isolated; reuses a pm network (exact name match, bridge driver, isolate strict or unset) and notes other containers on it; refuses foreign networks; refuses an existing container name before creating anything; rolls back the created container and network when `podman run` fails or on Ctrl-C
- V7-22 `pm rm [-f] <container>` – refuses running or paused containers without `-f`; removes the container, then each attached pm network without remaining containers; skips a still-used network with a note; a failed network removal prints a red error and returns 1
- V7-23 `pm net` – all networks with ISOLATE and the attached containers as `name (state)`; containers on no named network grouped as `(<mode>)` rows
- V7-24 completion: `rm` and `net`, `pm rm` flags before or after the container, `pm run --net` offers pm networks only, `--net=` and `--mount=` forms count as used flags

Decisions:

- tokens: a new secret is guaranteed only for containers created afterwards; podman documents this for `--replace`
- `pm secret-*` uses `--replace` only when the secret exists, because podman 4.9.3 fails with "no secret data with ID" when `--replace` meets a new name
- `pm ps` shows every container, not only pm containers
- an unset `CDPATH` inside the script keeps `--mount <relative dir>` from resolving elsewhere
- container states stay podman's (`created`, `running`, `exited`, `paused`) in `pm ps` and `pm net`; no mapping to `stopped`

Observed on podman 4.9.3, not documented:

- after `--replace`, new `podman exec` sessions of an existing container saw the new token, while PID 1 kept the old one
- `podman inspect` shows the secret value in `.Config.Env`, so `pm ps <container>` prints the token
- `podman network create` refuses a name that matches a prefix of an existing network ID ("already used"); pm passes that error on
- the old netavark there rejects `isolate=strict` when a container starts; network features were tested with `isolate=true` substituted; podman 6 is untested

## v8 (delivered in pm.sh, PM_VERSION=8)

- V8-01 `pm run --hc` gives the container a stable herdr-core identity, an id file and a state folder on the host, bind-mounted as in the dev container template of bugrasan/devcontainer-base-ai (`src/base-ai/.devcontainer/devcontainer.json`), and starts the core; the flag works in any position before `--`, and repeating it is harmless
- V8-02 `--hc` needs `--mount`; without it pm prints `pm run: --hc needs --mount`, a blank line, and the run help to stderr, and exits 2
- V8-03 dev container case, when `<dir>/.devcontainer` is a folder: id file `<dir>/.devcontainer/herdr-machine-id`, state folder `$HOME/.config/herdr-core/container/<foldername>-<devcontainerId>`; pm computes the devcontainer CLI's `${devcontainerId}` for the logical mount path (symlinks kept) and the config file `<dir>/.devcontainer/devcontainer.json`, whether or not it exists: the sha256 of the sorted id labels as JSON (JSON.stringify escaping), read as a 256-bit number and written as 52 base-32 digits; the escaping works on bytes (`LC_ALL=C`), so a multibyte locale such as GBK cannot change the id
- V8-04 root case, without `<dir>/.devcontainer`: id file `<dir>/herdr-machine-id`, state folder `$HOME/.config/herdr-core/container/<foldername>-<sha256 hex of the id>`
- V8-05 id file rules of the template's `initializeCommand`: pm keeps a valid id (32 lowercase hex digits once trailing newlines are dropped); it writes a missing or invalid one from `uuidgen`, else `/proc/sys/kernel/random/uuid` (dashes removed, lowercased), through a temp file and `mv`; a path that is not a regular file (a folder, a dangling link) or cannot be read is an error and stays untouched; a note for each new or replaced file
- V8-06 state folder: `mkdir -p`, then `chmod -- 700` on `$HOME/.config/herdr-core` and on the folder (700: the state holds terminal output, which may contain secrets; `--` first, as BSD chmod stops parsing options at the mode); a note for a new folder; a failed `mkdir` or `chmod` is an error
- V8-07 order: pm prepares the id file and the state folder after the container-exists check and before it creates a network or container, so a failure creates nothing in podman; the rollback of a failed `podman run` and `pm rm` keep both
- V8-08 hash tool: `sha256sum`, else `shasum -a 256`, else `openssl dgst -sha256 -r`; with none, an error
- V8-09 mounts: `-v <id file>:/etc/machine-id:ro` and `-v <state folder>:/home/vscode/.local/state/herdr-core`
- V8-10 after `podman run`, `podman exec -d -e SHELL=/bin/bash <container> hc serve` starts the core, and `sleep infinity` stays the main process: a green ok line, or a red error with podman's output and exit 1; the container stays
- V8-11 git note: when `git check-ignore` reports the id file as not ignored, pm prints `pm run: note: git does not ignore <file>; add it to .gitignore`; no note without git or outside a work tree
- V8-12 `pm start`, `pm stop`, `pm rm`, and `pm ps` are unchanged; the new mounts are not below `/workspaces`, so PROJECT stays as it was
- V8-13 `pm run --help` with the `--hc` option, a herdr-core section, and the start command in `runs:`, `[--hc]` in `pm help`, a HERDR-CORE section in `pm readme`, and `--hc` in the bash and zsh completion of `pm run` while it is not on the line yet
- V8-14 one core per state folder: before `podman run`, pm prints `pm run: note: <names> already mount the herdr-core state folder <path>; only one hc serve can run for it, and hc in every such container uses that core` when other containers (a dev container, a pm container under another name) bind-mount the state folder; it still starts `hc serve` and prints the ok line

Decisions:

- root-case state folder suffix: the sha256 hex of the id
- `hc serve` is a hidden subcommand that runs the core in the foreground, so pm starts it with `podman exec -d` and keeps `sleep infinity` as the main process: with `hc serve` as the main process, `hc server restart`, `hc server stop`, and `hc update` stop the container
- D14: pm passes `SHELL=/bin/bash`, because podman sets no SHELL and herdr-core starts new shells (`hc run --bg` without a program, keep recovery) from the core's own `$SHELL`, else `/bin/sh`; `/bin/bash` matches vscode's login shell in the base image and `pm bash`
- `PATH` is assumed set in the image; pm adds no handling
- a second container on a state folder gets a note, not a refusal (owner-neutral); its `hc serve` exits at once because the first core holds `core.lock`, and its `hc` drives that core through the shared socket
- `$HOME/.config` is used literally, not `$XDG_CONFIG_HOME`, so the paths match the dev container's
- `pm start` does not start the core; the first `hc` command does
- an id file that exists but cannot be read is an error, not replaced: pm cannot tell whether it holds a valid id (the spec left this case open)
- a `uuidgen` that fails is treated like a missing one: pm falls back to `/proc/sys/kernel/random/uuid`
- the open finding about `:` in mount paths also applies to the two `--hc` mounts

Tests (bats-core, `pm/tests/`):

- stub tests: `run-hc.bats` (49 tests) and `completion.bats` (7 tests) run pm with a fake `podman` (`stub/podman`) first in PATH that logs every call, and with HOME in a per-test folder; they cover S1 to S12 and H1 to H5 of the v8 spec and the review round 1 fixes; devcontainerId expectations come from the spec's JavaScript reference under node (`devcontainer-id.js`), and the spec's known value is checked through pm's own `_pm_devcontainer_id`; a GBK locale built with `localedef` into the test folder (`LOCPATH`) checks the byte-wise escaping, and GNU chmod with `POSIXLY_CORRECT` stands in for BSD chmod; run: `bats pm/tests/run-hc.bats pm/tests/completion.bats`
- against v7, 47 of the 56 stub tests fail; v8 passes all 56 as root and as a normal user (as root, the unreadable id file test skips)
- integration tests: `run-hc-podman.bats` (4 tests) with real rootless podman, only with `PM_TEST_PODMAN=1`; image from `PM_TEST_IMAGE` (default `ghcr.io/bugrasan/devcontainer-base-ai/base:latest`); besides mounts, core, and identity, they check `SHELL=/bin/bash` in the environment of `hc serve` and the note for a second container on the same folder; on the test host, run as root: `pm-as-testuser env PM_TEST_PODMAN=1 bats pm/tests/run-hc-podman.bats`; passed with podman 6.2.0 and hc 0.1.21

Observed with podman 6.2.0 and hc 0.1.21:

- the core writes `<state folder>/default/core.json` (`id`, `name`, `machine_id`) when it creates the identity and when a stored `core.json` takes on the current machine-id (herdr-core `server.rs`); a later start with the same machine-id rewrites `core.lock`, `default.sock`, and `terminals.json` and keeps `core.json`, so `name` stays the hostname of the first container
- `hc server status --json` reports the running core's id as `core.id`
- `podman ps --filter volume=<value>` compares a bare value with the mount target; only the form `<source>:<target>` matches a bind-mount source, so pm asks for `volume=<state folder>:/home/vscode/.local/state/herdr-core`

## v9 (delivered in pm.sh, PM_VERSION=9)

- V9-01 `PM_VERSION=9`: `pm --version` prints `pm 9`, and `pm run` labels containers and networks with `pm-script=9`
- V9-02 BUG-10: the herdr-core section of `pm run --help` and the readme say that pm notes other podman containers that already mount the state folder; `podman ps` sees only this user's podman containers, so containers of other engines, such as a dev container under Docker, are not detected
- V9-03 BUG-11: the note reads correctly for one or many names: `pm run: note: the herdr-core state folder <path> is already mounted by: <names>; only one hc serve can run for it, and hc in every such container uses that core`
- V9-04 BUG-12: the tests read pm.sh as bytes (`LC_ALL=C grep -a` in `pm_internal`), so under the GBK test locale they evaluate the whole script; grep used to drop the lines with an n-dash
- V9-05 every force option of pm is the long form only: `pm rm` accepts `--force` before or after the container and rejects `-f` like any other unknown option (usage to stderr, exit 2); the help, `pm help`, the readme (quick start: `pm rm --force pm-myapp`), the hint for a running or paused container (`stop it with: pm stop <container>, or use: pm rm --force <container>`), and both completions follow (no `-f`; containers after `--force`); `pm sh-file --force` and `pm zsh-file --force` already complied, and pm has no other force option
- V9-06 pm's own podman calls use the long form too: `podman rm --force` in `pm rm` and in the rollback of a failed `pm run`; coreutils keep `-f` (`rm -f`, `mv -f`, `ln -sf`), as their BSD versions on macOS have no `--force`

Tests (bats-core, `pm/tests/`):

- new `rm.bats` (6 stub tests) for V9-05 and V9-06; `completion.bats` checks `pm rm` in both shells; `run-hc.bats` checks V9-01 to V9-03; `run-hc.bats` and `run-hc-podman.bats` use `pm rm --force` and the new note
- against v8, 13 of the 64 stub tests fail; v9 passes all 64 as root and as a normal user (as root, the unreadable id file test skips)

## Open findings

- major (v7 review) – `--userns=keep-id` maps the host UID, so on hosts where it is not 1000 the container user cannot write `/home/vscode` and `pm bash` uses another HOME; fix candidate: `--userns=keep-id:uid=1000,gid=1000` or `PM_USERNS`
- minor (v7 review) – a `:` in a mount path breaks `-v`; `--mount type=bind,...` would move the problem to `,`
- minor (v7 review) – SELinux hosts need `:z` or `--security-opt label=disable` on bind mounts
- minor (network review) – `pm run --net=<Tab>` offers no network names, in both shells

## Candidates, not requested

- redact `$PM_CC_TARGET` and `$PM_CP_TARGET` values in `pm ps <container>`
- `pm help <subcommand>` as a synonym for `pm <subcommand> --help`
- cache the image list used by completion
- `pm cp` destination defaults to the basename of the source
- `-w /workspaces/<foldername>` so a mounted container starts in the workspace
- `pm secret-rm-cc` and `pm secret-rm-cp`
- zsh gaps: no trailing slash on `--mount` directory completion, and local files offered for `pm cp` argument 3
