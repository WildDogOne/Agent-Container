#!/bin/sh
# Container entrypoint. Runs as root (needed to start dockerd/mitmdump below), then drops
# to dev and execs the command docker run was given (default: the harness's own
# `command` from harness.conf, e.g. an interactive `claude` session) - no persistent
# daemon, no listening port; the container exits when that command does. Meant to be started fresh per session via run.sh, not left running.
set -eu

# Egress allowlist proxy first, so dockerd's own image pulls go through it too. Exported
# here for this script's own process tree (dockerd) and passed on to the dev session by
# the preserve_env list at the end. Both
# casings matter: curl, git, wget, and Go's net/http (dockerd's own client) deliberately
# only honor lowercase http_proxy for plain http:// requests - the standard httpoxy-CVE
# mitigation - so uppercase-only silently bypassed the proxy for anything not using
# https. HTTPS_PROXY itself is read case-insensitively by all of the above, so that half
# was already fine.
export HTTP_PROXY=http://127.0.0.1:3128
export HTTPS_PROXY=http://127.0.0.1:3128
export NO_PROXY=localhost,127.0.0.1
export http_proxy=$HTTP_PROXY
export https_proxy=$HTTPS_PROXY
export no_proxy=$NO_PROXY

# run.sh --allow-list bind-mounts a replacement allowlist file here, read-only, only
# when that flag is passed. Overwriting the image's baked-in allowed-hosts.txt (rather
# than repointing the addon at the mount) keeps everything else static and this
# session-scoped: the container's writable layer is discarded with it (--rm), so the
# image's own default is untouched for every other session.
# tr strips CRLF line endings (a list written on Windows, passed via run.ps1).
# The addon (image/inspect-proxy.py) parses this file directly - including the optional
# trailing `:port` suffixes (a listed port opens for every allowed host; 80/443 always
# open) and bare IPv4/IPv6/CIDR entries - so no splitting is needed here.
if [ -f /etc/agentcontainer/allowed-hosts.override.txt ]; then
  echo "entrypoint.sh: using --allow-list override for the egress allowlist" >&2
  tr -d '\r' < /etc/agentcontainer/allowed-hosts.override.txt > /etc/agentcontainer/allowed-hosts.txt
fi

# run.sh --allow-internet sets AGENTCONTAINER_ALLOW_INTERNET=1 to drop both the domain
# allowlist and the port restrictions for this session - any host (bare IPs too) on any
# port, e.g. a Kubernetes API server on :6443. Still proxied and logged. The port checks
# exist to stop a proxy being abused for e.g. SMTP, which doesn't apply to a proxy bound
# to loopback inside a disposable container. The addon reads this env var and skips its
# domain/port checks; the nftables egress firewall is also skipped (see below).
if [ "${AGENTCONTAINER_ALLOW_INTERNET:-0}" = "1" ]; then
  echo "entrypoint.sh: --allow-internet passed, disabling the domain and port allowlists for this session" >&2
fi

# run.sh passes the invoking host user's UID/GID - remap dev (1000:1000 in the image) to
# them so files written to the bind mounts ($PWD, the harness's state, --mount) stay
# owned by that user on the host. Has to happen before anything below chowns to dev. -o: the host IDs
# may already be taken inside the image (e.g. GID 100 "users", macOS's GID 20) - a
# shared numeric ID is harmless here, failing to start isn't. usermod also re-chowns
# /home/dev (the only dev-owned path in the image), but only its UID - hence the
# explicit chown for the GID. UID 0 is refused outright (run.sh never sends it): dev
# would silently become root.
if [ -n "${HOST_UID:-}" ] && [ -n "${HOST_GID:-}" ] && [ "$HOST_UID" != 0 ]; then
  if [ "$HOST_GID" != "$(id -g dev)" ]; then
    groupmod -o -g "$HOST_GID" dev
  fi
  if [ "$HOST_UID" != "$(id -u dev)" ]; then
    usermod -o -u "$HOST_UID" dev
  fi
  chown -R dev:dev /home/dev
fi

# harness.conf `owned`: image paths the harness needs dev to own (e.g. an install that
# refuses to run under a different UID). install.sh chowns them to 1000:1000 at build;
# only re-chown when the remap above moved dev off those IDs, since -R over a whole
# install isn't free.
for path in $(sed -n 's/^owned=//p' /etc/agentcontainer/harness.conf | tail -n 1); do
  if [ -e "$path" ] && [ "$(stat -c '%u:%g' "$path")" != "$(id -u dev):$(id -g dev)" ]; then
    chown -R dev:dev "$path"
  fi
