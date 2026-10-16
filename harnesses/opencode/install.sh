#!/bin/sh
# Installs opencode (https://opencode.ai) into the image. Runs as root at build time,
# after Node is on PATH (see image/Dockerfile). The npm package pulls in the prebuilt
# binary for this platform; npm's own launcher lands in /usr/bin/opencode.
set -eu

npm install -g opencode-ai

# The global npm install is root-owned, so opencode's self-update can't work as dev -
# and the image is rebuilt (--no-cache) to update anyway. The env var is set in a
# wrapper rather than in harness.conf's `command` so it also covers `run.sh bash` and
# then `opencode` by hand. /usr/local/bin comes before /usr/bin on PATH.
cat > /usr/local/bin/opencode <<'WRAPPER'
#!/bin/sh
export OPENCODE_DISABLE_AUTOUPDATE=1
exec /usr/bin/opencode "$@"
WRAPPER
chmod 755 /usr/local/bin/opencode

opencode --version
