#!/bin/sh
# Optional, per-machine extra dependencies baked into the image at build time - system
# packages, global npm/uv/pip installs, or a custom MCP server's own runtime
# requirements that aren't part of this repo's base image.
#
# Copy this file to extra-setup.sh (gitignored - never committed, like
# allowed-domains.txt, since what one machine needs here is personal/project-specific)
# and uncomment/add whatever you need. build.sh seeds an empty no-op copy from this
# .example automatically if extra-setup.sh doesn't exist yet, so a fresh clone still
# builds with nothing extra installed.
#
# Runs as root, late in the build (after Node/Python/uv/bun are already set up - see
# Dockerfile), inside the same --network host build context as the rest of the
# Dockerfile, so normal internet access works here even before squid's egress
# allowlist exists. If the tool itself needs network access at *runtime* (not just to
# install), add its domain(s) to allowed-domains.txt too - this script only covers the
# build.
#
# Keep it idempotent-ish and non-interactive (DEBIAN_FRONTEND=noninteractive is already
# set); a failing command here fails the whole build.
set -eu

# Extra apt packages:
# apt-get update && apt-get install -y --no-install-recommends \
#     ffmpeg \
#     postgresql-client \
#     && rm -rf /var/lib/apt/lists/*

# A global npm package (e.g. an MCP server distributed as a CLI):
# npm install -g some-mcp-server-package

# A uv-installed Python tool (uv itself is already on PATH, see Dockerfile):
# uv tool install some-python-mcp-server

# Anything else - curl-installed binaries, etc. - follows the same pattern as the
# uv/bun installs in Dockerfile: install straight into /usr/local/bin rather than a
# home directory, since entrypoint.sh's `sudo -u dev` doesn't preserve PATH.

## MS XDR MCP
# uv tool install's defaults are both under $HOME - during the build that's /root, so
# the shim (UV_TOOL_BIN_DIR) AND the actual venv (UV_TOOL_DIR) both need to move.
# Relocating just the bin dir isn't enough: the shim it drops in /usr/local/bin is a
# symlink into $HOME/.local/share/uv/tools/..., and /root itself is drwx------ (root-
# only traversal) - `dev` gets "Permission denied" resolving through it even though
# every file past that point is world-readable/executable.
UV_TOOL_DIR=/usr/local/share/uv-tools UV_TOOL_BIN_DIR=/usr/local/bin uv tool install git+https://github.com/WildDogOne/DefenderXDRMCP
UV_TOOL_DIR=/usr/local/share/uv-tools UV_TOOL_BIN_DIR=/usr/local/bin uv tool install git+https://github.com/WildDogOne/XSOARMCP
UV_TOOL_DIR=/usr/local/share/uv-tools UV_TOOL_BIN_DIR=/usr/local/bin uv tool install git+https://github.com/WildDogOne/KestraMCP