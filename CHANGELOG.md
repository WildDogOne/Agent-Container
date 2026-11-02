# Changelog

Notable changes to this sandbox (called claudecontainer before the harness split).
Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Entries marked **rebuild** touch a file baked into the image - run `./build.sh` before
the change takes effect.

## Unreleased

### Changed

- Egress is now **enforced, not just proxied**: `entrypoint.sh` installs an nftables
  output-chain firewall (loopback, Docker bridges, established flows and the
  root/proxy uids pass; everything else - `dev` included - is rejected), closing the
  `curl --noproxy`, raw-socket, direct-DNS and resolve-then-connect bypasses.
  `run.sh`/`run.ps1` add `--cap-add NET_ADMIN` (container-netns-scoped) for it.
  `--allow-internet` now also drops the firewall (full internet, its stated purpose);
  `--host-network` skips it so the rules can never touch the host's ruleset, and now
  warns loudly about the host-loopback access it grants. **rebuild**
  (`image/Dockerfile`, `image/entrypoint.sh`); the run scripts apply without one.
- The egress allowlist now accepts **bare IPv4/CIDR entries** (`10.10.10.81:8896`),
  enforced via a second squid `dst` ACL - `dstdomain` never matches a request aimed at
  a raw IP, so tools configured with an IP host (e.g. a self-hosted model server on
  the LAN) were silently unreachable once traffic actually went through squid.
  **rebuild** (`image/squid.conf`, `image/entrypoint.sh`)
- Documented a known Bash-sandbox leak in nested (sysbox) mode: sandboxed commands can
  read `/proc/<pid>/environ` of Claude Code and its MCP servers (container `/proc`,
  same UID), so `--env-file` variables are exposed to sandboxed shell commands there.
  (`harnesses/claude/claude-sandboxed` header, README, `docs/quickstart-claude.md`)
  **rebuild** (header comment only)
- **git-over-SSH support removed**: the `SSH_AUTH_SOCK` agent-forwarding mount is gone
  from both `run.sh` and `run.ps1` (outbound :22 falls into the firewall reject).
  Pushing is a host-side operation; inside the container use HTTPS remotes with
  `gh auth`.

- Default posture: a session now runs **unprivileged with no Docker at all**. The nested
  `dockerd` and `--privileged` are opt-in via the new `run.sh --with-docker` (uses the
  `sysbox-runc` runtime when the host has it registered, `--privileged` otherwise);
  `--sysbox` implies `--with-docker` and forces sysbox. `--allow-container` (host
  socket) needs no privileges and is now mutually exclusive with both. `WITH_DOCKER=1`
  in `run.local.sh`/`run.local.ps1` makes it standing. `run.sh --help` shows what the
  session gets. **rebuild** (`image/entrypoint.sh`); the run scripts apply without one.
- The Bash sandbox is **on by default** for every harness that defines a
  `sandboxed_command` (claude today): a session starts it unless you pass
  `--no-bash-sandbox` or set `BASH_SANDBOX=0`. `--bash-sandbox` stays as an explicit
  opt-in (refused for harnesses without one); harnesses that have no
  `sandboxed_command` (hermes, opencode) run their plain `command` as before.
  **rebuild** (`image/entrypoint.sh`)
- `dev` has **no `sudo` inside the container** anymore (the NOPASSWD sudoers entry is
  gone; `entrypoint.sh` still drops from root PID 1 to `dev` via sudo, which doesn't
  need an entry). As a replacement for the old `sudo tail` advice, the squid logs are
  world-readable: `tail /tmp/squid-access.log`. **rebuild** (`image/Dockerfile`,
  `image/entrypoint.sh`)
- Hermes harness: `~/.hermes/installs` (the dependency environment Hermes prepares on
  first launch and then *executes*) is no longer symlinked into the container's session
  home by `hermes-session` - it's container-local now, prepared per session. Sharing it
  rw let a session plant code that the host's native hermes would run from the shared
  `~/.hermes`. Cost: `installs/` is re-downloaded per session. **rebuild**
  (`harnesses/hermes/`)
- Claude harness: `~/.claude/shell-snapshots` is no longer shared read-write with the
  host. Claude Code sources those snapshots in every later Bash session, native host
  runs included, so a session could hand the host a file to execute. It's now covered by
  a container-local tmpfs (new `harness.conf` key `tmpfs`, see below): writable in the
  session, discarded on exit. **rebuild** (`harnesses/claude/`, `image/entrypoint.sh`)