done

# run.sh --ca-cert (or CA_CERTS in run.local.sh) bind-mounts additional root CA
# certificate files, read-only, at /etc/agentcontainer/ca-certs/. Import them into the
# container's trust store so chains signed by private/internal roots are trusted here -
# for mitmproxy's *upstream* validation (ssl_verify_upstream_trusted_ca=ca-certificates.crt)
# so an internal host whose cert is signed by, say, a corporate root CA doesn't fail with
# a cert error, and - under --inspect - so the in-container clients also trust the
# intercepted chain. Session-scoped and personal: deliberately not baked into the image.
# Only affects this container's store, not the host.
# Each file may be PEM (.crt/.pem, possibly a bundle) or DER (.cer/.der): normalised to PEM
# with openssl, since update-ca-certificates silently ignores anything that isn't a PEM
# file ending in .crt. A file openssl can't read is reported and skipped, not counted.
# run.sh/run.ps1 prefix the mount names with an index, so equal basenames don't collide.
ca_imported=0
if [ -d /etc/agentcontainer/ca-certs ]; then
  ca_dir=/usr/local/share/ca-certificates/agentcontainer-imported
  mkdir -p "$ca_dir"
  ca_count=0
  for f in /etc/agentcontainer/ca-certs/*; do
    [ -f "$f" ] || continue
    base="${f##*/}"; base="${base%.*}"
    if grep -q -- '-----BEGIN CERTIFICATE-----' "$f" 2>/dev/null; then
      # Validate the first cert; copy the file as-is so a bundle keeps all its certs.
      if openssl x509 -noout -in "$f" 2>/dev/null; then
        cp "$f" "$ca_dir/${base}.crt" && ca_count=$((ca_count + 1))
      else
        echo "entrypoint.sh: --ca-cert ${f##*/}: not a readable PEM certificate - skipped" >&2
      fi
    elif openssl x509 -inform DER -in "$f" -out "$ca_dir/${base}.crt" 2>/dev/null; then
      ca_count=$((ca_count + 1))
    else
      echo "entrypoint.sh: --ca-cert ${f##*/}: neither a PEM nor a DER certificate - skipped" >&2
    fi
  done
  [ "$ca_count" -gt 0 ] && ca_imported=1
fi
if [ "$ca_imported" = 1 ]; then
  if update-ca-certificates >/tmp/update-ca-certificates.log 2>&1; then
    echo "entrypoint.sh: imported $ca_count extra root CA cert file(s) into the container trust store" >&2
  else
    echo "entrypoint.sh: update-ca-certificates failed - extra root CAs may not be trusted:" >&2
    cat /tmp/update-ca-certificates.log >&2
  fi
  # curl/python/openssl read the system store by default; Node ships its own bundle, so
  # point it (and the others, for robustness) at the updated system store. Passed on to
  # dev below (see the preserve_env block).
  export NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt
  export CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
  export REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
  # Tools with their own compiled-in roots (uv/uvx use webpki roots, many Rust/Go
  # binaries likewise) only look at the system store through SSL_CERT_FILE.
  export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
fi

# /tmp/agentcontainer is the shared per-session scratch dir: the addon (running as
# agentproxy) writes flows.jsonl here, and harnesses running as dev after the drop below
# (e.g. claude-sandboxed generating its --settings file) drop their own per-session files
# here. Create it world-writable with the sticky bit up front, as root, so agentproxy and
# dev can both create files but dev cannot unlink or rename the agentproxy-owned flow log
# (sticky restricts deletion to the file's owner, the dir's owner, or root).
mkdir -p /tmp/agentcontainer
chmod 1777 /tmp/agentcontainer

