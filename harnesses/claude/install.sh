#!/bin/sh
# Installs Claude Code into the image. Runs as root at build time, after Node/Python/
# uv/bun are on PATH (see image/Dockerfile).
set -eu

npm install -g @anthropic-ai/claude-code