- `run.sh --bash-sandbox` (claude): the generated settings now also deny `Edit` on the
  project's own `.claude/settings.json`, `.claude/settings.local.json` and `.mcp.json`.
  Those live in the writable project mount, where the read-only config mounts can't
  reach them, and the host's own `claude` trusts them on the next run in that folder.
  Note: only the sandboxed mode gets these rules; with `--no-bash-sandbox` the project
  settings stay writable. **rebuild** (`harnesses/claude/claude-sandboxed`)

### Fixed

- Hermes harness: starting a second `run.sh --harness hermes` session while one is
  already running failed with `Error: Gateway connection failed; no local fallback`.
  Hermes runs one gateway daemon per Hermes home, discovered through
  `gateway.lock`/`gateway.sock` at the home's root and dialed over loopback TCP;
  with `~/.hermes` bind-mounted into every container, session 2 found session 1's
  gateway inside another network namespace and couldn't reach it. `hermes` in the
  container is now a wrapper that runs each session with a container-local
  `~/.hermes-session` home, symlinking everything but the gateway runtime files,
  `state.db` and `logs` from the shared `~/.hermes` - config, `.env`, `auth.json`,
  skills, hooks, cron, memories and transcripts stay shared; each container runs
  its own gateway with its own session store (Hermes enforces one writer per
  `state.db`), so `--continue` only sees the sessions of that container.
  **rebuild** (`harnesses/hermes/`)

### Added

- `harness.conf` key `tmpfs` (space-separated, relative to `$HOME`): paths mounted as
  container-local tmpfs on top of a `state` dir - writable inside the session, never
  reach the host, discarded on exit. For state the tool must write *and* later executes.
  Parsed by `run.sh`, `run.ps1` and `entrypoint.sh` (which chowns the root-owned mounts
  to dev); listed by `--help`. Format documented in `harnesses/README.md`. **rebuild**
  (`image/entrypoint.sh`; the run scripts apply without a rebuild)