# mitmdump (the egress proxy; addon in image/inspect-proxy.py), bound to loopback.
# Common options, then per-mode extras via the function's "$@" so this script's
# own command args ($@) aren't clobbered. confdir holds mitmdump's generated CA + state;
# ssl_verify_upstream_trusted_ca points its upstream validation at the system bundle
# (which the --ca-cert import above may have extended). The bundle file, not the hashed
# /etc/ssl/certs directory: `openssl rehash` skips files holding more than one cert, so
# a --ca-cert chain file (root + intermediate) would get no hash link there.
# Runs as the unprivileged `agentproxy` user (created in the Dockerfile), not root, and
# with a clean environment: this process inherits every --env-file variable, and a
# Python process honours PYTHONPATH/PYTHONSTARTUP/SSLKEYLOGFILE etc. - an env file with
# PYTHONPATH=$PWD/src would otherwise let the agent plant a module that root imports at
# the next session start. Only the addon's own (reserved, run.sh-set) AGENTCONTAINER_*
# settings are passed through. cwd is / rather than the dev-writable project dir.
# setpriv: no new privileges, no capabilities (the container's root caps, NET_ADMIN
# included, are dropped from the bounding set too). confdir is created up front, owned by
# agentproxy and mode 700 - the CA private key lives there under --inspect.
rm -rf /tmp/mitm
install -d -o agentproxy -g agentproxy -m 700 /tmp/mitm
# Default (tunnel) mode passes ignore_hosts=.*: HTTPS is tunneled, not decrypted, so no
# in-container client needs to trust mitmproxy's CA and TLS-pinning services keep working.
# The addon still enforces the allowlist on every CONNECT and plain request. --inspect
# (INSPECT=1) omits that: mitmproxy intercepts, and its generated CA is installed into the
# container's trust store below so the in-container clients trust it (the host's store is
# untouched - the CA never escapes the sandbox). Interception adds a failure mode to every
# HTTPS call and breaks TLS pinning, so it stays opt-in.
# The redirect target is opened by this (root) shell, so mitmdump.log stays root-owned.
# The subshell execs straight through nohup/setpriv/env into mitmdump, so $! is
# mitmdump's PID - the readiness check below tracks that rather than matching by uid
# (setpriv only switches to agentproxy a moment after launch, so a uid-filtered pgrep
# can miss a process that is still starting).
# flow_detail=0: mitmdump would otherwise print every request line with its full URL
# (query strings, path tokens) to mitmdump.log, bypassing the addon's redaction - that
# log is world-readable and mirrored to the host by --proxy-logs. Errors and the addon's
# own messages still go there.
# stream_large_bodies=4m: a backstop so no body over 4 MB is held in memory - the addon
# already streams non-text bodies, server-sent events and (in tunnel mode) everything;
# this catches big text bodies, including chunked ones. 4 MB matches redact_secrets.py's
# MAX_PARSE: smaller text bodies are buffered so the redactor can parse them whole.
start_mitmdump() {
  (cd / && exec nohup setpriv --reuid=agentproxy --regid=agentproxy --clear-groups \
    --no-new-privs --inh-caps=-all --bounding-set=-all \
    env -i PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 HOME=/tmp/mitm \
      ${AGENTCONTAINER_INSPECT:+"AGENTCONTAINER_INSPECT=$AGENTCONTAINER_INSPECT"} \
      ${AGENTCONTAINER_ALLOW_INTERNET:+"AGENTCONTAINER_ALLOW_INTERNET=$AGENTCONTAINER_ALLOW_INTERNET"} \
      ${AGENTCONTAINER_ALLOWLIST:+"AGENTCONTAINER_ALLOWLIST=$AGENTCONTAINER_ALLOWLIST"} \
      ${AGENTCONTAINER_FLOWLOG:+"AGENTCONTAINER_FLOWLOG=$AGENTCONTAINER_FLOWLOG"} \
      ${AGENTCONTAINER_FLOWLOG_DISABLE:+"AGENTCONTAINER_FLOWLOG_DISABLE=$AGENTCONTAINER_FLOWLOG_DISABLE"} \
    mitmdump \
    --listen-host 127.0.0.1 --listen-port 3128 \
    --set confdir=/tmp/mitm \
    --set ssl_verify_upstream_trusted_ca=/etc/ssl/certs/ca-certificates.crt \
    --set flow_detail=0 \
    --set stream_large_bodies=4m \
    -s /usr/local/lib/agentcontainer/inspect-proxy.py \
    "$@") > /tmp/mitmdump.log 2>&1 &
  mitmdump_pid=$!
}
# Alive = the PID exists and isn't a zombie (this script is its parent and doesn't reap it).
mitmdump_alive() {
  st=$(sed -n 's/^State:[[:space:]]*\([A-Z]\).*/\1/p' "/proc/$mitmdump_pid/status" 2>/dev/null)
  [ -n "$st" ] && [ "$st" != Z ]
}
if [ "${INSPECT:-0}" = "1" ]; then
  echo "entrypoint.sh: --inspect: TLS interception ENABLED for this session" >&2
  # The addon (loaded by mitmdump below) reads AGENTCONTAINER_INSPECT to decide whether
  # to log full request/response bodies; INSPECT is the host-facing name run.sh sets.
  export AGENTCONTAINER_INSPECT=1
  start_mitmdump
