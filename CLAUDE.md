# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Not an application - it's the build/launch scripts for a restricted, disposable Docker
sandbox used to run an AI coding harness (Claude Code, Hermes Agent and opencode today) or
any other tool against a project directory. There's no app code, no test suite, no
package manager. Everything is a shell script or config file consumed by
`docker build` / `docker run`.

## Layout

- `build.sh`, `run.sh` (+ `build.ps1`, `run.ps1`, `setup.ps1` for Windows) - entry points.
- `image/` - the harness-agnostic sandbox: `Dockerfile`, `entrypoint.sh`, `squid.conf`,
  `allowed-domains.txt` (shared default allowlist).
- `harnesses/<name>/` - everything tool-specific: `install.sh` (build time),
  `harness.conf` (mounts + default command), `allowed-domains.txt`. Format documented
  in `harnesses/README.md`.
- `config/` - personal, gitignored per-machine files, each seeded from a tracked
  `.example`: `run.local.sh`/`.ps1`, `extra-setup.sh`, `allowed-domains.txt`.
- `lib/windows-common.ps1` - shared PowerShell helpers.

**Keep harness specifics out of `image/`, `run.sh` and `run.ps1`.** If a new harness
needs something the `harness.conf` keys can't express, extend the format (and all
three readers: `run.sh`, `run.ps1`, `entrypoint.sh`) rather than special-casing a name.

## Commands

```sh
./build.sh [harness...]    # docker build -f image/Dockerfile --build-arg HARNESS=x -t agentcontainer:x . (always --no-cache); no args = all harnesses
cd ~/some-project && /path/to/run.sh          # launch a session scoped to that directory
run.sh --harness claude    # pick the harness (default: $HARNESS from env/config/run.local.sh, else claude)
run.sh --continue          # resume last session (any `-`-prefixed arg forwards to the harness)
run.sh --permission-mode manual            # claude starts in auto permission mode by default (harness.conf command); this overrides it
run.sh bash                # override the default harness command entirely
run.sh --help              # print flags + this machine's resolved harness/mounts/network config
run.sh --host-network      # share host network namespace (only for VPNs that block the bridge network)
run.sh --allow-list ./extra-domains.txt   # replace the squid egress allowlist for one session (no rebuild)
run.sh --mount ~/data                     # add an extra bind mount for one session, rw same path both sides (repeatable)
run.sh --mount ~/data:/data:ro            # ...or host:container[:ro] to mount elsewhere / read-only
run.sh --allow-container                  # mount the HOST's docker.sock in instead of the sandbox's nested dockerd (off by default - root-equivalent host access)
run.sh --sysbox                           # use the sysbox-runc runtime instead of --privileged (must be installed/registered on the host already)
run.sh --allow-config                     # let the harness write its config (harness.conf `config`/`staged` entries) back to the host - read-only by default
```

**Rebuild after touching anything in `image/` or `harnesses/`, or
`config/allowed-domains.txt` / `config/extra-setup.sh`** - all baked in at build time,
so a stale image keeps running the old version silently. (`harness.conf` is also read
on the host by `run.sh`, so mount changes apply immediately, but the default `command`
only changes after a rebuild.)

There's nothing to lint or test here; the way to validate a change is to rebuild and run
`run.sh` (or `run.sh bash` for a plain shell) and check the resulting container.

## Architecture

**`build.sh`** → seeds `config/extra-setup.sh` and `config/allowed-domains.txt` from
their `.example`s if missing, builds `agentcontainer:<harness>` for each requested harness
(repo root as context; `.dockerignore` whitelists `image/`, `harnesses/` and the two
config files), then prunes dangling images labeled `project=agentcontainer` (the
`--no-cache` builds otherwise pile up untagged layers).

