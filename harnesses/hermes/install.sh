#!/bin/sh
# Installs Hermes Agent (https://github.com/NousResearch/hermes-agent) into the image.
# Runs as root at build time (see image/Dockerfile).
#
# The upstream installer puts the code and its own pinned uv/Python/Node inside the
# Hermes home (~/.hermes). Here ~/.hermes is a host mount (see harness.conf), so the
# install gets its own home at /opt/hermes instead. A session's ~/.hermes then
# "borrows" it: Hermes finds the dependency environment through the home the checkout
# sits in (/opt/hermes/hermes-agent -> /opt/hermes), so ~/.hermes only holds your
# config and state.
set -eu

curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh \
  | bash -s -- --dir /opt/hermes/hermes-agent --hermes-home /opt/hermes \
      --non-interactive --skip-browser --skip-computer-use

# Hermes refuses to run an install owned by another user; dev is UID/GID 1000 in the
# image (entrypoint.sh re-chowns `owned` paths if dev gets remapped to a different ID).
chown -R 1000:1000 /opt/hermes
ln -sf /opt/hermes/hermes-agent/.hermes/bin/hermes /usr/local/bin/hermes
# Only /opt/hermes itself has a ready environment at this point; a session home prepares
# its own on first launch (into ~/.hermes/installs, a few hundred MB).
HERMES_HOME=/opt/hermes hermes --version