else
  start_mitmdump --set 'ignore_hosts=.*'
fi
# Wait until mitmdump actually listens instead of sleeping a fixed time: Python 3.14 +
# mitmproxy + the addon take a few seconds on a cold container, and a harness started
# before :3128 is up fails its first API/auth/MCP calls. No ss/nc in the image, so read
# the kernel's socket table: 0100007F:0C38 = 127.0.0.1:3128, state 0A = LISTEN. If the
# process dies (addon error, broken wheel), fail the session with its log rather than
# starting with all egress silently broken.
proxy_up=0
i=0
while [ "$i" -lt 120 ]; do
  if grep -q '^ *[0-9]*: 0100007F:0C38 [0-9A-F]*:[0-9A-F]* 0A ' /proc/net/tcp; then
    # mitmdump binds before it acts on a startup error ("Error logged during startup,
    # exiting...") - confirm it is still alive a moment later.
    sleep 0.5
    mitmdump_alive && proxy_up=1
    break
  fi
  mitmdump_alive || break
  sleep 0.25
  i=$((i + 1))
done
if [ "$proxy_up" != 1 ]; then
  echo "entrypoint.sh: the egress proxy (mitmdump) did not come up on 127.0.0.1:3128 - refusing to start" >&2
  echo "entrypoint.sh: last lines of /tmp/mitmdump.log:" >&2
  tail -n 20 /tmp/mitmdump.log >&2 2>/dev/null || true
  exit 1
fi

# Under --inspect, every in-container client must trust mitmproxy's CA. mitmproxy
# generates it into confdir at startup; wait for it, then install it into the container's
# trust store only. Node ships its own bundle (unaffected by update-ca-certificates);
# curl/python get the system bundle explicitly for robustness. Passed on to dev below.
if [ "${INSPECT:-0}" = "1" ]; then
  i=0
  while [ ! -f /tmp/mitm/mitmproxy-ca-cert.pem ] && [ "$i" -lt 20 ]; do sleep 0.25; i=$((i + 1)); done
  if [ -f /tmp/mitm/mitmproxy-ca-cert.pem ]; then
    cp /tmp/mitm/mitmproxy-ca-cert.pem /usr/local/share/ca-certificates/agentcontainer-mitm.crt
    update-ca-certificates >/dev/null 2>&1
    export NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt
    export CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
    export REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
    export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
  else
    echo "entrypoint.sh: --inspect: mitmproxy CA not found after startup - intercepted TLS will not be trusted" >&2
  fi
fi

# dev has no sudo in this image (deliberate: no in-container privilege escalation path),
# and troubleshooting blocked egress means reading the proxy logs as dev - make them
# world-readable. mitmdump.log is root-owned (this shell opens the redirect), flows.jsonl
# belongs to agentproxy (the addon creates it) - neither is dev-readable by default.
chmod a+r /tmp/mitmdump.log /tmp/agentcontainer/flows.jsonl 2>/dev/null || true

# run.sh --proxy-logs (or PROXY_LOGS=1 in run.local.sh) bind-mounts a per-session host
# directory at /var/log/agentcontainer, read-write; the mount's presence is the switch
# (a plain `docker run` without it is unaffected). mitmdump and the addon keep logging to
# /tmp: their logs are owned by root (the mitmdump.log redirect) and agentproxy (the
# addon's flows.jsonl), so pointing them at the mount directly would leave files the
# host user doesn't own in their log dir. Mirror them out
# through a dev-owned tail instead - dev's UID is the host user's (remapped above), so
# the copies are host-owned from the first line. The >> redirection must happen inside
# the dev-side `sh -c`, not in this root shell, for the same reason. (setpriv rather than
# sudo, like the final drop below: no root process left waiting on the tail.) -F waits for the files to
# appear and follows them through rotation. mitmdump.log is the proxy's own log (request
# lines, the addon's allowlist summary, denials); flows.log is the addon's JSONL flow log
# (connect events always; full request/response bodies only under --inspect).
if [ -d /var/log/agentcontainer ]; then
  nohup setpriv --reuid=dev --regid=dev --init-groups env -i PATH=/usr/bin:/bin \
    sh -c "tail -F '/tmp/mitmdump.log' >> '/var/log/agentcontainer/mitmdump.log'" >/dev/null 2>&1 &
  nohup setpriv --reuid=dev --regid=dev --init-groups env -i PATH=/usr/bin:/bin \
    sh -c "tail -F '/tmp/agentcontainer/flows.jsonl' >> '/var/log/agentcontainer/flows.log'" >/dev/null 2>&1 &
