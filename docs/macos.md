# macOS hosts

On a Mac the sandbox runs through Docker Desktop: `build.sh`, `run.sh`, `doctor.py` and
the `tools/` scripts run unchanged on macOS, and the container runs inside Docker
Desktop's own Linux VM. There is no separate setup script and no second set of scripts -
the shell scripts are written to work with the `/bin/bash` macOS ships (3.2) and avoid
GNU-only command-line flags, so no coreutils from Homebrew is needed.

## 1. Set up and run

```sh
brew install --cask docker      # or download Docker Desktop; git comes from the CLT
open -a Docker                  # wait until the engine reports running
git clone https://github.zhaw.ch/Security-Operations-Center/Agent-Container.git ~/Agent-Container
cd ~/Agent-Container
./build.sh                      # same as on Linux
cd ~/path/to/some-project
~/Agent-Container/run.sh --allow-config   # first run only: log in, see README.md
~/Agent-Container/run.sh                  # every run after that
```

## How it differs from Linux

- **File sharing.** Docker Desktop exposes only `/Users`, `/Volumes`, `/private` and
  `/tmp` to its VM by default. A project anywhere else needs that path added under
  Settings -> Resources -> File sharing, or its bind mount is refused or arrives empty.
  `doctor.py` warns when the current directory is outside that set.
- **No `--sysbox`.** Sysbox can't be installed into Docker Desktop's VM, so
  `--with-docker` always falls back to `--privileged`. That's privileged inside Docker
  Desktop's VM, not over macOS itself.
- **`--allow-container` refuses to start.** `run.sh` checks for `/var/run/docker.sock`,
  which doesn't exist on a Mac (Docker Desktop's CLI socket is
  `~/.docker/run/docker.sock`) - and a mounted daemon socket would be the VM's daemon,
  not one on macOS. Use `--with-docker` for a nested daemon instead.
- **`--loopback-socket` is Linux-only.** A Unix socket on the macOS filesystem can't be
  bind-mounted into the VM, so there is nothing for `image/loopback-forward.py` to
  connect to.
- **`--host-network` shares the VM's network namespace**, not macOS's, and `run.sh` then
  skips the nftables egress firewall and `NET_ADMIN` - strictly weaker than the default
  bridge session, and it solves no Mac problem (the VM has its own network stack).
- **File ownership.** The UID/GID remap still happens (your Mac's uid/gid, e.g.
  `503:20`, becomes `dev` inside the container), but ownership of mounted paths comes
  from Docker Desktop's file-sharing layer rather than from macOS, so the remap mainly
  matters for paths the container creates itself.
- **Speed.** Mounted macOS folders go through a file-sharing layer that is slow on large
  trees, such as `node_modules` or `.venv`.
- **No git-over-SSH.** Same as on every host: outbound :22 is firewalled in the
  container and pushing is a host-side operation. Inside the container, use HTTPS
  remotes with `gh auth login`.

## Claude's Bash sandbox

Claude Code's sandboxed shell is bubblewrap running *inside* the container, which is why
`run.sh` adds `--security-opt seccomp=lib/seccomp-userns.json` and
`systempaths=unconfined`. That needs unprivileged user namespaces in Docker Desktop's
VM. If sandboxed Bash fails with `Operation not permitted`, that's the first thing to
suspect: `run.sh --no-bash-sandbox` starts the same session with the in-container shell
sandbox off (the container itself, its mounts and the egress proxy are unchanged).
`doctor.py` says which harnesses use it; it can't test the VM's kernel itself without
starting a container.

## If a session won't start

```sh
./doctor.py            # or: ./doctor.py claude opencode
```

The checks are the Linux ones - `run.sh` reads the same `config/run.local.sh` and the
same `harnesses/<name>/harness.conf` here - and three findings are phrased for Docker
Desktop on purpose:

- **A daemon that isn't answering** is Docker Desktop not running or switched to Windows
  containers, not a missing `systemctl` unit or a missing `docker` group.
- **No `sysbox-runc` runtime** is expected and unfixable here; only the `--with-docker`
  consequence matters.
- **A project outside the shared folders** is a File sharing setting, not a permissions
  problem.