- `run.sh --bash-sandbox` (or `BASH_SANDBOX=1` in `config/run.local.sh`): starts the
  harness's new `harness.conf` key `sandboxed_command` instead of `command`. For Claude
  Code that's `claude-sandboxed`, which turns on Claude Code's own Bash sandbox
  (bubblewrap) inside the container: shell commands get no direct network access (only
  the allowlisted domains, via Claude Code's proxy) and can't read the login token or
  the backups of `~/.claude.json` (which may predate moving tokens to `--env-file`). Works under `--sysbox` in a nested mode (shared `/proc`, a `bwrap`
  wrapper adding the ipc/uts/cgroup namespaces sysbox requires, Docker sockets denied as
  files instead of seccomp); refuses to start if bubblewrap doesn't work at all. Opt-in,
  nothing changes without it. **rebuild** (claude image: bubblewrap, socat,
  `claude-sandboxed`, `/usr/local/bin/bwrap` wrapper; `entrypoint.sh`)
- `run.sh --env-file FILE` (or `ENV_FILE=` in `config/run.local.sh`): passes a docker
  env file into the session, e.g. tokens MCP servers reference as `${VAR}`, so they
  don't have to sit in plaintext in `~/.claude.json`. Variables the sandbox relies on
  (proxy settings, `HOME`, `HOST_*`, `SQUID_*`, `AGENTCONTAINER_*`, ...) are refused.
  With `--bash-sandbox`, shell commands don't see them. **rebuild** (`entrypoint.sh`)
- Default env file: without `--env-file`/`ENV_FILE`, `~/.config/agentcontainer.env` is
  passed in if it exists. `--no-env-file` (or `ENV_FILE=off`) skips it. `run.sh` warns if
  the env file is accessible by other users or lies inside the mounted `$PWD`.
- Both flags in `run.ps1` too (`$BASH_SANDBOX`, `$ENV_FILE` in `run.local.ps1`), untested.

- Third harness: [opencode](https://opencode.ai) (`./build.sh opencode`,
  `run.sh --harness opencode`). Sessions and logins live in `~/.local/share/opencode`
  and `~/.local/state/opencode`; `~/.config/opencode` is read-only unless
  `--allow-config`, and `~/.cache/opencode` (downloaded LSP servers, npm packages) stays
  inside the container.
- Second harness: [Hermes Agent](https://github.com/NousResearch/hermes-agent)
  (`./build.sh hermes`, `run.sh --harness hermes`). Its state and config live in
  `~/.hermes`; the install itself is baked into the image under `/opt/hermes`.
- Allowlist entries can name a port (`llm.example.lan:8080`), which opens that port in
  the egress proxy on top of 80/443 - for self-hosted model servers and the like.
  Works in `config/allowed-domains.txt` (rebuild) and `--allow-list` files.
- `harness.conf` key `owned`: image paths re-chowned to `dev` at startup when `dev` is
  remapped to a different UID (needs a rebuild of every image, since it's read by
  `entrypoint.sh`).

- `build.sh`/`build.ps1` create `allowed-domains.txt` from `allowed-domains.txt.example`
  if it's missing (like `extra-setup.sh`), instead of failing the build.
- Windows support through Docker Desktop (WSL2 backend), untested so far:
  `setup.ps1` installs WSL2, Docker Desktop (via winget, falling back to Docker's own
  installer) and Git for Windows; `build.ps1` checks
  WSL2 and Docker (and starts Docker Desktop) before building; `run.ps1` is `run.sh`
  with the same flags, except `--sysbox`. Per-machine config goes in `run.local.ps1`.
  See `docs/windows.md`.
- CRLF line endings are stripped from `entrypoint.sh`, `squid.conf`,
  `allowed-domains.txt` and `extra-setup.sh` at build time, and from `--allow-list`
  files at startup. `.gitattributes` keeps tracked files LF. **rebuild**

- `run.sh --allow-config`: lets a session write Claude Code's configuration back to the
  host. Without it, config is now read-only (see Changed).
- `dev` inside the container now takes the invoking host user's UID/GID at startup
  (`run.sh` passes `HOST_UID`/`HOST_GID`, `entrypoint.sh` remaps), so mounted files
  stay owned by the host user even when their UID isn't 1000. Skipped for host root,
  rootless Docker and Podman. Override with `CONTAINER_UID`/`CONTAINER_GID` in
  `run.local.sh` (or the environment), or `CONTAINER_UID=off`; `run.sh --help` shows
  the result. **rebuild**
- README: first-run instructions for hosts without Claude Code installed (pre-create
  `~/.claude`/`~/.claude.json`, log in once with `--allow-config`).

### Changed

- **rebuild** `run.sh --allow-internet` now also drops squid's port restrictions, so any
  host (bare IPs included) is reachable on any port, e.g. a Kubernetes API server on
  `:6443`. Previously only 80/443 plus allowlisted ports worked.
- **rebuild** Renamed from Devcontainer to Agent-Container. The repo now lives at
  [github.zhaw.ch/Security-Operations-Center/Agent-Container](https://github.zhaw.ch/Security-Operations-Center/Agent-Container).
  Images are now `agentcontainer:<harness>` (was `devcontainer:<harness>`), labeled
  `project=agentcontainer`, with the baked-in config under `/etc/agentcontainer/`. Run
  `./build.sh` to build the new images, then remove the old ones with
  `docker rmi $(docker images -q --filter label=project=devcontainer)`.
- **Repository restructured, Claude Code split out into a "harness".** The sandbox
  moved from `claudecontainer/` to the repo root: `build.sh`/`run.sh` (and the `.ps1`
  scripts) at the top, `Dockerfile`/`entrypoint.sh`/`squid.conf` in `image/`,
  personal files in `config/`, `windows-common.ps1` in `lib/`. Everything
  Claude-specific now lives in `harnesses/claude/` (`install.sh`, `harness.conf`,
  `allowed-domains.txt`), and the sandbox reads it from there - see
  `harnesses/README.md` for adding another harness. **rebuild**
- Images are now `devcontainer:<harness>` (was `claudecontainer:latest`), one per
  harness. `build.sh` builds all of them, or the ones named; `run.sh --harness <name>`
  (or `HARNESS=` in `config/run.local.sh`/the environment) picks one, default `claude`.
  Remove the old image with `docker rmi claudecontainer:latest`.
- **Moving your personal files:** `run.local.sh`, `run.local.ps1`, `extra-setup.sh` and
  `allowed-domains.txt` now live in `config/`. `CLAUDE_CONFIG_RO_PATHS` is now
  `EXTRA_CONFIG_RO_PATHS`, with paths relative to `$HOME` (`statusline.sh` becomes
  `.claude/statusline.sh`).
- The egress allowlist is assembled at build time from `image/allowed-domains.txt`
  (shared defaults), `harnesses/<name>/allowed-domains.txt` and your
  `config/allowed-domains.txt`, which now only needs your own additions instead of the
  whole list. `--allow-list` still replaces the whole list for one session. **rebuild**
- `run.sh` now creates the harness's state directories and staged files (`~/.claude`,
  `~/.claude.json`) if they're missing, like `run.ps1` already did, and refuses to start
  with a clear message when the image hasn't been built.
- **Claude Code config is read-only by default.** `settings.json`,
  `settings.local.json`, `CLAUDE.md`, `keybindings.json`, `agents/`, `commands/`,
  `skills/`, `hooks/`, `plugins/` and `output-styles/` under `~/.claude` are mounted
  `:ro` (where they exist); `~/.claude.json` is copied into the container from a
  read-only mount, so in-session edits to it are discarded on exit. Session state (transcripts, history,
  `.credentials.json`) stays writable. Extend the list from
  `run.local.sh` via `CLAUDE_CONFIG_RO_PATHS+=(...)`. **rebuild**
- **Claude starts in auto permission mode** (`--permission-mode auto`) inside the
  container. Override per session with `run.sh --permission-mode manual`. **rebuild**

## 2026-10-01

### Fixed

- `run.sh` works with macOS's bash 3.2: an empty argument list no longer trips
  `set -u` ("unbound variable").

## 2026-09-30

### Changed

- README restructured and trimmed. Sysbox install instructions (Ubuntu/Debian and Arch)
  moved to `docs/sysbox.md`.

## 2026-09-28

### Added

- `extra-setup.sh`: optional, gitignored per-machine build hook for extra apt/npm/uv
  packages or custom MCP server dependencies. Runs as root late in the build.
  `build.sh` seeds a no-op copy from `extra-setup.sh.example` if missing. **rebuild**

## 2026-09-20

### Added

- `run.sh --sysbox`: run with the `sysbox-runc` runtime instead of `--privileged`, for
  user-namespace isolation around the nested `dockerd`. Sysbox must already be
  installed; `run.sh` refuses to start if the runtime isn't registered.
- README note that Claude flags need their leading dashes (`run.sh --remote-control`,
  not `run.sh remote-control`, which fails with `sudo: remote-control: command not found`).

## 2026-09-19

### Added

- `run.sh --allow-container`: mounts the **host's** Docker socket instead of starting a
  nested `dockerd`. Containers started this way are siblings on the host daemon.
  Root-equivalent host access, off by default. **rebuild**

## 2026-09-16

### Added

- `run.sh --allow-internet`: drops squid's domain allowlist for one session. Port
  restrictions (HTTP on 80, CONNECT to 443) and proxy logging stay in place. Mutually
  exclusive with `--allow-list`. **rebuild**

## 2026-09-01

### Added

- `run.sh --mount <path|host:container[:ro]>`: one-off extra bind mounts for a single
  session, on top of `EXTRA_MOUNTS`. Repeatable; a bare path mounts read-write at the
  same path.

## 2026-08-31

### Added

- `run.sh --allow-list <path>`: replaces the egress allowlist for one session without
  touching the image. **rebuild**

## 2026-08-18

### Changed

- `build.sh` always builds with `--no-cache` and prunes the dangling images it leaves
  behind (scoped by a `project=claudecontainer` image label). **rebuild**
- `build.sh` no longer builds with `--network host`.

## 2026-08-08

### Added

- `run.sh --host-network`: opt-in host networking for VPNs that block the bridge network.
- `run.sh --help`: lists flags plus this machine's resolved mounts and network mode.
- Bun in the image (needed by the official Telegram plugin). **rebuild**

### Changed

- **Containers use Docker's bridge network by default** instead of `--network host`.
- `~/.claude` and `~/.claude.json` are mounted at the host's `$HOME` path, and `dev`'s
  `$HOME` is set to match. Fixes `cache-miss` errors for plugins installed on the host. **rebuild**

## 2026-08-07

Initial release.

### Added

- Disposable Ubuntu 24.04 image with Claude Code, Node 22, Python 3.14, uv, `gh`,
  Docker-in-Docker and zsh. Projects' `.venv` is activated automatically.
- `run.sh`: starts a `--rm` container scoped to `$PWD`, mounts the Claude Code login and
  forwards the host's ssh-agent. Args starting with `-` go to `claude`; anything else
  replaces the command.
- `run.local.sh` (gitignored, from `run.local.sh.example`): standing per-machine
  `EXTRA_MOUNTS`.
- Squid egress proxy with a domain allowlist. Proxy settings are applied to env (both
  casings), apt and git. The allowlist lives in `allowed-domains.txt` (gitignored, from
  `allowed-domains.txt.example`).
