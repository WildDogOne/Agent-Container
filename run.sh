#!/usr/bin/env bash
# Launches a fresh, disposable sandbox container scoped to the current directory - run
# this from whatever project you want the harness (Claude Code by default, or anything
# else in the image) to have access to. Only $PWD and the harness's own login/state get
# mounted in; nothing else on the host is reachable from inside, and the container is
# removed on exit (--rm) so there's no persistent state or mount to go stale. Extra
# arguments starting with `-` are forwarded to the harness itself (e.g. `run.sh
# --continue`); anything else overrides the harness's default command entirely (e.g.
# `run.sh bash` for a plain shell).
#
# `--harness <name>` (consumed here, not forwarded on) picks which harness to run, i.e.
# which harnesses/<name>/harness.conf decides the mounts and default command, and which
# devcontainer:<name> image to start (build it with `build.sh <name>`). Defaults to
# $HARNESS (environment or config/run.local.sh), else claude.
#
# Runs on Docker's default bridge network unless `--host-network` is passed (consumed
# here, not forwarded on). Only needed when the host's own network setup - e.g. a
# corporate VPN - blocks the bridge network from reaching DNS/the internet; see
# README.md. `--host-network` shares the host's network namespace outright, so treat it
# as an opt-in trade of isolation for connectivity, not a default. Run `run.sh --help`
# for a summary of flags and this machine's resolved config (mounts, network mode).
#
# `--allow-list <path>` (consumed here, not forwarded on) swaps the squid egress
# allowlist for that one session: the given file is bind-mounted read-only and
# entrypoint.sh overwrites the image's baked-in allowed-domains.txt with it before squid
# starts. Only affects this disposable container - the image itself, and every other
# session, still use the default list. See README.md.
#
# `--mount <path>` or `--mount <host:container[:ro]>` (consumed here, not forwarded on;
# repeatable) adds one extra bind mount to this session only, on top of $PWD/the
# harness's state/run.local.sh's EXTRA_MOUNTS. A bare path with no ':' mounts read-write at that
# same path on both sides (e.g. `--mount ~/data` -> ~/data:~/data); give host:container[:ro]
# explicitly to mount elsewhere or read-only. Use it for a one-off session that needs a
# path run.local.sh doesn't already cover; for anything needed on every session on this
# machine, put it in run.local.sh instead.
#
# `--allow-internet` (consumed here, not forwarded on) drops squid's domain allowlist for this
# one session: entrypoint.sh patches the running config so `http_access allow
# allowed_dst` becomes `http_access allow all`, while leaving the Safe_ports/SSL_ports
# checks in place (still only plain HTTP on 80 and CONNECT to 443 through the proxy).
# Traffic is still proxied and logged, just no longer domain-filtered. Only affects this
# disposable container - the image, allowed-domains.txt, and every other session are
# untouched. Mutually exclusive with --allow-list (one drops the list, the other swaps
# it - combining them is almost certainly not what you meant).
#
# `--allow-container` (consumed here, not forwarded on) bind-mounts the HOST's own Docker
# socket (/var/run/docker.sock) into the container, instead of the nested dockerd
# entrypoint.sh otherwise starts inside the container. Containers started this way are
# siblings on the host's real Docker daemon, not nested inside the sandbox - they see the
# host's other containers/images/networks and are not cleaned up when this container
# exits. Off by default: a container's root-equivalent access to the host's Docker socket
# is effectively root on the host (bind-mount any host path in, run as any UID). Only pass
# this for a workflow that specifically needs the host daemon (e.g. driving host
# `docker compose` services) and that you trust to run inside this sandbox.
#
# `--sysbox` (consumed here, not forwarded on) swaps `--privileged` for
# `--runtime=sysbox-runc` (https://github.com/nestybox/sysbox), which must already be
# installed and registered with the host's Docker daemon - this script only selects it,
# it doesn't install it. Sysbox gives the nested dockerd entrypoint.sh starts real
# user-namespace isolation instead of `--privileged`'s "may as well be root on the host"
# access, at the cost of a host-side dependency beyond plain Docker. Irrelevant if
# combined with --allow-container, since that path skips the nested dockerd entirely -
# there's nothing left for sysbox's isolation to apply to.
#
# `--allow-config` (consumed here, not forwarded on) lets this session write to the
# harness's *configuration*. By default it can't: the harness's `state` dirs (e.g.
# ~/.claude - transcripts, history, OAuth token refreshes; the harness breaks without
# them) stay read-write, but its `config` entries (plus EXTRA_CONFIG_RO_PATHS) are
# bind-mounted read-only on top of them, and its `staged` files (e.g. ~/.claude.json)
# are mounted read-only at a staging path that entrypoint.sh copies into the
# container's own $HOME (the harness rewrites those on every start, so they must stay
# writable - edits just never reach the host). The point: hooks, MCP servers, plugins,
# agents, commands and skills all run with full access on the HOST the next time you
# run the harness natively, so a session that gets talked into editing them could
# escape the sandbox. See harnesses/README.md.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cli_harness=""
host_network=0
show_help=0
allow_list=""
allow_internet=0
allow_container=0
allow_config=0
sysbox=0
cli_mounts=()
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host-network) host_network=1; shift ;;
    -h|--help) show_help=1; shift ;;
    --allow-internet) allow_internet=1; shift ;;
    --allow-container) allow_container=1; shift ;;
    --allow-config) allow_config=1; shift ;;
    --sysbox) sysbox=1; shift ;;
    --harness)
      if [[ $# -lt 2 ]]; then
        echo "run.sh: --harness requires a harness name" >&2
        exit 1
      fi
      cli_harness="$2"
      shift 2
      ;;
    --allow-list)
      if [[ $# -lt 2 ]]; then
        echo "run.sh: --allow-list requires a path argument" >&2
        exit 1
      fi
      allow_list="$2"
      shift 2
      ;;
    --mount)
      if [[ $# -lt 2 ]]; then
        echo "run.sh: --mount requires a host path, or host:container[:ro], argument" >&2
        exit 1
      fi
      # No ':' -> mount at the same path on both sides, read-write (matches $PWD's own
      # same-path-both-sides default above). Give container:ro explicitly to differ.
      if [[ "$2" == *:* ]]; then
        cli_mounts+=("$2")
      else
        cli_mounts+=("$2:$2")
      fi
      shift 2
      ;;
    *) args+=("$1"); shift ;;
  esac
done
# ${args[@]+...} guard: macOS's bash 3.2 treats an empty array as unbound under set -u.
set -- ${args[@]+"${args[@]}"}

if [[ -n "$allow_list" && "$allow_internet" -eq 1 ]]; then
  echo "run.sh: --allow-list and --allow-internet are mutually exclusive" >&2
  exit 1
fi

if [[ -n "$allow_list" ]]; then
  if [[ ! -f "$allow_list" ]]; then
    echo "run.sh: --allow-list file not found: $allow_list" >&2
    exit 1
  fi
  allow_list="$(cd "$(dirname "$allow_list")" && pwd)/$(basename "$allow_list")"
fi

if [[ "$allow_container" -eq 1 && ! -S /var/run/docker.sock ]]; then
  echo "run.sh: --allow-container passed but /var/run/docker.sock not found on this host" >&2
  exit 1
fi

if [[ "$sysbox" -eq 1 ]] && ! docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q sysbox-runc; then
  echo "run.sh: --sysbox passed but the sysbox-runc runtime isn't registered with this" >&2
  echo "host's Docker daemon. Install sysbox first: https://github.com/nestybox/sysbox" >&2
  exit 1
fi

# Personal, per-machine settings - see config/run.local.sh.example. Gitignored and
# entirely optional: nothing breaks if it's missing, everything keeps its default.
# EXTRA_CONFIG_RO_PATHS: more paths (relative to $HOME) to keep read-only unless
# --allow-config, on top of the harness's own `config` list - e.g. a statusline script
# your settings point at. Missing entries are skipped.
EXTRA_MOUNTS=()
EXTRA_CONFIG_RO_PATHS=()
# Seeded from the environment so a one-off `HARNESS=x run.sh` / `CONTAINER_UID=1234
# run.sh` works; run.local.sh can set them permanently.
HARNESS="${HARNESS:-claude}"
CONTAINER_UID="${CONTAINER_UID:-}"
CONTAINER_GID="${CONTAINER_GID:-}"
if [[ -f "$script_dir/config/run.local.sh" ]]; then
  . "$script_dir/config/run.local.sh"
fi

harness="${cli_harness:-$HARNESS}"
harness_conf_file="$script_dir/harnesses/$harness/harness.conf"
if [[ ! -f "$harness_conf_file" ]]; then
  echo "run.sh: unknown harness '$harness' (no $harness_conf_file)" >&2
  exit 1
fi
image="devcontainer:$harness"

# See harnesses/README.md for the keys. Space-separated lists; last line wins.
harness_conf() { sed -n "s/^$1=//p" "$harness_conf_file" | tail -n 1; }
read -r -a harness_state <<< "$(harness_conf state)"
read -r -a harness_staged <<< "$(harness_conf staged)"
read -r -a harness_config <<< "$(harness_conf config)"
config_ro_paths=(${harness_config[@]+"${harness_config[@]}"} ${EXTRA_CONFIG_RO_PATHS[@]+"${EXTRA_CONFIG_RO_PATHS[@]}"})

# entrypoint.sh remaps dev's UID/GID (1000 in the image) to remap_uid/remap_gid, so files
# written to the bind mounts stay owned by the host user whatever their UID. Automatic
# unless CONTAINER_UID is set (a number, or "off"). Auto skips root (dev would become
# UID 0) and rootless Docker, where container UID 0 already is the host user and the
# host UID would land on an unrelated subordinate UID instead. Also Podman, which is
# typically rootless the same way but doesn't report it in Docker's SecurityOptions:
# `docker version` names "Podman Engine" both when `docker` is Podman's shim and when
# the Docker CLI talks to a Podman socket.
remap_uid=""
remap_gid=""
if [[ "$CONTAINER_UID" == off ]]; then
  remap_desc="off (CONTAINER_UID=off)"
elif [[ -n "$CONTAINER_UID" ]]; then
  remap_uid="$CONTAINER_UID"
  remap_gid="${CONTAINER_GID:-$(id -g)}"
  if ! [[ "$remap_uid" =~ ^[0-9]+$ && "$remap_gid" =~ ^[0-9]+$ ]] \
    || [[ "$remap_uid" -eq 0 || "$remap_gid" -eq 0 ]]; then
    echo "run.sh: CONTAINER_UID/CONTAINER_GID must be non-zero numbers, or CONTAINER_UID=off (got '$remap_uid'/'$remap_gid')" >&2
    exit 1
  fi
  remap_desc="$remap_uid:$remap_gid (set by CONTAINER_UID/CONTAINER_GID)"
elif [[ "$(id -u)" -eq 0 ]]; then
  remap_desc="off (running as root)"
elif docker info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless; then
  remap_desc="off (rootless Docker detected)"
elif docker version 2>/dev/null | grep -qi podman; then
  remap_desc="off (Podman detected)"
else
  remap_uid="$(id -u)"
  remap_gid="$(id -g)"
  remap_desc="$remap_uid:$remap_gid (your host user)"
fi

if [[ "$show_help" -eq 1 ]]; then
  cat <<EOF
Usage: run.sh [--harness <name>] [--host-network] [--allow-list <path> | --allow-internet]
              [--allow-container] [--allow-config] [--sysbox] [--mount <path|host:container[:ro]>]...
              [-h|--help] [harness-args... | command...]

Launches a fresh, disposable sandbox container scoped to \$PWD. Only \$PWD and the
harness's login/state are mounted in; the container is removed on exit (--rm).

  -h, --help        Show this help (reflects this machine's actual config below) and exit.
  --harness NAME    Which harness to run (harnesses/NAME/, image devcontainer:NAME).
                    Defaults to \$HARNESS, else claude. Available: $(cd "$script_dir/harnesses" && ls -d */ | tr -d / | tr '\n' ' ')
  --host-network    Share the host's network namespace instead of Docker's default
                    bridge network. Only needed if the host's network (e.g. a
                    corporate VPN) blocks the bridge network from reaching the
                    internet. Consumed here, never forwarded to docker/the harness.
  --allow-list PATH Replace the squid egress allowlist for this session only, with
                    PATH (one domain per line, same format as allowed-domains.txt).
                    Doesn't touch the image or other sessions. Consumed here, never
                    forwarded to docker/the harness.
  --allow-internet  Drop squid's domain allowlist for this session only - any host is
                    reachable, still only over plain HTTP (80) or CONNECT to 443,
                    still proxied and logged. Mutually exclusive with --allow-list.
                    Consumed here, never forwarded to docker/the harness.
  --mount SPEC      Add one extra bind mount for this session only. A bare PATH mounts
                    read-write at that same path on both sides; use host:container[:ro]
                    to mount elsewhere or read-only. Repeatable. On top of run.local.sh's
                    EXTRA_MOUNTS, not a replacement for it. Consumed here, never
                    forwarded to docker/the harness.
  --allow-container Bind-mount the HOST's own Docker socket in, instead of the sandbox's
                    nested dockerd. Containers started this way run on the host daemon as
                    siblings, not nested inside the sandbox - host-visible, not cleaned up
                    when this container exits. OFF by default: this is root-equivalent
                    access to the host. Consumed here, never forwarded to docker/the harness.
  --allow-config    Let this session change the harness's config on the host (its
                    harness.conf \`config\` and \`staged\` entries, e.g. settings/hooks/
                    plugins under ~/.claude and ~/.claude.json). OFF by default: those
                    are read-only, and in-session edits to staged files are discarded on
                    exit. Session state (transcripts, history, login) stays writable
                    either way. Consumed
                    here, never forwarded to docker/the harness.
  --sysbox          Use the sysbox-runc OCI runtime instead of --privileged, for real
                    user-namespace isolation around the nested dockerd. Must already be
                    installed and registered with this host's Docker daemon - see
                    https://github.com/nestybox/sysbox. Consumed here, never forwarded
                    to docker/the harness.

Anything else starting with '-' is forwarded to the harness itself (e.g. --continue).
A bare command (e.g. \`run.sh bash\`) overrides the harness's default command
($(harness_conf command)) entirely. Full details: README.md.

Effective config on this machine:
  Harness:        $harness$([[ -n "$cli_harness" ]] && echo " (--harness passed)")
  Image:          $image
  Network:        $([[ "$host_network" -eq 1 ]] && echo "host (--host-network passed)" || echo "bridge (default; pass --host-network to change)")
  Runtime:        $([[ "$sysbox" -eq 1 ]] && echo "sysbox-runc (--sysbox passed; no --privileged)" || echo "--privileged (default; pass --sysbox to use sysbox-runc instead, if installed)")
  Allowlist:      $([[ "$allow_internet" -eq 1 ]] && echo "DISABLED (--allow-internet passed - any host reachable via the proxy)" || { [[ -n "$allow_list" ]] && echo "$allow_list (--allow-list passed, overrides image default)" || echo "image default (allowed-domains.txt baked in at build; pass --allow-list to override)"; })
  Docker socket:  $([[ "$allow_container" -eq 1 ]] && echo "HOST /var/run/docker.sock (--allow-container passed - root-equivalent host access)" || echo "sandboxed nested dockerd only (default; pass --allow-container to use the host daemon)")
  Harness config: $([[ "$allow_config" -eq 1 ]] && echo "WRITABLE (--allow-config passed - edits persist on the host)" || echo "read-only (default; pass --allow-config to let the harness change it)")
  dev UID:GID:    $remap_desc
  Mounts:
    $PWD -> $PWD
EOF
  for entry in ${harness_state[@]+"${harness_state[@]}"}; do
    echo "    $HOME/$entry -> $HOME/$entry (dev's \$HOME is set to match, see README.md)"
  done
  if [[ "$allow_config" -eq 1 ]]; then
    for entry in ${config_ro_paths[@]+"${config_ro_paths[@]}"}; do
      if [[ -e "$HOME/$entry" ]]; then
        echo "    $HOME/$entry -> $HOME/$entry"
      fi
    done
    for entry in ${harness_staged[@]+"${harness_staged[@]}"}; do
      echo "    $HOME/$entry -> $HOME/$entry"
    done
  else
    for entry in ${config_ro_paths[@]+"${config_ro_paths[@]}"}; do
      if [[ -e "$HOME/$entry" ]]; then
        echo "    $HOME/$entry -> $HOME/$entry (ro)"
      fi
    done
    for entry in ${harness_staged[@]+"${harness_staged[@]}"}; do
      echo "    $HOME/$entry -> copied in from a ro mount (edits discarded on exit)"
    done
  fi
  if [[ -n "${SSH_AUTH_SOCK:-}" && -S "${SSH_AUTH_SOCK}" ]]; then
    echo "    $SSH_AUTH_SOCK -> $SSH_AUTH_SOCK (SSH_AUTH_SOCK, agent forwarding)"
  else
    echo "    (no SSH_AUTH_SOCK on host - no agent forwarding)"
  fi
  if [[ ${#EXTRA_MOUNTS[@]} -gt 0 ]]; then
    for mount in "${EXTRA_MOUNTS[@]}"; do
      echo "    $mount (from config/run.local.sh)"
    done
  else
    echo "    (no config/run.local.sh - no extra mounts)"
  fi
  if [[ ${#cli_mounts[@]} -gt 0 ]]; then
    for mount in "${cli_mounts[@]}"; do
      echo "    $mount (from --mount)"
    done
  fi
  exit 0
fi

if ! docker image inspect "$image" >/dev/null 2>&1; then
  echo "run.sh: image $image not found - run $script_dir/build.sh $harness first" >&2
  exit 1
fi

# First run without the harness installed on the host: docker would create a missing
# mount source as an empty root-owned *directory* (fatal for a file like
# ~/.claude.json), so create the harness's state dirs and staged files up front.
for entry in ${harness_state[@]+"${harness_state[@]}"}; do
  mkdir -p "$HOME/$entry"
done
for entry in ${harness_staged[@]+"${harness_staged[@]}"}; do
  if [[ -d "$HOME/$entry" ]]; then
    echo "run.sh: $HOME/$entry is a directory (left over from a failed earlier mount?) - remove it and retry" >&2
    exit 1
  fi
  if [[ ! -e "$HOME/$entry" ]]; then
    mkdir -p "$(dirname "$HOME/$entry")"
    if [[ "$entry" == *.json ]]; then echo '{}' > "$HOME/$entry"; else : > "$HOME/$entry"; fi
  fi
done

# The harness's state (e.g. ~/.claude, ~/.claude.json) is mounted at the SAME absolute
# path inside the container as on the host (not /home/dev/...) - same reasoning as $PWD
# above, but it matters more here: e.g. Claude Code's plugin/marketplace metadata
# records absolute "installLocation" paths computed from $HOME at the time a marketplace
# was registered. If the container's $HOME (dev's, /home/dev) didn't match the host's,
# anything registered while running the harness natively on the host would mismatch
# inside the container - surfacing in Claude Code's case as a "cache-miss" error on
# whatever it registered last. HOST_HOME carries the host's $HOME into the container so
# entrypoint.sh can point dev's own $HOME at the same path (see entrypoint.sh).
docker_args=(
  --rm -it
  -v "$PWD:$PWD"
  -w "$PWD"
  -e "HOST_HOME=$HOME"
)
for entry in ${harness_state[@]+"${harness_state[@]}"}; do
  docker_args+=(-v "$HOME/$entry:$HOME/$entry")
done

# See the remap_uid block near the top.
if [[ -n "$remap_uid" ]]; then
  docker_args+=(-e "HOST_UID=$remap_uid" -e "HOST_GID=$remap_gid")
fi

# Config is read-only unless --allow-config - see the header comment. The per-entry ro
# mounts nest inside the rw state mounts above (docker mounts parents first). Staged
# files can't just be :ro since the harness rewrites them on every start, so they're
# mounted read-only under /etc/devcontainer/staged/ and entrypoint.sh copies them into
# the container's writable layer. With --allow-config the config entries are still
# mounted, just read-write: one outside every state dir (opencode's ~/.config/opencode)
# would otherwise not be in the container at all.
if [[ "$allow_config" -eq 1 ]]; then
  for entry in ${config_ro_paths[@]+"${config_ro_paths[@]}"}; do
    if [[ -e "$HOME/$entry" ]]; then
      docker_args+=(-v "$HOME/$entry:$HOME/$entry")
    fi
  done
  for entry in ${harness_staged[@]+"${harness_staged[@]}"}; do
    docker_args+=(-v "$HOME/$entry:$HOME/$entry")
  done
else
  for entry in ${config_ro_paths[@]+"${config_ro_paths[@]}"}; do
    if [[ -e "$HOME/$entry" ]]; then
      docker_args+=(-v "$HOME/$entry:$HOME/$entry:ro")
    fi
  done
  for entry in ${harness_staged[@]+"${harness_staged[@]}"}; do
    docker_args+=(-v "$HOME/$entry:/etc/devcontainer/staged/$entry:ro")
  done
fi

# --privileged is the default, needed for the inner dockerd (Docker-in-Docker). --sysbox
# swaps it for the sysbox-runc runtime instead, which gives that same nested dockerd real
# user-namespace isolation rather than near-root host access - see the header comment.
if [[ "$sysbox" -eq 1 ]]; then
  docker_args+=(--runtime=sysbox-runc)
else
  docker_args+=(--privileged)
fi

if [[ "$host_network" -eq 1 ]]; then
  docker_args+=(--network host)
fi

# entrypoint.sh overwrites the image's baked-in allowed-domains.txt with this file
# (if mounted) before starting squid - see entrypoint.sh.
if [[ -n "$allow_list" ]]; then
  docker_args+=(-v "$allow_list:/etc/squid/allowed-domains.override.txt:ro")
fi

# entrypoint.sh patches squid.conf to drop the domain allowlist check when this is set -
# see entrypoint.sh.
if [[ "$allow_internet" -eq 1 ]]; then
  docker_args+=(-e "SQUID_ALLOW_INTERNET=1")
fi

# entrypoint.sh skips starting its own nested dockerd when this is set, since the host
# socket is mounted at the same path and would conflict with it - see entrypoint.sh.
# Root-equivalent access to the host: off by default, opt-in per session only.
if [[ "$allow_container" -eq 1 ]]; then
  docker_args+=(-v /var/run/docker.sock:/var/run/docker.sock -e "ALLOW_CONTAINER=1")
fi

# Forwards the host's ssh-agent for outbound git SSH auth (no private keys copied in).
# No-op if SSH_AUTH_SOCK isn't set - git-over-SSH just won't have agent-forwarded keys.
if [[ -n "${SSH_AUTH_SOCK:-}" && -S "${SSH_AUTH_SOCK}" ]]; then
  docker_args+=(-v "$SSH_AUTH_SOCK:$SSH_AUTH_SOCK" -e "SSH_AUTH_SOCK=$SSH_AUTH_SOCK")
fi

if [[ ${#EXTRA_MOUNTS[@]} -gt 0 ]]; then
  for mount in "${EXTRA_MOUNTS[@]}"; do
    docker_args+=(-v "$mount")
  done
fi

# --mount, one or more times - session-scoped extra mounts on top of run.local.sh's
# EXTRA_MOUNTS, without needing to edit that (personal, per-machine) file.
if [[ ${#cli_mounts[@]} -gt 0 ]]; then
  for mount in "${cli_mounts[@]}"; do
    docker_args+=(-v "$mount")
  done
fi

exec docker run "${docker_args[@]}" "$image" "$@"