fi

# run.sh --loopback-socket PORT:SOCKET: the host socket is mounted at
# /run/agentcontainer/loopback/PORT.sock; forward 127.0.0.1:PORT to it, as dev (whose UID
# is the host user's after the remap above, so a 0600 socket owned by that user works).
# Ports were range-checked by run.sh; checked again here since they reach a command line.
if [ -n "${AGENTCONTAINER_LOOPBACK_PORTS:-}" ]; then
  if ! printf '%s' "$AGENTCONTAINER_LOOPBACK_PORTS" | grep -Eq '^[0-9]{4,5}(,[0-9]{4,5})*$'; then
    echo "entrypoint.sh: invalid AGENTCONTAINER_LOOPBACK_PORTS: $AGENTCONTAINER_LOOPBACK_PORTS" >&2
    exit 1
  fi
  for port in $(printf '%s' "$AGENTCONTAINER_LOOPBACK_PORTS" | tr ',' ' '); do
    if [ -S "/run/agentcontainer/loopback/$port.sock" ]; then
      (cd / && exec nohup setpriv --reuid=dev --regid=dev --init-groups env -i PATH=/usr/bin:/bin \
        python3 /usr/local/lib/agentcontainer/loopback-forward.py "$port" "/run/agentcontainer/loopback/$port.sock" \
        >/dev/null 2>&1) &
    else
      echo "entrypoint.sh: warning: --loopback-socket $port: no socket mounted, skipping" >&2
    fi
  done
fi

# run.sh --allow-container bind-mounts the HOST's own docker.sock at this same path,
# so starting our own nested dockerd here would just fail to bind it. Instead, give dev
# access to the mounted socket by joining the group that owns it on the host - dev's own
# UID/GID has no relation to whatever GID owns the socket on an arbitrary host.
# The docker *client* (installed for the nested case) works unmodified against either
# socket; only the daemon side differs.
if [ "${ALLOW_CONTAINER:-0}" = "1" ]; then
  echo "entrypoint.sh: --allow-container passed, using the HOST's Docker socket instead of a nested dockerd" >&2
  sock_gid="$(stat -c '%g' /var/run/docker.sock)"
  sock_group="$(getent group "$sock_gid" | cut -d: -f1)"
  if [ -z "$sock_group" ]; then
    sock_group=hostdocker
    groupadd -g "$sock_gid" "$sock_group"
  fi
  usermod -aG "$sock_group" dev
  # Tells a harness Bash sandbox (claude-sandboxed) that the user deliberately handed
  # this session a Docker socket, so sandboxed commands may use it - see preserve_env.
  export AGENTCONTAINER_DOCKER=host
elif [ "${WITH_DOCKER:-0}" = "1" ]; then
  export AGENTCONTAINER_DOCKER=nested
  # run.sh --with-docker: nested Docker-in-Docker, explicitly requested (and run.sh
  # passed --privileged or selected the sysbox runtime for it). Without that flag there
  # is no daemon at all: the docker CLI in the container has no socket to talk to.
  nohup dockerd --host=unix:///var/run/docker.sock > /tmp/dockerd.log 2>&1 &
  sleep 1
fi

