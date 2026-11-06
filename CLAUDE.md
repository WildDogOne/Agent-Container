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
- `image/` - the harness-agnostic sandbox: `Dockerfile`, `entrypoint.sh`,
  `inspect-proxy.py` (the mitmproxy egress addon), `allowed-domains.txt` (shared default
  allowlist).
- `harnesses/<name>/` - everything tool-specific: `install.sh` (build time),
  `harness.conf` (mounts + default command), `allowed-domains.txt`. Format documented
  in `harnesses/README.md`.
- `config/` - personal, gitignored per-machine files, each seeded from a tracked
  `.example`: `run.local.sh`/`.ps1`, `extra-setup.sh`, `allowed-domains.txt`.
- `tools/flowlog.py` - host-side analyzer for the `--proxy-logs` session logs
  (`summary`/`hosts`/`flows`/`show`/`grep`/`errors`/`denies`); not baked into the image.
- `lib/windows-common.ps1` - shared PowerShell helpers.

**Keep harness specifics out of `image/`, `run.sh` and `run.ps1`.** If a new harness
needs something the `harness.conf` keys can't express, extend the format (and all
three readers: `run.sh`, `run.ps1`, `entrypoint.sh`) rather than special-casing a name.

## Commands

```sh
./build.sh [harness...]    # docker build -f image/Dockerfile --build-arg HARNESS=x -t agentcontainer:x . (--no-cache, ~20 min for all); no args = all harnesses
./build.sh --cached [harness...]   # reuse the layer cache: fast after editing entrypoint.sh/the addon/allowlists (COPYed last), but updates nothing already cached
cd ~/some-project && /path/to/run.sh          # launch a session scoped to that directory
run.sh --harness claude    # pick the harness (default: $HARNESS from env/config/run.local.sh, else claude)
run.sh --continue          # resume last session (any `-`-prefixed arg forwards to the harness)
run.sh --permission-mode manual            # claude starts in auto permission mode by default (harness.conf command); this overrides it
run.sh bash                # override the default harness command entirely
run.sh --help              # print flags + this machine's resolved harness/mounts/network config
run.sh --host-network      # share host network namespace (only for VPNs that block the bridge network)
run.sh --allow-list ./extra-domains.txt   # replace the egress allowlist for one session (no rebuild)
run.sh --no-bash-sandbox                  # don't start harness.conf's sandboxed_command - it's the default for harnesses that define one (claude: Claude Code's own bubblewrap Bash sandbox inside the container)
run.sh --env-file ~/other.env             # pass a docker env file in (e.g. MCP tokens as ${VAR}); sandbox-relevant names refused
                                          # default: ~/.config/agentcontainer.env if it exists; --no-env-file / ENV_FILE=off for none
run.sh --mount ~/data                     # add an extra bind mount for one session, rw same path both sides (repeatable)
run.sh --mount ~/data:/data:ro            # ...or host:container[:ro] to mount elsewhere / read-only
run.sh --ca-cert ~/corp-root-ca.crt       # import an extra root CA into the container trust store for one session (repeatable; CA_CERTS in run.local.sh = default) - e.g. a corporate root so --inspect can validate/intercept an internal host's chain
run.sh --allow-container                  # mount the HOST's docker.sock in (no nested dockerd, no privileges - off by default, root-equivalent host access; excludes --with-docker/--sysbox)
run.sh --with-docker                      # nested dockerd + privileges: sysbox-runc runtime if registered on the host, --privileged otherwise (off by default - no Docker at all otherwise)
run.sh --sysbox                           # implies --with-docker and forces the sysbox-runc runtime (must be installed/registered on the host already)
run.sh --allow-config                     # let the harness write its config (harness.conf `config`/`staged` entries) back to the host - read-only by default
run.sh --proxy-logs [=PATH]               # mirror the session's proxy logs (mitmdump log + JSONL flow log) to the host (~/.local/state/agentcontainer/logs/<ts>-<harness>/, or PATH/PROXY_LOG_DIR); PROXY_LOGS=1 in run.local.sh = default, --no-proxy-logs forces off
run.sh --inspect                          # opt-in TLS interception (mitmproxy decrypts HTTPS): entrypoint.sh lets mitmdump generate a throwaway CA, installs it into the container's trust store only, and drops the default tunnel so flows (incl. bodies, with known secret shapes redacted) are logged; breaks TLS pinning - off by default (INSPECT=1)
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
(repo root as context, no `.dockerignore`: the Dockerfile `COPY`s only `image/`,
`harnesses/<name>/` and the two config files), then prunes dangling images labeled `project=agentcontainer` (the
rebuilds otherwise pile up untagged layers). The Dockerfile copies the repo's own
runtime files (`entrypoint.sh`, `inspect-proxy.py`, `redact_secrets.py`) at the very end
so a `--cached` rebuild after editing them skips every install step - keep new
frequently-edited files there too.

**`harness.conf`** → `key=value`, space-separated lists, paths relative to `$HOME`:
`command` (default command; `-` args appended), `sandboxed_command` (optional, used
instead of `command` by default whenever it's set - `AGENTCONTAINER_BASH_SANDBOX=1`
explicit or unset-with-one; `=0` (`run.sh --no-bash-sandbox`/`BASH_SANDBOX=0`) falls back
to `command`; `=1` with no `sandboxed_command` refuses to start), `state` (rw dirs, created if missing),
`config` (ro on top of state unless `--allow-config`, skipped if missing), `staged`
(files the harness rewrites every start: rw with `--allow-config`, else mounted ro under
`/etc/agentcontainer/staged/<path>` and copied into `$HOME` by `entrypoint.sh`; created on
the host if missing, `{}` for `.json`), `owned` (absolute image paths that must belong
to `dev`: chowned to 1000:1000 by `install.sh`, re-chowned by `entrypoint.sh` only when
the UID remap moved `dev`). Parsed by `run.sh` (bash), `run.ps1`, and `entrypoint.sh`
(only `command`, `sandboxed_command` and `owned`, from the copy baked into
`/etc/agentcontainer/`). `run.sh --env-file` passes a docker env file through and lists
its variable names in `AGENTCONTAINER_ENV_KEYS`, which `entrypoint.sh` adds to its
`preserve_env` list (the drop to `dev` starts from an empty environment); names the sandbox relies on (proxy vars,
`HOME`, `HOST_*`, `INSPECT`, `PROXY_LOGS`, `AGENTCONTAINER_*`, ...) are refused in both run scripts, as are the loader's `LD_*`,
`GCONV_PATH` and `OPENSSL_*` (docker gives env-file vars to `entrypoint.sh`'s root phase too, where root
honours them - pointing one into the project would load agent-planted code as root).
Claude's `sandboxed_command` is `harnesses/claude/claude-sandboxed`: generates
`--settings` per session (sandbox on, unsandboxed commands off, allowlist derived from
`/etc/agentcontainer/allowed-hosts.txt`, denyRead on `.credentials.json` and `~/.claude.json` backups but not the file
itself - MCP tokens go in the env file,
env-file vars denied, Docker/containerd sockets denied) and probes bwrap with the same
namespaces/`/proc` mount Claude Code uses. Under sysbox a fresh `/proc` is refused and
the `/proc` bind only passes with ipc/uts/cgroup namespaces too (sysbox's mount
interception), and Claude Code's `apply-seccomp` helper mounts a fresh `/proc` itself, so
nested mode = `enableWeakerNestedSandbox` + `allowAllUnixSockets` (skips the helper) +
`AGENTCONTAINER_BWRAP_EXTRA_NS=1`, which `harnesses/claude/bwrap-sysbox-shim` (installed as
`/usr/local/bin/bwrap`, ahead of `/usr/bin/bwrap`) turns into the extra unshare flags.

**`run.sh`** → per-session launcher, run from the *target* project directory (it resolves
its own path via `BASH_SOURCE`, so it works as a shell alias from anywhere). Resolves the
harness (`--harness` > `$HARNESS` from env/`config/run.local.sh` > `claude`), reads its
`harness.conf`, checks the image exists. Mounts `$PWD` (at the same absolute path) and
the harness's `state`/`config`/`staged` paths at their host `$HOME` paths into a fresh
`--rm` container. No SSH agent forwarding - git-over-SSH is unsupported by design
(outbound :22 is firewalled; pushing is a host-side operation). Config is read-only by default because those files run with full
access on the host the next time the harness runs natively, so writing them = sandbox
escape. `EXTRA_CONFIG_RO_PATHS` in `config/run.local.sh` extends the ro list. No
whole-home mount, no persistent container. `config/run.local.sh` (gitignored) is sourced
for optional per-machine `EXTRA_MOUNTS`, `CA_CERTS`, `HARNESS`, `CONTAINER_UID`/`CONTAINER_GID` -
opt-in only, widen deliberately. `run.sh --mount <path>` (repeatable) adds
session-scoped extra mounts the same way. A bare path with no `:` mounts read-write at
the same path on both sides; use `host:container[:ro]` to differ. `run.sh --ca-cert <path>`
(repeatable, or `CA_CERTS` in `run.local.sh`) bind-mounts extra root CA files ro under
`/etc/agentcontainer/ca-certs/`; `entrypoint.sh` imports them into the container's trust
store (`update-ca-certificates`) at start - chiefly so `--inspect` lets mitmproxy
validate an internal host's chain signed by a private root. `run.sh
--allow-container` bind-mounts the *host's* `/var/run/docker.sock` in (and sets
`ALLOW_CONTAINER=1` so `entrypoint.sh` skips its own nested `dockerd`, which would
otherwise conflict on the same socket path) - off by default, since a Docker socket is
root-equivalent access to whatever host owns it; mutually exclusive with
`--with-docker`/`--sysbox`. Default sessions pass neither: no dockerd, no privileges.
`run.sh --with-docker` sets `WITH_DOCKER=1` (entrypoint starts the nested `dockerd`) plus
`--runtime=sysbox-runc` when `docker info` lists it, `--privileged` otherwise;
`run.sh --sysbox` implies it and forces sysbox (https://github.com/nestybox/sysbox) -
real user-namespace
isolation around the nested `dockerd` instead of near-full host access, but only selects
the runtime; it must already be installed and registered with the host's Docker daemon,
and `run.sh` checks `docker info` for it and refuses to start otherwise.

**`image/entrypoint.sh`** → the container's main process (behind `docker run --init`'s
docker-init as PID 1, which forwards signals and reaps orphans), runs as root first (imports any
`/etc/agentcontainer/ca-certs/*.crt` - `run.sh --ca-cert` - into the system trust store
via `update-ca-certificates`, so a private root CA is trusted before the proxy starts and
mitmproxy can validate chains signed by it; then starts `mitmdump`, then
`dockerd` only with `WITH_DOCKER=1`; `ALLOW_CONTAINER=1` means the host socket is
mounted and no dockerd starts), copies staged files into `$HOME`, then `exec setpriv
--reuid=dev --regid=dev --init-groups env -i ...` drops to the unprivileged `dev` user
for the actual command, with an environment rebuilt from scratch (what sudo's
`env_reset` used to give, plus the `preserve_env` list). No root process stays behind -
that matters because Bash-sandbox sessions run with `systempaths=unconfined`, where
`/proc/sys` is writable by any root process. With
`/var/log/agentcontainer` mounted (`run.sh --proxy-logs`), it also spawns two
`setpriv`-as-`dev` `tail -F` sidecars mirroring the proxy's `/tmp` logs there (mitmdump's own log
+ the addon's JSONL flow log) - mitmdump runs as `agentproxy` and the log redirect is opened by root, so the host copies must come from the dev-side tail, including the
`>>` redirection (inside `sh -c`, not the root shell). Key subtlety: `dev`'s
*session* `$HOME` is repointed from its passwd-registered `/home/dev` to `HOST_HOME`
(the host's real `$HOME`, passed through by `run.sh`) so the harness's `$HOME`-derived
absolute paths (e.g. Claude Code's plugin marketplace `installLocation`) match what was
recorded when it last ran natively on the host. The default command is
`harness.conf`'s `command` (Claude: `claude --permission-mode auto`, set there rather
than in `settings.json` so the host's native `claude` is unaffected); forwarded `-` args
come after it, so a user-passed `--permission-mode` overrides it. Not `su -l`: its
login-session `cd` to the target user's home would clobber `run.sh`'s `-w "$PWD"`
(setpriv never changes directory).

**`image/Dockerfile`** → shared part first, harness part last (after `ARG HARNESS`).
Ubuntu 24.04 base; hand-installed packages (no devcontainer.json features): Node 22 via
NodeSource, `gh` via its own apt repo, Python 3.14 via deadsnakes PPA (repoints
`python3`/`python` via `update-alternatives`), `docker.io`+`docker-compose-v2` for
Docker-in-Docker, `mitmdump` (mitmproxy, installed in a dedicated `/opt/mitmproxy` venv on
that Python, symlinked into `/usr/local/bin`) for the egress proxy, `uv`/`uvx` and `bun` as static binaries
in `/usr/local/bin` (not a home-dir install - the drop to `dev` resets `PATH`, and
uvx/bun are execed directly by MCP servers). Creates a `dev` user at UID/GID 1000
(deletes Ubuntu's default `ubuntu` user first to free that UID); `entrypoint.sh` remaps
it at startup to the host user's UID/GID, which `run.sh` passes as `HOST_UID`/`HOST_GID`
(not for host root, rootless Docker or Podman; `CONTAINER_UID`/`CONTAINER_GID` override
the detection, `CONTAINER_UID=off` disables it). `.venv` auto-activation is wired into
`/etc/zsh/zshenv`. Then `config/extra-setup.sh`, then the harness: `install.sh`,
`harness.conf` → `/etc/agentcontainer/harness.conf`, and the allowlist (`image/` +
`harnesses/<name>/` + `config/` lists, comments stripped, `sort -u`).

**`image/inspect-proxy.py` + allowlist** → mitmproxy (`mitmdump`) as a loopback-only
(`127.0.0.1:3128`) forward proxy allowlisting egress by domain, IP and port; the addon
enforces the list and logs flows as JSONL. By default HTTPS is only tunneled
(`ignore_hosts=.*`) - the allowlist is still checked at CONNECT, but bodies are never
seen; `--inspect` drops the tunnel so mitmproxy decrypts and the addon logs full
request/response detail, redacted by `image/redact_secrets.py` (field names in parsed
JSON/form/query/headers, then gitleaks/betterleaks-derived token patterns - MIT
attribution in its docstring; redact before truncating). Both
`HTTP_PROXY`/`HTTPS_PROXY`/lowercase mirrors and explicit `apt`/`git` proxy config are set
(curl/git/wget/Go's `net/http` only honor lowercase `http_proxy` for plain `http://`, and
apt/git are inconsistent about reading proxy env vars at all). Enforced, not just
advisory: `entrypoint.sh` (as root, before the drop) installs an nftables output-chain
table `inet agentcfgr` - loopback, docker0/br-*, established/related, `agentproxy` and (only with `--with-docker`, for the nested dockerd) skuid root
pass (mitmdump runs as the unprivileged `agentproxy` system user, via `setpriv` + `env -i` so
env-file variables never reach it); everything else (dev included) is rejected, closing the
`curl --noproxy`/raw-socket/resolve-then-connect and :22 bypasses. Needs `--cap-add
NET_ADMIN` (added by both run scripts unless `--host-network`, when the whole firewall is
skipped so it can't touch the host's ruleset; `--allow-internet` also skips it, and the
addon then skips its domain/port checks via `AGENTCONTAINER_ALLOW_INTERNET`); fatal if
`nft` can't apply the rules. Nested containers' traffic (forward path) is not covered.
The allowlist format is unchanged: a leading `.` matches the domain and all subdomains;
bare IPv4/IPv6/CIDR entries are allowed too (IPv6 with a port: `[addr]:port`) (the addon matches them with `ipaddress` - a
domain match never matches raw-IP requests); entries may end in `:port`, which opens that
port globally (80, 443 + every listed port, parsed by the addon), so a listed port is open
for every allowed domain. The assembled list is baked to
`/etc/agentcontainer/allowed-hosts.txt`; `run.sh --allow-list <path>` bind-mounts a
replacement file read-only to `/etc/agentcontainer/allowed-hosts.override.txt`, and
`entrypoint.sh` copies it over the baked-in list before the proxy starts - session-scoped
only (the container is `--rm`), no rebuild.

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

- The default container is unprivileged: no `--privileged`, no nested `dockerd`
  (`entrypoint.sh` starts it only with `WITH_DOCKER=1`, set by `--with-docker`/`--sysbox`,
  which then add `--privileged` or the sysbox runtime). `dev` has no sudo in the image
  (the package isn't installed; `entrypoint.sh` drops root→dev with `setpriv`). Network mode is
  the only other thing `run.sh` toggles (`bridge` default vs. `--host-network`).
- No inbound SSH / no listening port - if JetBrains Gateway-style remote dev is ever
  needed again, that requires a separate persistent-container setup; it's incompatible
  with this repo's "fresh disposable container per session" model.
- Everything in `config/` except the `.example`s is gitignored (personal host paths /
  environment-specific egress rules / per-machine build dependencies) - don't assume the
  example files reflect what's actually deployed on a given machine.