**`harness.conf`** → `key=value`, space-separated lists, paths relative to `$HOME`:
`command` (default command; `-` args appended), `state` (rw dirs, created if missing),
`config` (ro on top of state unless `--allow-config`, skipped if missing), `staged`
(files the harness rewrites every start: rw with `--allow-config`, else mounted ro under
`/etc/agentcontainer/staged/<path>` and copied into `$HOME` by `entrypoint.sh`; created on
the host if missing, `{}` for `.json`), `owned` (absolute image paths that must belong
to `dev`: chowned to 1000:1000 by `install.sh`, re-chowned by `entrypoint.sh` only when
the UID remap moved `dev`). Parsed by `run.sh` (bash), `run.ps1`, and `entrypoint.sh`
(only `command` and `owned`, from the copy baked into `/etc/agentcontainer/`).

**`run.sh`** → per-session launcher, run from the *target* project directory (it resolves
its own path via `BASH_SOURCE`, so it works as a shell alias from anywhere). Resolves the
harness (`--harness` > `$HARNESS` from env/`config/run.local.sh` > `claude`), reads its
`harness.conf`, checks the image exists. Mounts `$PWD` (at the same absolute path), the
harness's `state`/`config`/`staged` paths at their host `$HOME` paths, and
`$SSH_AUTH_SOCK` if set (agent-forwarded git-over-SSH, no keys copied in) into a fresh
`--rm` container. Config is read-only by default because those files run with full
access on the host the next time the harness runs natively, so writing them = sandbox
escape. `EXTRA_CONFIG_RO_PATHS` in `config/run.local.sh` extends the ro list. No
whole-home mount, no persistent container. `config/run.local.sh` (gitignored) is sourced
for optional per-machine `EXTRA_MOUNTS`, `HARNESS`, `CONTAINER_UID`/`CONTAINER_GID` -
opt-in only, widen deliberately. `run.sh --mount <path>` (repeatable) adds
session-scoped extra mounts the same way. A bare path with no `:` mounts read-write at
the same path on both sides; use `host:container[:ro]` to differ. `run.sh
--allow-container` bind-mounts the *host's* `/var/run/docker.sock` in (and sets
`ALLOW_CONTAINER=1` so `entrypoint.sh` skips its own nested `dockerd`, which would
otherwise conflict on the same socket path) - off by default, since a Docker socket is
root-equivalent access to whatever host owns it. `run.sh --sysbox` swaps `--privileged`
for `--runtime=sysbox-runc` (https://github.com/nestybox/sysbox) - real user-namespace
isolation around the nested `dockerd` instead of near-full host access, but only selects
the runtime; it must already be installed and registered with the host's Docker daemon,
and `run.sh` checks `docker info` for it and refuses to start otherwise.

**`image/entrypoint.sh`** → container PID 1, runs as root first (starts squid, then
`dockerd` for Docker-in-Docker), copies staged files into `$HOME`, then `exec sudo -u
dev` drops to the unprivileged `dev` user for the actual command. Key subtlety: `dev`'s
*session* `$HOME` is repointed from its passwd-registered `/home/dev` to `HOST_HOME`
(the host's real `$HOME`, passed through by `run.sh`) so the harness's `$HOME`-derived
absolute paths (e.g. Claude Code's plugin marketplace `installLocation`) match what was
recorded when it last ran natively on the host. The default command is
`harness.conf`'s `command` (Claude: `claude --permission-mode auto`, set there rather
than in `settings.json` so the host's native `claude` is unaffected); forwarded `-` args
come after it, so a user-passed `--permission-mode` overrides it. Uses `sudo` rather
than `su -l` specifically to avoid `su`'s login-session `cd` to the target user's home
clobbering `run.sh`'s `-w "$PWD"`.

**`image/Dockerfile`** → shared part first, harness part last (after `ARG HARNESS`).
Ubuntu 24.04 base; hand-installed packages (no devcontainer.json features): Node 22 via
NodeSource, `gh` via its own apt repo, Python 3.14 via deadsnakes PPA (repoints
`python3`/`python` via `update-alternatives`), `docker.io`+`docker-compose-v2` for
Docker-in-Docker, `squid` for the egress proxy, `uv`/`uvx` and `bun` as static binaries
in `/usr/local/bin` (not a home-dir install - `sudo -u dev` doesn't preserve `PATH`, and
uvx/bun are execed directly by MCP servers). Creates a `dev` user at UID/GID 1000
(deletes Ubuntu's default `ubuntu` user first to free that UID); `entrypoint.sh` remaps
it at startup to the host user's UID/GID, which `run.sh` passes as `HOST_UID`/`HOST_GID`
(not for host root, rootless Docker or Podman; `CONTAINER_UID`/`CONTAINER_GID` override
the detection, `CONTAINER_UID=off` disables it). `.venv` auto-activation is wired into
`/etc/zsh/zshenv`. Then `config/extra-setup.sh`, then the harness: `install.sh`,
`harness.conf` → `/etc/agentcontainer/harness.conf`, and the allowlist (`image/` +
`harnesses/<name>/` + `config/` lists, comments stripped, `sort -u`).

**`image/squid.conf` + allowlist** → loopback-only (`127.0.0.1:3128`) forward proxy
allowlisting egress by domain. Both `HTTP_PROXY`/`HTTPS_PROXY`/lowercase mirrors and
explicit `apt`/`git` proxy config are set (curl/git/wget/Go's `net/http` only honor
lowercase `http_proxy` for plain `http://`, and apt/git are inconsistent about reading
proxy env vars at all). This is a guard against accidents, not a hard sandbox boundary -
there's no network-level (iptables) enforcement, so a tool that ignores proxy env vars
can still reach the network directly. A leading `.` matches the domain and all
subdomains. Entries may end in `:port`: `entrypoint.sh` splits the list at startup into
`allowed-dstdomains.txt` and `allowed-ports.txt` (80, 443 + listed ports, used for both
`Safe_ports` and `SSL_ports`), so a listed port is open for every allowed domain. `run.sh --allow-list <path>` bind-mounts a replacement file read-only to
`/etc/squid/allowed-domains.override.txt`, and `entrypoint.sh` `cp`s it over the baked-in
list before squid starts - session-scoped only (the container is `--rm`), no rebuild.

**`config/extra-setup.sh`** → optional, gitignored, per-machine hook for baking in extra
dependencies a custom MCP server or tool needs. Run as root near the end of the shared
part of the build (before the harness), in the unrestricted build-time network.

**Windows (`setup.ps1`, `build.ps1`, `run.ps1`, `lib/windows-common.ps1`)** →
PowerShell ports for Docker Desktop with the WSL2 backend. `run.ps1` mirrors `run.sh`'s
flags (including `--harness` and `harness.conf` parsing), but maps paths (`C:\x` →
`/c/x`) instead of using the same path on both sides. It doesn't remap the UID, doesn't
forward the SSH agent, and refuses `--sysbox`. Details are in `docs/windows.md`. **Keep
both ports in sync when adding a `run.sh` flag, a mounted path or a `harness.conf`
key.** Keep the scripts compatible with Windows PowerShell 5.1 (no `??`, `?:`, `&&`)
and plain ASCII; remember PowerShell variable names are case-insensitive. Native-command
probes must go through `Invoke-NativeQuiet` or `Invoke-NativeCapture`: under 5.1 with
`$ErrorActionPreference = 'Stop'`, redirected stderr from a native command throws. The
scripts have not been tested on Windows yet.

## Things worth knowing before changing behavior

- Record user-visible changes (new flags, changed defaults, removals) under
  `## Unreleased` in `CHANGELOG.md`; mark entries that need an image rebuild.

- `--privileged` is on by default (required for the inner `dockerd`), unless `--sysbox`
  is passed and the host has sysbox-runc installed; network mode is the only other thing
  `run.sh` toggles (`bridge` default vs. `--host-network`).
- No inbound SSH / no listening port - if JetBrains Gateway-style remote dev is ever
  needed again, that requires a separate persistent-container setup; it's incompatible
  with this repo's "fresh disposable container per session" model.
- Everything in `config/` except the `.example`s is gitignored (personal host paths /
  environment-specific egress rules / per-machine build dependencies) - don't assume the
  example files reflect what's actually deployed on a given machine.