# Egress firewall (see README "Network"): the proxy alone is advisory - a tool that
# ignores the proxy env vars (curl --noproxy, raw sockets, resolve-then-connect)
# could still reach the network directly. These nftables rules make it enforced:
# only root (dockerd under --with-docker) and agentproxy (mitmdump and its own DNS
# resolution) may originate traffic directly; everyone else (dev and everything it spawns) is limited
# to loopback (the proxy, dev servers), the docker0/br-* bridges (port-published nested
# containers), and replies to allowed flows.
# Everything else is rejected - outbound :22 included: git-over-SSH is not
# supported in the sandbox, pushing is a host-side operation.
# Needs NET_ADMIN in the container (run.sh adds --cap-add NET_ADMIN; it is
# netns-scoped, and dev has no sudo to pick it up). Skipped with --host-network
# (the rules would land in the HOST's ruleset) and --allow-internet (unrestricted
# egress is that flag's point). Nested containers' own traffic goes through the
# forward path, not this output chain - DinD egress is the nested daemon's business,
# not covered by the allowlist.
if [ "${AGENTCONTAINER_HOST_NETWORK:-0}" = "1" ]; then
  echo "entrypoint.sh: --host-network: skipping the nftables egress firewall (it would modify the host's ruleset)" >&2
elif [ "${AGENTCONTAINER_ALLOW_INTERNET:-0}" = "1" ]; then
  echo "entrypoint.sh: --allow-internet: skipping the nftables egress firewall (unrestricted egress requested)" >&2
else
  # Root only needs direct egress for the nested dockerd (image pulls, its own DNS).
  # Otherwise all traffic leaves through agentproxy, so a root-context process (a
  # helper reached through some root-phase bug) gets no bypass either.
  root_egress_rule=""
  if [ "${WITH_DOCKER:-0}" = "1" ]; then
    root_egress_rule="    meta skuid 0 accept"
  fi
  if ! nft -f - <<EOF
table inet agentcfgr
delete table inet agentcfgr
table inet agentcfgr {
  chain output {
    type filter hook output priority filter; policy accept;
    oif lo accept
    oifname { "docker0", "br-*" } accept
    ct state established, related accept
$root_egress_rule
    meta skuid $(id -u agentproxy) accept
    reject
  }
}
EOF
  then
    echo "entrypoint.sh: failed to install the nftables egress firewall - refusing to start" >&2
    echo "entrypoint.sh: (kernel without nf_tables? --allow-internet starts without the firewall)" >&2
    exit 1
  fi
fi

# apt doesn't reliably pick up *_proxy env vars for Acquire (varies by version/method),
# and git's http transport can be configured to skip its own env lookup - pin both
# explicitly rather than relying on env alone. Written here (not baked into the image)
# since the proxy isn't running yet at `docker build` time.
cat <<EOF > /etc/apt/apt.conf.d/95proxy
Acquire::http::Proxy "http://127.0.0.1:3128";
Acquire::https::Proxy "http://127.0.0.1:3128";
EOF
git config --system http.proxy "http://127.0.0.1:3128"
git config --system https.proxy "http://127.0.0.1:3128"

