# Harnesses

Each subdirectory here is one coding tool the sandbox can run: `claude/` is Claude Code,
`hermes/` is [Hermes Agent](https://github.com/NousResearch/hermes-agent), `opencode/` is
[opencode](https://opencode.ai).
The sandbox itself (`image/`, `run.sh`, `run.ps1`) knows nothing about any of them - it
reads everything harness-specific from these three files:

| File | Used by | Purpose |
|---|---|---|
| `install.sh` | `image/Dockerfile` | Installs the tool. Runs as root at build time, after Node, Python 3.14, uv and bun are on `PATH`. Install binaries to `/usr/local/bin`, not a home directory (`sudo -u dev` doesn't keep `PATH`). |
| `allowed-domains.txt` | `image/Dockerfile` | Domains the tool needs at runtime, added to the shared allowlist in `image/allowed-domains.txt`. |
| `harness.conf` | `run.sh`, `run.ps1`, `image/entrypoint.sh` | How to start the tool and which of your host config to mount in - see below. |

Each harness gets its own image, `devcontainer:<name>`, built with `./build.sh <name>`
and started with `run.sh --harness <name>`.

## harness.conf

Plain `key=value` lines; `#` starts a comment. List values are space-separated, so
paths can't contain spaces. `state`, `config` and `staged` paths are relative to your
home directory and are mounted at the same path inside the container.

| Key | Meaning |
|---|---|
| `command` | Default command when `run.sh` is given none. Arguments starting with `-` (`run.sh --continue`) are appended to it. |
| `state` | Directories mounted read-write: login, session history, caches. Created on the host if missing. |
| `config` | Files or directories mounted read-only on top of `state`, unless `--allow-config`. Anything that makes the tool run code or change behavior the next time you use it natively on the host belongs here. Missing entries are skipped. |
| `staged` | Files the tool rewrites on every start. With `--allow-config` they're mounted read-write; otherwise they're mounted read-only and copied into the container, so edits are discarded on exit. Created on the host if missing (`{}` for `.json`, empty otherwise). |
| `owned` | Absolute paths inside the image that must belong to the `dev` user, for tools that refuse to run an install owned by someone else. `install.sh` chowns them to `1000:1000`; if `dev` is remapped to a different host UID, `entrypoint.sh` re-chowns them at startup. Rarely needed (see `hermes/`). |

## Adding a harness

1. Copy `claude/` to `harnesses/<name>/` and rewrite the three files.
2. `./build.sh <name>`
3. `run.sh --harness <name>`, or set `HARNESS=<name>` in `config/run.local.sh` to make
   it your default.
