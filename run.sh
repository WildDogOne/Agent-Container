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
# agentcontainer:<name> image to start (build it with `build.sh <name>`). Defaults to
# $HARNESS (environment or config/run.local.sh), else claude.
#
# Runs on Docker's default bridge network unless `--host-network` is passed (consumed
# here, not forwarded on). Only needed when the host's own network setup - e.g. a
# corporate VPN - blocks the bridge network from reaching DNS/the internet; see
# README.md. `--host-network` shares the host's network namespace outright, so treat it
# as an opt-in trade of isolation for connectivity, not a default - it also skips the
# nftables egress firewall entrypoint.sh normally installs. Run `run.sh --help`
# for a summary of flags and this machine's resolved config (mounts, network mode).
#
# `--allow-list <path>` (consumed here, not forwarded on) swaps the egress allowlist
# for that one session: the given file is bind-mounted read-only and entrypoint.sh
# overwrites the image's baked-in allowed-hosts.txt with it before the proxy starts.
# Only affects this disposable container - the image itself, and every other
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
# `--ca-cert <path>` (consumed here, not forwarded on; repeatable) bind-mounts an extra
# root CA certificate file read-only into this session and entrypoint.sh imports it into
# the container's trust store at start, so an internal host signed by a private root CA
# (e.g. a corporate CA) is trusted. Who checks the chain depends on the mode: by default
# HTTPS is only tunneled, so each in-container client verifies the origin itself (with
# the system store, NODE_EXTRA_CA_CERTS, SSL_CERT_FILE, ...); under --inspect mitmproxy
# terminates TLS and verifies the origin on the way upstream, against the same store. Nothing is baked into the image and only
# this container's store changes - the host's trust store is never touched. run.local.sh's
# CA_CERTS array lists personal defaults; --ca-cert adds to them per session.
#
# `--allow-internet` (consumed here, not forwarded on) drops the proxy's domain and port
# allowlists for this one session: the mitmproxy addon skips its host/port checks, so any
# host (bare IPs included) on any port is reachable.
# Traffic is still proxied and logged, just no longer filtered. Only affects this
# disposable container - the image, allowed-domains.txt, and every other session are
# untouched. ALLOW_INTERNET=1 in run.local.sh makes it the default on this machine.
# Mutually exclusive with --allow-list (one drops the list, the other swaps
# it - combining them is almost certainly not what you meant).
#
# `--proxy-logs` / `--no-proxy-logs` (consumed here, not forwarded on) save this
# session's proxy logs (mitmdump's own log + the addon's JSONL flow log) to the host
# instead of letting them die with the container: a per-session directory under
# ~/.local/state/agentcontainer/logs/<timestamp>-<harness>/ (override the base with
# --proxy-logs=<path> or PROXY_LOG_DIR in run.local.sh) is bind-mounted at
# /var/log/agentcontainer and entrypoint.sh mirrors the logs into it as dev, so the
# files are owned by the host user. mitmdump and the addon keep writing to /tmp: their
# logs are owned by root and agentproxy there, which would land foreign-owned files on
# the host.
# PROXY_LOGS=1 in run.local.sh makes it the default; --no-proxy-logs overrides that for
# one session.
#
# `--inspect` (consumed here, not forwarded on) turns on TLS interception for this
# session: mitmproxy decrypts HTTPS with a throwaway CA generated inside the container and
# trusted only inside the container, and the flow log then records full request/response
# detail including message bodies (known secret shapes are redacted in the logged copy).
# By default HTTPS is tunneled undecrypted, so this is opt-in deliberately: interception
# adds a failure mode to every HTTPS call and breaks TLS-pinning services. INSPECT=1 in
# run.local.sh makes it the default.
#
# `--allow-container` (consumed here, not forwarded on) bind-mounts the HOST's own Docker
# socket (/var/run/docker.sock) into the container, instead of the nested dockerd
# `--with-docker` would otherwise start inside it. Containers started this way are
# siblings on the host's real Docker daemon, not nested inside the sandbox - they see the
# host's other containers/images/networks and are not cleaned up when this container
# exits. Off by default: a container's root-equivalent access to the host's Docker socket
# is effectively root on the host (bind-mount any host path in, run as any UID). Only pass
# this for a workflow that specifically needs the host daemon (e.g. driving host
# `docker compose` services) and that you trust to run inside this sandbox. Mutually
# exclusive with --with-docker/--sysbox (one wants the host daemon, the other a nested
# one - combining them is almost certainly not what you meant).
#
# `--with-docker` (consumed here, not forwarded on; WITH_DOCKER=1 in run.local.sh makes
# it the default) starts a nested Docker daemon (dockerd) inside the container, so the
# session can build/run its own containers (testcontainers, compose dev stacks, ...).
# That needs heavy privileges, so it's opt-in: without the flag there is no dockerd and
# no --privileged at all, and the `docker` CLI in the container is inert (no socket).
# With it, run.sh picks the sysbox-runc runtime when that's registered with the host's
# Docker daemon (real user-namespace isolation around the nested daemon), and falls back
# to --privileged otherwise.
#
# `--sysbox` (consumed here, not forwarded on) implies --with-docker and forces the
# sysbox-runc OCI runtime (https://github.com/nestybox/sysbox) instead of --privileged;
# sysbox must already be installed and registered with the host's Docker daemon - this
# script only selects it, it doesn't install it. Sysbox gives the nested dockerd real
# user-namespace isolation instead of `--privileged`'s "may as well be root on the host"
# access, at the cost of a host-side dependency beyond plain Docker. Where sysbox isn't
# installed, --with-docker alone still works via the --privileged fallback.
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
#
# `--bash-sandbox` / `--no-bash-sandbox` (consumed here, not forwarded on) control
# whether the harness's `sandboxed_command` (if it has one) is started instead of its
# `command` - ON by default. For Claude Code, `sandboxed_command` is its own Bash sandbox
# (bubblewrap) on top of this container: real network isolation for shell commands
# instead of the proxy's env-var-only filtering, and no read access to the login token.
# A harness without a `sandboxed_command` just runs its plain `command` (no error);
# explicitly passing `--bash-sandbox` for such a harness is refused. `BASH_SANDBOX=0` in
# the environment/run.local.sh turns it off permanently. See README.md.
#
# `--env-file <path>` (consumed here, not forwarded on; ENV_FILE in run.local.sh sets a
# default) passes the variables in a docker env file into the session, e.g. tokens that
# MCP servers reference as ${VAR}, so they don't have to sit in plaintext in
# ~/.claude.json. Without either, ~/.config/agentcontainer.env is used if it exists;
# `--no-env-file` (or ENV_FILE=off) skips it. Names the sandbox itself relies on (proxy
# settings, HOME, HOST_*, the flags above) are refused, so an env file can't quietly
# switch them off. So are LD_*, GCONV_PATH and OPENSSL_*: docker hands the env file to
# entrypoint.sh's root phase too, where the dynamic loader honours them (no setuid, so no
# secure-execution mode) - LD_LIBRARY_PATH into the project would load agent-planted code as root.
# Likewise OPENSSL_CONF/OPENSSL_MODULES for the openssl/update-ca-certificates calls the
# root phase makes for --ca-cert and --inspect (a config can load an engine/provider .so).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cli_harness=""
host_network=0
show_help=0
allow_list=""
allow_internet=0
allow_container=0
allow_config=0
with_docker=0
sysbox=0
cli_bash_sandbox=0
cli_no_bash_sandbox=0
cli_env_file=""
no_env_file=0
cli_proxy_logs=""   # "" = not passed, "1" = --proxy-logs, "0" = --no-proxy-logs
cli_proxy_log_dir=""
cli_inspect=""      # "" = not passed, "1" = --inspect
cli_mounts=()
cli_ca_certs=()  # --ca-cert host paths (CA files to import into the container trust store)
cli_labels=()    # --label key=value docker labels (e.g. for an orchestrator to find its sessions)
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    # Deprecated squid-era names (the proxy is mitmproxy now): still accepted, with a
    # warning, so an old alias or muscle memory doesn't get forwarded to the harness as
    # an unknown option.
    --squid-logs|--squid-logs=*|--no-squid-logs)
      echo "run.sh: warning: $1 is deprecated, use ${1/squid-logs/proxy-logs}" >&2
      set -- "${1/squid-logs/proxy-logs}" "${@:2}"
      continue
      ;;
    --host-network) host_network=1; shift ;;
    --bash-sandbox) cli_bash_sandbox=1; shift ;;
    --no-bash-sandbox) cli_no_bash_sandbox=1; shift ;;
    --env-file)
      if [[ $# -lt 2 ]]; then
        echo "run.sh: --env-file requires a path argument" >&2
        exit 1
      fi
      cli_env_file="$2"
      shift 2
      ;;
    --no-env-file) no_env_file=1; shift ;;
    --proxy-logs) cli_proxy_logs=1; shift ;;
    --proxy-logs=*)
      cli_proxy_logs=1
      cli_proxy_log_dir="${1#*=}"
      if [[ -z "$cli_proxy_log_dir" ]]; then
        echo "run.sh: --proxy-logs= requires a path (or use plain --proxy-logs for the default)" >&2
        exit 1
      fi
      shift
      ;;
    --no-proxy-logs) cli_proxy_logs=0; shift ;;
    --inspect) cli_inspect=1; shift ;;
    -h|--help) show_help=1; shift ;;
    --allow-internet) allow_internet=1; shift ;;
    --allow-container) allow_container=1; shift ;;
    --allow-config) allow_config=1; shift ;;
    --with-docker) with_docker=1; shift ;;
    --sysbox) sysbox=1; with_docker=1; shift ;;
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
    --label)
      # Docker label on the session container - metadata only (no effect on the
      # sandbox), so an orchestrator like Agent-Fleet can find its sessions with
      # `docker ps --filter label=...`. key=value, key in docker's charset.
      if [[ $# -lt 2 || ! "$2" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*=.*$ ]]; then
        echo "run.sh: --label requires a key=value argument" >&2
        exit 1
      fi
      cli_labels+=("$2")
      shift 2
      ;;
    --)
      # End of run.sh's own flags: everything after it goes to the harness verbatim
      # (kept with its `--`, which entrypoint.sh strips), even args that look like
      # run.sh flags or don't start with `-` - e.g. a positional prompt that would
      # otherwise replace the harness command. Lets a caller (Agent-Fleet's launcher)
      # forward untrusted harness args without them ever being read as sandbox flags.
      args+=("$@")
      break
      ;;
    --ca-cert)
      if [[ $# -lt 2 ]]; then
        echo "run.sh: --ca-cert requires a host path to a CA certificate file" >&2
        exit 1
      fi
      cli_ca_certs+=("$2")
      shift 2
      ;;
    *) args+=("$1"); shift ;;
  esac
done
# ${args[@]+...} guard: macOS's bash 3.2 treats an empty array as unbound under set -u.
set -- ${args[@]+"${args[@]}"}

if [[ -n "$allow_list" ]]; then
  if [[ ! -f "$allow_list" ]]; then
    echo "run.sh: --allow-list file not found: $allow_list" >&2
    exit 1
  fi
  allow_list="$(cd "$(dirname "$allow_list")" && pwd)/$(basename "$allow_list")"
fi

if [[ "$allow_container" -eq 1 && ( "$with_docker" -eq 1 || "$sysbox" -eq 1 ) ]]; then
  echo "run.sh: --allow-container and --with-docker/--sysbox are mutually exclusive" >&2
  echo "(one mounts the host's Docker daemon, the other runs a nested one)" >&2
  exit 1
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
# Additional root CA cert files (host paths) to import into the container's trust store
# at session start - see --ca-cert. run.local.sh can list personal defaults (e.g. a
# corporate root CA) here permanently; --ca-cert adds to them per session.
CA_CERTS=()
# Seeded from the environment so a one-off `HARNESS=x run.sh` / `CONTAINER_UID=1234
# run.sh` works; run.local.sh can set them permanently.
HARNESS="${HARNESS:-claude}"
CONTAINER_UID="${CONTAINER_UID:-}"
CONTAINER_GID="${CONTAINER_GID:-}"
ENV_FILE="${ENV_FILE:-}"
# Not seeded from the environment: settings that loosen the sandbox or change what is
# logged (nested Docker = --privileged, Bash sandbox off, TLS interception, log
# mirroring, allow-internet) count only when run.local.sh or a flag asks for them. These names are
# generic enough that an unrelated `export WITH_DOCKER=1` / `INSPECT=1` in the user's
# shell would otherwise apply to every session. Unset (not just emptied), since
# run.local.sh is sourced into this shell and would otherwise see the exported value as
# already set.
unset WITH_DOCKER BASH_SANDBOX PROXY_LOGS PROXY_LOG_DIR INSPECT SQUID_LOGS SQUID_LOG_DIR ALLOW_INTERNET
WITH_DOCKER=""
BASH_SANDBOX=""
PROXY_LOGS=""
PROXY_LOG_DIR=""
INSPECT=""
ALLOW_INTERNET=""
if [[ -f "$script_dir/config/run.local.sh" ]]; then
  . "$script_dir/config/run.local.sh"
fi
# Deprecated squid-era settings (run.local.sh only, like the new names): honoured when the new
# name isn't set, with a warning - otherwise an old run.local.sh would silently stop
# saving logs.
if [[ -n "${SQUID_LOGS:-}" ]]; then
  echo "run.sh: warning: SQUID_LOGS is deprecated, rename it to PROXY_LOGS (config/run.local.sh)" >&2
  [[ -z "$PROXY_LOGS" ]] && PROXY_LOGS="$SQUID_LOGS"
fi
if [[ -n "${SQUID_LOG_DIR:-}" ]]; then
  echo "run.sh: warning: SQUID_LOG_DIR is deprecated, rename it to PROXY_LOG_DIR (config/run.local.sh)" >&2
  [[ -z "$PROXY_LOG_DIR" ]] && PROXY_LOG_DIR="$SQUID_LOG_DIR"
fi

harness="${cli_harness:-$HARNESS}"
with_docker_src="--with-docker passed"
if [[ "$with_docker" -eq 0 && "$WITH_DOCKER" == 1 ]]; then
  with_docker=1
  with_docker_src="WITH_DOCKER=1 in run.local.sh"
fi
allow_internet_src="--allow-internet passed"
if [[ "$allow_internet" -eq 0 && "$ALLOW_INTERNET" == 1 ]]; then
  allow_internet=1
  allow_internet_src="ALLOW_INTERNET=1 in run.local.sh"
fi
if [[ -n "$allow_list" && "$allow_internet" -eq 1 ]]; then
  echo "run.sh: --allow-list and --allow-internet (or ALLOW_INTERNET=1 in run.local.sh) are mutually exclusive" >&2
  exit 1
fi
if [[ "$allow_container" -eq 1 && "$with_docker" -eq 1 ]]; then
  echo "run.sh: --allow-container and --with-docker/--sysbox (or WITH_DOCKER=1 in run.local.sh) are mutually exclusive" >&2
  exit 1
fi
harness_conf_file="$script_dir/harnesses/$harness/harness.conf"
if [[ ! -f "$harness_conf_file" ]]; then
  echo "run.sh: unknown harness '$harness' (no $harness_conf_file)" >&2
  exit 1
fi
image="agentcontainer:$harness"

# Additional root CA certs to import: run.local.sh's CA_CERTS plus any --ca-cert.
# Existence is validated at mount time below - a missing host path would otherwise make
# Docker create a directory at the bind target instead of binding the CA file.
all_ca_certs=(${CA_CERTS[@]+"${CA_CERTS[@]}"} ${cli_ca_certs[@]+"${cli_ca_certs[@]}"})

# TLS interception: --inspect overrides INSPECT=1 in run.local.sh. Off by
# default - see the header comment for why.
inspect=0
if [[ "$cli_inspect" == 1 || "$INSPECT" == 1 ]]; then
  inspect=1
fi
# Proxy logs to the host: --proxy-logs / --no-proxy-logs override PROXY_LOGS=1 in
# run.local.sh (see the header comment). The per-session directory name carries a
# timestamp and the harness so sessions are greppable/ sortable afterwards; a second
# session started in the same second gets the PID appended. The directory is only
# created on the real (non---help) path below.
proxy_logs=0
proxy_log_dir=""
if [[ "$cli_proxy_logs" == 0 ]]; then
  proxy_logs_desc="off (--no-proxy-logs passed)"
elif [[ "$cli_proxy_logs" == 1 ]]; then
  proxy_logs=1
elif [[ "$PROXY_LOGS" == 1 ]]; then
  proxy_logs=1
  proxy_logs_desc="on (PROXY_LOGS=1)"
fi
if [[ "$proxy_logs" -eq 1 ]]; then
  proxy_log_base="${cli_proxy_log_dir:-$PROXY_LOG_DIR}"
  # expand a leading ~ typed as --proxy-logs=~/... (bash doesn't in that position)
  proxy_log_base="${proxy_log_base/#~/$HOME}"
  [[ -z "$proxy_log_base" ]] && proxy_log_base="$HOME/.local/state/agentcontainer/logs"
  proxy_log_dir="$proxy_log_base/$(date +%Y-%m-%d-%H%M%S)-$harness"
  [[ -e "$proxy_log_dir" ]] && proxy_log_dir="$proxy_log_dir-$$"
fi

# See harnesses/README.md for the keys. Space-separated lists; last line wins.
harness_conf() { sed -n "s/^$1=//p" "$harness_conf_file" | tail -n 1; }
read -r -a harness_state <<< "$(harness_conf state)"
read -r -a harness_staged <<< "$(harness_conf staged)"
read -r -a harness_config <<< "$(harness_conf config)"
read -r -a harness_tmpfs <<< "$(harness_conf tmpfs)"
config_ro_paths=(${harness_config[@]+"${harness_config[@]}"} ${EXTRA_CONFIG_RO_PATHS[@]+"${EXTRA_CONFIG_RO_PATHS[@]}"})

# The Bash sandbox is ON by default for harnesses that define a sandboxed_command;
# --no-bash-sandbox or BASH_SANDBOX=0 turns it off. --bash-sandbox forces it on and is
# refused for a harness without one. entrypoint.sh refuses too, but checking here gives
# the error before docker starts anything.
bash_sandbox=0
bash_sandbox_desc=""
if [[ "$cli_no_bash_sandbox" -eq 1 || "$BASH_SANDBOX" == 0 ]]; then
  bash_sandbox_desc="off ($([[ "$cli_no_bash_sandbox" -eq 1 ]] && echo "--no-bash-sandbox passed" || echo "BASH_SANDBOX=0"))"
elif [[ "$cli_bash_sandbox" -eq 1 ]]; then
  if [[ -z "$(harness_conf sandboxed_command)" ]]; then
    echo "run.sh: --bash-sandbox: harness '$harness' has no sandboxed_command in its harness.conf" >&2
    exit 1
  fi
  bash_sandbox=1
  bash_sandbox_desc="ON (--bash-sandbox passed): $(harness_conf sandboxed_command)"
elif [[ -z "$(harness_conf sandboxed_command)" ]]; then
  bash_sandbox_desc="n/a (harness '$harness' has no sandboxed_command; plain command)"
else
  bash_sandbox=1
  bash_sandbox_desc="ON (default; --no-bash-sandbox to disable): $(harness_conf sandboxed_command)"
fi

# --env-file, else ENV_FILE from the environment/run.local.sh, else the default path if
# that file exists (a missing default is skipped quietly - not everyone has secrets).
# --no-env-file / ENV_FILE=off turn the default off too. Docker parses the file itself; the names are only collected here so entrypoint.sh can keep them through
# the drop to dev (which starts from an empty environment), and checked against the variables this sandbox relies on: an env file setting
# e.g. AGENTCONTAINER_ALLOW_INTERNET=1 or HTTPS_PROXY= would otherwise quietly undo the egress
# allowlist. Docker env file format: KEY=value, or a bare KEY to copy it from this
# shell's environment; # starts a comment line.
if [[ "$no_env_file" -eq 1 && -n "$cli_env_file" ]]; then
  echo "run.sh: --env-file and --no-env-file are mutually exclusive" >&2
  exit 1
fi
default_env_file="$HOME/.config/agentcontainer.env"
env_file=""
if [[ "$no_env_file" -eq 1 ]]; then
  env_file_desc="none (--no-env-file passed)"
elif [[ -n "$cli_env_file" ]]; then
  env_file="$cli_env_file"
  env_file_desc="--env-file passed"
elif [[ "$ENV_FILE" == off ]]; then
  env_file_desc="none (ENV_FILE=off)"
elif [[ -n "$ENV_FILE" ]]; then
  env_file="$ENV_FILE"
  env_file_desc="ENV_FILE"
elif [[ -f "$default_env_file" ]]; then
  env_file="$default_env_file"
  env_file_desc="default"
else
  env_file_desc="none ($default_env_file doesn't exist; pass --env-file or set ENV_FILE to use another file)"
fi
env_keys=""
if [[ -n "$env_file" ]]; then
  if [[ ! -f "$env_file" ]]; then
    echo "run.sh: env file not found: $env_file" >&2
    exit 1
  fi
  env_file="$(cd "$(dirname "$env_file")" && pwd)/$(basename "$env_file")"
  # Warnings only: the file is the user's to place. ls instead of stat, whose flags
  # differ between GNU and BSD/macOS; characters 5-10 are the group/other bits.
  env_file_mode="$(ls -ld "$env_file")"
  if [[ "${env_file_mode:4:6}" != "------" ]]; then
    echo "run.sh: warning: $env_file is accessible by other users - chmod 600 it" >&2
  fi
  if [[ "$env_file" == "$PWD"/* ]]; then
    echo "run.sh: warning: $env_file is inside $PWD, which is mounted into the session - the harness can read and edit it" >&2
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    key="${line%%=*}"
    if ! [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      echo "run.sh: $env_file: invalid variable name '$key'" >&2
      exit 1
    fi
    case "$key" in
      HOME|PATH|USER|SHELL|SUDO_*|HOST_*|AGENTCONTAINER_*|LD_*|GCONV_PATH|OPENSSL_*|INSPECT|PROXY_LOGS|PROXY_LOG_DIR|ALLOW_CONTAINER|WITH_DOCKER|[Hh][Tt][Tt][Pp]_[Pp][Rr][Oo][Xx][Yy]|[Hh][Tt][Tt][Pp][Ss]_[Pp][Rr][Oo][Xx][Yy]|[Nn][Oo]_[Pp][Rr][Oo][Xx][Yy]|[Aa][Ll][Ll]_[Pp][Rr][Oo][Xx][Yy])
        echo "run.sh: $env_file: '$key' is reserved by the sandbox and can't be set from an env file" >&2
        exit 1
        ;;
    esac
    env_keys="${env_keys:+$env_keys,}$key"
  done < "$env_file"
fi

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
              [--allow-container | --with-docker [--sysbox]] [--allow-config]
              [--mount <path|host:container[:ro]>]... [--ca-cert <path>]...
              [--no-bash-sandbox] [--env-file <path> | --no-env-file]
              [--proxy-logs[=<path>] | --no-proxy-logs] [--inspect]
              [--label <key=value>]...
              [-h|--help] [harness-args... | command... | -- harness-args...]

Launches a fresh, disposable sandbox container scoped to \$PWD. Only \$PWD and the
harness's login/state are mounted in; the container is removed on exit (--rm).

  -h, --help        Show this help (reflects this machine's actual config below) and exit.
  --harness NAME    Which harness to run (harnesses/NAME/, image agentcontainer:NAME).
                    Defaults to \$HARNESS, else claude. Available: $(cd "$script_dir/harnesses" && ls -d */ | tr -d / | tr '\n' ' ')
  --host-network    Share the host's network namespace instead of Docker's default
                    bridge network. Only needed if the host's network (e.g. a
                    corporate VPN) blocks the bridge network from reaching the
                    internet: it also gives the container unrestricted access to
                    every host service on 127.0.0.1 and skips the nftables egress
                    firewall (it would alter the host's ruleset). Consumed here,
                    never forwarded to docker/the harness.
  --allow-list PATH Replace the egress allowlist for this session only, with
                    PATH (one domain per line, same format as allowed-domains.txt).
                    Doesn't touch the image or other sessions. Consumed here, never
                    forwarded to docker/the harness.
  --allow-internet  Full internet for this session only: drops the proxy's domain and port
                    allowlists AND the nftables egress firewall - any host (bare IPs
                    too) on any port, proxied or direct. ALLOW_INTERNET=1 in run.local.sh
                    = default on this machine. Mutually exclusive with --allow-list.
                    Consumed here, never forwarded to docker/the harness.
  --mount SPEC      Add one extra bind mount for this session only. A bare PATH mounts
                    read-write at that same path on both sides; use host:container[:ro]
                    to mount elsewhere or read-only. Repeatable. On top of run.local.sh's
                     EXTRA_MOUNTS, not a replacement for it. Consumed here, never
                     forwarded to docker/the harness.
  --ca-cert PATH    Import an extra root CA certificate (host file) into the container's
                    trust store for this session only - e.g. a corporate root CA, so an
                    internal host signed by it is trusted instead of failing with a
                    certificate error (by the in-container clients by default, by
                    mitmproxy's upstream check under --inspect). PEM or DER. Read-only mount; only
                    this container's store is touched, never the host's. Repeatable. Adds to
                    run.local.sh's CA_CERTS. Consumed here, never forwarded to docker/the
                    harness. **no rebuild** (runtime).
  --allow-container Bind-mount the HOST's own Docker socket in, instead of a nested
                    dockerd. Containers started this way run on the host daemon as
                    siblings, not nested inside the sandbox - host-visible, not cleaned up
                    when this container exits. OFF by default: this is root-equivalent
                    access to the host. Mutually exclusive with --with-docker/--sysbox.
                    Consumed here, never forwarded to docker/the harness.
  --with-docker     Start a nested Docker daemon (dockerd) inside the container, so the
                    session can build/run its own containers. Needs heavy privileges, so
                    it's opt-in: without it there is no dockerd and no --privileged, and
                    the docker CLI in the container is inert (no socket). Uses the
                    sysbox-runc runtime if this host has it registered, --privileged
                    otherwise. WITH_DOCKER=1 in run.local.sh makes it the default.
                    Consumed here, never forwarded to docker/the harness.
  --allow-config    Let this session change the harness's config on the host (its
                    harness.conf \`config\` and \`staged\` entries, e.g. settings/hooks/
                    plugins under ~/.claude and ~/.claude.json). OFF by default: those
                    are read-only, and in-session edits to staged files are discarded on
                    exit. Session state (transcripts, history, login) stays writable
                    either way. Consumed
                    here, never forwarded to docker/the harness.
  --sysbox          Implies --with-docker and forces the sysbox-runc OCI runtime instead
                    of --privileged, for real user-namespace isolation around the nested
                    dockerd. Must already be installed and registered with this host's
                    Docker daemon - see https://github.com/nestybox/sysbox. Consumed
                    here, never forwarded to docker/the harness.
  --no-bash-sandbox Don't start the harness's sandboxed_command even if it has one - use
                    its plain command instead. The sandbox (ON by default where the
                    harness defines one; for Claude Code: its own Bash sandbox,
                    bubblewrap, on top of the container - shell commands get no direct
                    network access and can't read the login token) is turned off
                    permanently by BASH_SANDBOX=0 in run.local.sh.
  --bash-sandbox    Force the sandboxed_command on and refuse if the harness has none.
                    Redundant by default; kept as the explicit opt-in. Consumed here,
                    never forwarded to docker/the harness.
  --env-file PATH   Pass the variables in PATH (docker env file: KEY=value per line) into
                    the session, e.g. tokens MCP servers reference as \${VAR}. Overrides
                    ENV_FILE from run.local.sh, which overrides the default
                    ~/.config/agentcontainer.env (used if it exists). Variables the
                    sandbox relies on (proxy settings, HOME, HOST_*, LD_*, ...) are refused.
                    Consumed here, never forwarded to docker/the harness.
  --no-env-file     Pass no env file this session, not even the default (ENV_FILE=off
                    in run.local.sh does the same permanently). Consumed here, never
                    forwarded to docker/the harness.
  --proxy-logs      Save this session's proxy logs (mitmdump's own log + the addon's JSONL
                    flow log) to the host, in
                    ~/.local/state/agentcontainer/logs/<timestamp>-<harness>/
                    (--proxy-logs=<path> or PROXY_LOG_DIR in run.local.sh changes the
                    base dir). entrypoint.sh mirrors them out of the container; the
                    files end up owned by you. PROXY_LOGS=1 in run.local.sh makes it
                    the default. Consumed here, never forwarded to docker/the harness.
  --no-proxy-logs   Don't save the proxy logs this session, even with PROXY_LOGS=1 set
                    (they stay in the container's /tmp and die with it). Consumed here,
                    never forwarded to docker/the harness.
  --inspect         TLS interception for this session: mitmproxy decrypts HTTPS with a
                    throwaway CA trusted only inside the container, so the flow log records
                    full request/response detail including message bodies (known secret
                    shapes redacted in the logged copy). Adds a failure mode to every HTTPS
                    call and breaks TLS pinning - opt-in; HTTPS is tunneled undecrypted by
                    default. INSPECT=1 in run.local.sh makes it the default. Consumed here,
                    never forwarded to docker/the harness.
  --label K=V       Put a docker label on the session container (metadata only, no effect
                    on the sandbox) - lets an orchestrator such as Agent-Fleet find its
                    sessions. Repeatable. Consumed here, never forwarded to the harness.

Anything else starting with '-' is forwarded to the harness itself (e.g. --continue).
A bare command (e.g. \`run.sh bash\`) overrides the harness's default command
($(harness_conf command)) entirely. \`--\` ends run.sh's own flags: everything after it
goes to the harness verbatim, positional args included (\`run.sh -- "fix the bug"\`).
In a git worktree (.git is a file) the main repo's git dir is mounted read-write
automatically, so git works inside the container. Full details: README.md.

Effective config on this machine:
  Harness:        $harness$([[ -n "$cli_harness" ]] && echo " (--harness passed)")
  Image:          $image
  Network:        $([[ "$host_network" -eq 1 ]] && echo "host (--host-network passed)" || echo "bridge (default; pass --host-network to change)")
  Runtime:        $([[ "$allow_container" -eq 1 ]] && echo "plain runc, unprivileged (host socket mounted; no nested dockerd to privilege)" || { [[ "$with_docker" -eq 1 ]] && { [[ "$sysbox" -eq 1 ]] && echo "sysbox-runc (--sysbox passed)" || { docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q sysbox-runc && echo "sysbox-runc (auto: registered on this host)" || echo "--privileged (--with-docker; install sysbox-runc for user-namespace isolation instead)"; }; } || echo "plain runc, unprivileged (default; pass --with-docker for a nested dockerd)"; })
  Allowlist:      $([[ "$allow_internet" -eq 1 ]] && echo "DISABLED ($allow_internet_src - any host/port reachable, nftables egress firewall also off)" || { [[ -n "$allow_list" ]] && echo "$allow_list (--allow-list passed, overrides image default)" || echo "image default (allowed-domains.txt baked in at build; pass --allow-list to override)"; })
  Docker socket:  $([[ "$allow_container" -eq 1 ]] && echo "HOST /var/run/docker.sock (--allow-container passed - root-equivalent host access)" || { [[ "$with_docker" -eq 1 ]] && echo "nested dockerd in the container ($with_docker_src)" || echo "none (default; pass --with-docker for a nested dockerd, --allow-container for the host daemon)"; })
  Harness config: $([[ "$allow_config" -eq 1 ]] && echo "WRITABLE (--allow-config passed - edits persist on the host)" || echo "read-only (default; pass --allow-config to let the harness change it)")
  dev UID:GID:    $remap_desc
  Bash sandbox:   $bash_sandbox_desc
  Env file:       $([[ -n "$env_file" ]] && echo "$env_file ($env_file_desc: ${env_keys:-no variables})" || echo "$env_file_desc")
  Proxy logs:     $([[ "$proxy_logs" -eq 1 ]] && echo "$proxy_log_dir (mirrored to the host)" || echo "${proxy_logs_desc:-container-only (/tmp, discarded on exit; --proxy-logs or PROXY_LOGS=1 to save them)}")
  TLS inspect:    $( [[ "$inspect" -eq 1 ]] && echo "ON (--inspect: HTTPS decrypted, bodies logged - expect breakage)" || echo "off (HTTPS tunneled undecrypted; --inspect to intercept)")
  Mounts:
    $PWD -> $PWD
EOF
  for entry in ${harness_state[@]+"${harness_state[@]}"}; do
    echo "    $HOME/$entry -> $HOME/$entry (dev's \$HOME is set to match, see README.md)"
  done
  for entry in ${harness_tmpfs[@]+"${harness_tmpfs[@]}"}; do
    echo "    $HOME/$entry -> tmpfs (container-local, writable, discarded on exit)"
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
  echo "    (no git-over-SSH: agent forwarding is gone by design - use HTTPS remotes / gh auth inside)"
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
  if [[ ${#all_ca_certs[@]} -gt 0 ]]; then
    echo "  Extra root CAs:  ${#all_ca_certs[@]} to import (run.local.sh CA_CERTS + --ca-cert):"
    for cert in "${all_ca_certs[@]}"; do
      echo "    $cert"
    done
  else
    echo "  Extra root CAs:  none (pass --ca-cert or set CA_CERTS in run.local.sh to trust a private root)"
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
# --init: docker-init is PID 1 (forwards signals, reaps orphans). entrypoint.sh drops to
# dev by exec'ing straight into the harness, so without it the harness itself would be
# PID 1 - an un-handled SIGTERM to PID 1 is ignored, and orphans would pile up as zombies.
docker_args=(
  --rm -it --init
  -v "$PWD:$PWD"
  -w "$PWD"
  -e "HOST_HOME=$HOME"
)

# Git worktree: $PWD/.git is a file pointing into <main-repo>/.git/worktrees/<name>, outside
# $PWD, so git inside the container would find no repository. Mount the common git dir
# (objects, refs, the worktree's own metadata) read-write at its own path. Read-write is
# required - commits write objects and refs there - so the session can also change the
# main checkout's refs and anything else in its .git (hooks/config included, the same
# exposure a plain repo's $PWD/.git already has).
# Both pointers git follows here ($PWD/.git and <gitdir>/commondir) are writable by an
# earlier session, so neither is trusted on its own: the mount happens only when git's own
# back-link agrees - <common>/worktrees/<name>/gitdir must point at this $PWD/.git. A
# session can't forge that for a directory it has no write access to, so it can't
# redirect the next session's mount to $HOME or another repo's git dir.
if [[ -f "$PWD/.git" ]] && command -v git >/dev/null 2>&1; then
  wt_git_dir="$(git -C "$PWD" rev-parse --absolute-git-dir 2>/dev/null || true)"
  git_common_dir="$(git -C "$PWD" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [[ -n "$wt_git_dir" && -n "$git_common_dir" ]]; then
    wt_git_dir="$(realpath -e "$wt_git_dir" 2>/dev/null || true)"
    git_common_dir="$(realpath -e "$git_common_dir" 2>/dev/null || true)"
    back_link="$(realpath -m "$(cat "$wt_git_dir/gitdir" 2>/dev/null || true)" 2>/dev/null || true)"
    if [[ -n "$wt_git_dir" && -n "$git_common_dir" \
          && "$(dirname "$wt_git_dir")" == "$git_common_dir/worktrees" \
          && "$back_link" == "$(realpath -e "$PWD/.git")" \
          && -f "$git_common_dir/HEAD" && -d "$git_common_dir/objects" && -d "$git_common_dir/refs" \
          && "$git_common_dir" != "$PWD"/* \
          && "$HOME/" != "$git_common_dir"/* ]]; then
      docker_args+=(-v "$git_common_dir:$git_common_dir")
    else
      echo "run.sh: warning: $PWD is a git worktree, but its git dir links don't check out - not mounting the main repo's git dir (git won't work in the container)" >&2
    fi
  fi
fi

for label in ${cli_labels[@]+"${cli_labels[@]}"}; do
  docker_args+=(--label "$label")
done
for entry in ${harness_state[@]+"${harness_state[@]}"}; do
  docker_args+=(-v "$HOME/$entry:$HOME/$entry")
done

# harness.conf `tmpfs`: $HOME-relative paths that must be writable in the session but
# must never reach the host (e.g. Claude Code's shell snapshots, which it sources in
# every later Bash session, host runs included). The tmpfs covers the path inside the
# state mount: writes land in the container's memory and die with it (--rm). Docker
# creates the mount-point directory inside the state mount, so an empty dir shows up
# on the host - harmless for these paths (the harness creates them itself anyway).
# entrypoint.sh chowns the mounts to dev.
for entry in ${harness_tmpfs[@]+"${harness_tmpfs[@]}"}; do
  docker_args+=(--tmpfs "$HOME/$entry")
done

# See the remap_uid block near the top.
if [[ -n "$remap_uid" ]]; then
  docker_args+=(-e "HOST_UID=$remap_uid" -e "HOST_GID=$remap_gid")
fi

# Config is read-only unless --allow-config - see the header comment. The per-entry ro
# mounts nest inside the rw state mounts above (docker mounts parents first). Staged
# files can't just be :ro since the harness rewrites them on every start, so they're
# mounted read-only under /etc/agentcontainer/staged/ and entrypoint.sh copies them into
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
    docker_args+=(-v "$HOME/$entry:/etc/agentcontainer/staged/$entry:ro")
  done
fi

# Docker-in-Docker is opt-in (--with-docker / --sysbox): by default there is no nested
# dockerd and no --privileged at all. When requested, prefer the sysbox-runc runtime
# (real user-namespace isolation around the nested dockerd) if it's registered with this
# host's Docker daemon, and fall back to --privileged otherwise - see the header comment.
# --allow-container needs no privilege of its own: it just mounts the host socket, and
# entrypoint.sh skips starting a nested dockerd when it's set (same socket path).
if [[ "$allow_container" -eq 1 ]]; then
  docker_args+=(-v /var/run/docker.sock:/var/run/docker.sock -e "ALLOW_CONTAINER=1")
elif [[ "$with_docker" -eq 1 ]]; then
  docker_args+=(-e "WITH_DOCKER=1")
  if [[ "$sysbox" -eq 1 ]] || docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q sysbox-runc; then
    docker_args+=(--runtime=sysbox-runc)
  else
    docker_args+=(--privileged)
  fi
fi

# The Bash sandbox (harness.conf `sandboxed_command`, e.g. Claude Code's bubblewrap)
# creates user/pid/net namespaces and mounts a fresh /proc for every command. A plain
# unprivileged container blocks both: Docker's default seccomp profile only allows
# unshare/clone-with-namespaces/mount to CAP_SYS_ADMIN, and the kernel refuses a fresh
# procfs while Docker's masked /proc paths (/proc/kcore, /proc/sys, ...) are overmounted.
# So for those sessions: Docker's own default profile plus those syscalls
# (lib/seccomp-userns.json; the kernel still demands the capabilities *inside* the new
# user namespace, as on any host with unprivileged userns), and systempaths=unconfined.
# The latter lifts the /proc masks for the whole container, and many /proc/sys knobs
# (e.g. kernel/core_pattern, which runs a host command on a crash) need only uid 0 plus
# write access - no capability. Without userns-remap container root is host root, so
# root code in such a container is a host escape. Mitigation: no root process outlives
# the entrypoint's root phase (it execs setpriv to dev; mitmdump runs as agentproxy,
# docker-init as PID 1 only reaps), and dev has no sudo/setuid path back to root.
# Not needed (and not added) under --privileged or sysbox, which allow both already.
if [[ "$bash_sandbox" -eq 1 && "$with_docker" -eq 0 ]]; then
  docker_args+=(--security-opt "seccomp=$script_dir/lib/seccomp-userns.json"
                --security-opt systempaths=unconfined)
fi

if [[ "$host_network" -eq 1 ]]; then
  echo "run.sh: WARNING: --host-network shares the HOST's network namespace: the" >&2
  echo "run.sh: container reaches every host service on 127.0.0.1, the nftables egress" >&2
  echo "run.sh: firewall is NOT installed (it would alter the host's ruleset), and" >&2
  echo "run.sh: NET_ADMIN is not added. Only for VPNs that block the bridge network." >&2
  docker_args+=(--network host -e "AGENTCONTAINER_HOST_NETWORK=1")
else
  # The nftables egress firewall in entrypoint.sh needs NET_ADMIN. It's scoped to the
  # container's own network namespace (never the host's), and only root PID 1 holds it -
  # dev has no sudo to pick it up.
  docker_args+=(--cap-add NET_ADMIN)
fi

# entrypoint.sh overwrites the image's baked-in allowed-hosts.txt with this file
# (if mounted) before starting the proxy - see entrypoint.sh.
if [[ -n "$allow_list" ]]; then
  docker_args+=(-v "$allow_list:/etc/agentcontainer/allowed-hosts.override.txt:ro")
fi

# the mitmproxy addon skips its domain/port checks when this is set - see entrypoint.sh.
if [[ "$allow_internet" -eq 1 ]]; then
  docker_args+=(-e "AGENTCONTAINER_ALLOW_INTERNET=1")
fi
if [[ "$inspect" -eq 1 ]]; then
  docker_args+=(-e "INSPECT=1")
fi

# entrypoint.sh mirrors the proxy's /tmp logs into this read-write per-session mount (see
# the header comment). Created here, not at resolution time, so --help doesn't leave an
# empty directory behind.
if [[ "$proxy_logs" -eq 1 ]]; then
  if ! mkdir -p "$proxy_log_dir" 2>/dev/null; then
    echo "run.sh: can't create the proxy log dir $proxy_log_dir - if a parent of it is root-owned (an older docker run creating a missing mount source as root), repair with: sudo chown -R \"\$USER\": \"$proxy_log_base\"" >&2
    exit 1
  fi
  docker_args+=(-v "$proxy_log_dir:/var/log/agentcontainer")
  # Also mount the base itself rw at the same path, so a run.sh started from *inside*
  # a sandbox can create its own session dir there: without it the default base's
  # parents in the container are just Docker's root-owned mount scaffolding, not the
  # host's real log tree.
  docker_args+=(-v "$proxy_log_base:$proxy_log_base")
fi

# entrypoint.sh starts the harness's sandboxed_command instead of its command (or the
# other way round with =0) - see the bash sandbox block near the top. Only needs to be
# explicit where the harness actually has a sandboxed_command to switch on/off.
if [[ "$bash_sandbox" -eq 1 ]]; then
  docker_args+=(-e "AGENTCONTAINER_BASH_SANDBOX=1")
elif [[ -n "$(harness_conf sandboxed_command)" ]]; then
  docker_args+=(-e "AGENTCONTAINER_BASH_SANDBOX=0")
fi

# Docker reads the env file itself; entrypoint.sh needs the names to keep them through
# sudo, and claude-sandboxed hides them from sandboxed shell commands. An env file with
# only comments sets nothing, so there's nothing to keep either.
if [[ -n "$env_file" ]]; then
  docker_args+=(--env-file "$env_file")
  if [[ -n "$env_keys" ]]; then
    docker_args+=(-e "AGENTCONTAINER_ENV_KEYS=$env_keys")
  fi
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

# The container-side paths of the read-write ones among them (no "ro" in the options
# field), ':'-separated - docker -v specs can't contain ':' in a path anyway. A harness
# Bash sandbox (claude-sandboxed) only allows writes in $PWD by default and adds these,
# so a mount the user gave read-write is writable from sandboxed commands too.
rw_mounts=""
for mount in ${EXTRA_MOUNTS[@]+"${EXTRA_MOUNTS[@]}"} ${cli_mounts[@]+"${cli_mounts[@]}"}; do
  IFS=: read -r m_src m_dst m_opts <<< "$mount"
  [[ -z "$m_dst" ]] && m_dst="$m_src"
  [[ ",$m_opts," == *,ro,* || "$m_dst" != /* ]] && continue
  rw_mounts="${rw_mounts:+$rw_mounts:}$m_dst"
done
if [[ -n "$rw_mounts" ]]; then
  docker_args+=(-e "AGENTCONTAINER_RW_MOUNTS=$rw_mounts")
fi

# --ca-cert / CA_CERTS: bind each CA file read-only under /etc/agentcontainer/ca-certs/;
# entrypoint.sh imports them into the container's trust store at start. Validate they're
# existing files first - Docker would otherwise mkdir the missing path at the target.
# Made absolute first (like --allow-list): docker -v treats a source without a `/` as a
# named volume, so `--ca-cert corp.crt` would mount an empty volume and import nothing.
# The target name is prefixed with an index so two files with the same basename (from
# different directories) don't collide on one mount point.
if [[ ${#all_ca_certs[@]} -gt 0 ]]; then
  ca_index=0
  for cert in "${all_ca_certs[@]}"; do
    if [[ ! -f "$cert" ]]; then
      echo "run.sh: --ca-cert file not found: $cert" >&2
      exit 1
    fi
    cert="$(cd "$(dirname "$cert")" && pwd)/$(basename "$cert")"
    ca_index=$((ca_index + 1))
    docker_args+=(-v "$cert:/etc/agentcontainer/ca-certs/$ca_index-$(basename "$cert"):ro")
  done
fi

exec docker run "${docker_args[@]}" "$image" "$@"