# run.sh mounts the harness's state/config (e.g. ~/.claude) at the host's own $HOME
# path (see run.sh for why) and passes that path through as HOST_HOME. dev's own
# passwd-registered home stays /home/dev, but dev's *session* HOME needs to point at
# HOST_HOME instead so the harness's own $HOME-derived paths (e.g. Claude Code's
# recorded plugin "installLocation") match what was recorded when it last ran natively
# on the host. Falls back to /home/dev if run without run.sh (e.g. a bare `docker run`).
# HOST_HOME itself is mostly other bind mounts' auto-created parent scaffolding
# (Docker creates missing mount-point parents in the container's own writable layer,
# not on the host), owned by root by default - chown just the top level so dev can
# still write new dotfiles/caches directly under it; the mounts underneath already
# have host-matching ownership (dev is remapped to the host UID above) and don't need touching.
export HOME="${HOST_HOME:-/home/dev}"
mkdir -p "$HOME"
chown dev:dev "$HOME"
# The same goes for deeper scaffolding: a mount at e.g. ~/.local/state/agentcontainer/logs
# (--proxy-logs) or ~/.config/x leaves ~/.local, ~/.local/state, ~/.config root-owned, so
# dev can't create ~/.local/share (uvx's tool dir - uvx-launched MCP servers died with
# "Permission denied") or ~/.config/<tool>. Walk up from every mount under $HOME and chown
# each root-owned parent - but only where it lives in the container's own layer (its
# containing mount is /), never a host directory inside another bind mount.
findmnt -rn -o TARGET | while IFS= read -r target; do
  case "$target" in "$HOME"/*) ;; *) continue ;; esac
  dir=$(dirname "$target")
  while [ "$dir" != "$HOME" ] && [ "$dir" != / ]; do
    if [ -d "$dir" ] && [ "$(stat -c %u "$dir")" = 0 ] \
        && [ "$(findmnt -n -o TARGET --target "$dir")" = / ]; then
      chown dev:dev "$dir"
    fi
    dir=$(dirname "$dir")
  done
done

# harness.conf `tmpfs`: run.sh mounts these $HOME-relative paths as container-local
# tmpfs (writable in the session, never reaches the host - see run.sh). tmpfs mounts
# come up root-owned 0755, so dev couldn't write them; chown each mount to dev. Only
# where the mount actually exists - without run.sh (bare `docker run`) there are no
# tmpfs mounts and the paths may not exist at all.
for entry in $(sed -n 's/^tmpfs=//p' /etc/agentcontainer/harness.conf | tail -n 1); do
  if [ -d "$HOME/$entry" ]; then
    chown dev:dev "$HOME/$entry"
  fi
done

# run.sh (without --allow-config) mounts the harness's `staged` files (harness.conf)
# read-only under /etc/agentcontainer/staged/, at their path relative to $HOME, instead of
# at $HOME itself. The harness rewrites them on every start (e.g. ~/.claude.json), so a
# plain :ro mount would break it - copy them into the container's writable layer
# instead: the harness can change them freely, but nothing reaches the host and they're
# discarded with the container (--rm).
if [ -d /etc/agentcontainer/staged ]; then
  (cd /etc/agentcontainer/staged && find . -type f) | while IFS= read -r rel; do
    rel="${rel#./}"
    mkdir -p "$(dirname "$HOME/$rel")"
    cp "/etc/agentcontainer/staged/$rel" "$HOME/$rel"
    chown dev:dev "$HOME/$rel"
    chmod 600 "$HOME/$rel"
  done
fi

# Default command from the harness.conf baked into the image (see harnesses/README.md).
# Sandbox-friendly defaults belong there rather than in the harness's own config on the
# host - e.g. Claude Code's `--permission-mode auto`, which the sandbox (no host access
# beyond the mounts, read-only config, egress allowlist) is what makes acceptable, but
# which shouldn't apply to `claude` run natively. Forwarded args come after it, so e.g.
# `run.sh --permission-mode manual` still overrides it (last one wins).
harness_command="$(sed -n 's/^command=//p' /etc/agentcontainer/harness.conf | tail -n 1)"

# Bash sandbox: use the harness's `sandboxed_command` instead of `command` (for Claude
# Code: the same command with its own Bash sandbox on top). ON by default when the
# harness defines one; run.sh passes =0 explicitly (--no-bash-sandbox / BASH_SANDBOX=0)
# or =1 explicitly (--bash-sandbox). =1 with no sandboxed_command refuses to start
# rather than fall back - the user asked for the sandbox, so silently running without it
# would be the wrong failure; an unset value (bare `docker run`, no run.sh) just uses it
# if present. A full command override (`run.sh bash`) bypasses the harness command
# entirely, so the sandbox can't apply there; say so instead of pretending it did.
sandboxed_command="$(sed -n 's/^sandboxed_command=//p' /etc/agentcontainer/harness.conf | tail -n 1)"
if [ "${AGENTCONTAINER_BASH_SANDBOX:-}" = "1" ] || { [ -z "${AGENTCONTAINER_BASH_SANDBOX:-}" ] && [ -n "$sandboxed_command" ]; }; then
  if [ -z "$sandboxed_command" ]; then
    echo "entrypoint.sh: Bash sandbox requested, but this harness has no sandboxed_command in harness.conf" >&2
    exit 1
  fi
  harness_command="$sandboxed_command"
  if [ "$#" -gt 0 ] && [ "${1#-}" = "$1" ]; then
    echo "entrypoint.sh: the Bash sandbox only applies to the harness's own command, not to '$1'" >&2
  fi
fi

if [ "$#" -eq 0 ]; then
  set -- zsh -lc "exec $harness_command"
elif [ "$1" = "--" ]; then
  # `run.sh -- args...`: everything after `--` belongs to the harness, positional args
  # included (e.g. a prompt), so it is never taken as a command override.
  shift
  set -- zsh -lc "exec $harness_command \"\$@\"" zsh "$@"
elif [ "${1#-}" != "$1" ]; then
  # First arg is a flag (e.g. --continue, --resume) rather than a full command
  # override - forward it to the harness instead of trying to exec a flag as a program.
  # `zsh -lc 'script' zsh "$@"` forwards the remaining args as the script's own $@
  # (the usual positional-forwarding trick for `sh -c`).
  set -- zsh -lc "exec $harness_command \"\$@\"" zsh "$@"
fi

# Drop to dev with setpriv + `env -i`, not sudo: sudo stays behind as a root parent
# for the whole session (plus a second root process relaying its pseudo-terminal), and
# with run.sh's systempaths=unconfined (Bash sandbox sessions) /proc/sys is writable
# by any root process - a lingering root process is worth avoiding. After this exec
# nothing in the container runs as root except the nested dockerd under --with-docker.
# run.sh/run.ps1 pass `docker run --init`, so docker-init is PID 1 (forwards signals,
# reaps orphans) and the harness isn't - an un-handled SIGTERM to PID 1 is ignored.
# setpriv never chdir's, so the cwd docker run -w set (run.sh's project mount) passes
# through untouched (the reason this was sudo rather than `su -l` before). HOME is this
# script's own $HOME (the HOST_HOME alignment above), not dev's passwd /home/dev.
#
# The environment is rebuilt from scratch, as sudo's env_reset did: the basics sudo set
# (secure_path PATH, USER/LOGNAME/SHELL/MAIL, TERM, HOSTNAME, TZ, LANG from
# /etc/default/locale like pam_env), plus the names in preserve_env. run.sh --env-file:
# docker sets those variables on this process, and run.sh lists their names in
# AGENTCONTAINER_ENV_KEYS so they survive the reset (e.g. MCP server tokens referenced as
# ${VAR} in the harness's config). The names are checked again here rather than trusted:
# they are expanded with eval below.
preserve_env=HOME,HTTP_PROXY,HTTPS_PROXY,NO_PROXY,http_proxy,https_proxy,no_proxy,TERM,HOSTNAME,TZ
if [ -n "${AGENTCONTAINER_ENV_KEYS:-}" ]; then
  if ! printf '%s' "$AGENTCONTAINER_ENV_KEYS" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*(,[A-Za-z_][A-Za-z0-9_]*)*$'; then
    echo "entrypoint.sh: invalid AGENTCONTAINER_ENV_KEYS: $AGENTCONTAINER_ENV_KEYS" >&2
    exit 1
  fi
  preserve_env="$preserve_env,$AGENTCONTAINER_ENV_KEYS,AGENTCONTAINER_ENV_KEYS"
  # Which of them came from the env file (secrets): for a harness Bash sandbox to hide.
  # (Empty = no env file; grep alone would reject that, it sees no line to match.)
  if [ -z "${AGENTCONTAINER_SECRET_ENV_KEYS:-}" ] \
     || printf '%s' "$AGENTCONTAINER_SECRET_ENV_KEYS" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*(,[A-Za-z_][A-Za-z0-9_]*)*$'; then
    preserve_env="$preserve_env,AGENTCONTAINER_SECRET_ENV_KEYS"
  fi
fi
# What this session was deliberately given, for a harness Bash sandbox to honour: the
# read-write extra mounts (run.sh) and the Docker socket (set above). Both are reserved
# names, refused from an env file.
preserve_env="$preserve_env,AGENTCONTAINER_RW_MOUNTS,AGENTCONTAINER_DOCKER"
if [ "${INSPECT:-0}" = "1" ] || [ "$ca_imported" = "1" ]; then
  preserve_env="$preserve_env,NODE_EXTRA_CA_CERTS,CURL_CA_BUNDLE,REQUESTS_CA_BUNDLE,SSL_CERT_FILE"
fi
for name in $(printf '%s' "$preserve_env" | tr ',' ' '); do
  if eval "[ -n \"\${$name+set}\" ]"; then
    eval "value=\$$name"
    set -- "$name=$value" "$@"
  fi
done
locale_lang="$(sed -n 's/^LANG=//p' /etc/default/locale 2>/dev/null | tail -n 1)"
exec setpriv --reuid=dev --regid=dev --init-groups \
  env -i \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin \
    USER=dev LOGNAME=dev MAIL=/var/mail/dev \
    SHELL="$(getent passwd dev | cut -d: -f7)" \
    ${locale_lang:+"LANG=$locale_lang"} \
    "$@"
