#!/bin/sh
# Installs Claude Code into the image. Runs as root at build time, after Node/Python/
# uv/bun are on PATH (see image/Dockerfile).
set -eu

npm install -g @anthropic-ai/claude-code

# bubblewrap + socat: what Claude Code's Bash sandbox runs on, on Linux. Used by
# claude-sandboxed (harness.conf `sandboxed_command`, the claude default; opt out with
# run.sh --no-bash-sandbox).
apt-get update
apt-get install -y --no-install-recommends bubblewrap socat
rm -rf /var/lib/apt/lists/*
install -m 0755 "$(dirname "$0")/claude-sandboxed" /usr/local/bin/claude-sandboxed
# Ahead of /usr/bin/bwrap on PATH; a pass-through unless claude-sandboxed runs in its
# sysbox mode - see the file.
install -m 0755 "$(dirname "$0")/bwrap-sysbox-shim" /usr/local/bin/bwrap
