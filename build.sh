#!/bin/sh
# Builds one image per harness, agentcontainer:<harness>. With no arguments, builds every
# harness under harnesses/; otherwise just the ones named (e.g. `./build.sh claude`).
#
# Default: --no-cache, so every build pulls current apt packages, Node/Python/uv/bun and
# the harness itself (a cached build would keep e.g. an old Claude Code forever).
# --cached: reuse Docker's layer cache instead - fast for iterating on this repo's own
# files (entrypoint.sh, the proxy addon, allowlists: the Dockerfile copies them last),
# but nothing already cached is updated. Do a plain build now and then.
set -eu
cd "$(dirname "$0")"

cache_flag=--no-cache
harness_args=""
for arg in "$@"; do
  case "$arg" in
    --cached) cache_flag="" ;;
    -h|--help)
      echo "usage: ./build.sh [--cached] [harness...]  (no harness = all; --cached reuses the layer cache)"
      exit 0 ;;
    -*) echo "build.sh: unknown option '$arg' (try --help)" >&2; exit 1 ;;
    *) harness_args="$harness_args $arg" ;;
  esac
done
# shellcheck disable=SC2086 # harness names are plain words (checked against harnesses/ below)
set -- $harness_args

# extra-setup.sh is gitignored (personal, like allowed-domains.txt - see
# config/extra-setup.sh.example) and the Dockerfile COPYs it unconditionally, so seed a
# no-op copy here if it's missing rather than letting a fresh clone fail to build.
[ -f config/extra-setup.sh ] || cp config/extra-setup.sh.example config/extra-setup.sh

# Same for allowed-domains.txt (also gitignored, also COPYed unconditionally) - but said
# out loud, since unlike a no-op extra-setup.sh this decides what the container can reach.
if [ ! -f config/allowed-domains.txt ]; then
  cp config/allowed-domains.txt.example config/allowed-domains.txt
  echo "build.sh: created config/allowed-domains.txt - add your own egress allowlist entries there" >&2
fi

if [ "$#" -eq 0 ]; then
  for dir in harnesses/*/; do
    set -- "$@" "$(basename "$dir")"
  done
fi

for harness in "$@"; do
  if [ ! -f "harnesses/$harness/harness.conf" ]; then
    avail=""
    for dir in harnesses/*/; do name="${dir%/}"; avail="$avail ${name#harnesses/}"; done
    echo "build.sh: unknown harness '$harness' - available: ${avail# }" >&2
    exit 1
  fi
done

# Repo root as the build context: the Dockerfile needs image/, harnesses/ and config/
# (.dockerignore keeps everything else out).
for harness in "$@"; do
  echo "build.sh: building agentcontainer:$harness" >&2
  docker build ${cache_flag:+"$cache_flag"} -f image/Dockerfile --build-arg "HARNESS=$harness" -t "agentcontainer:$harness" .
done

# A rebuild (always with --no-cache, often with --cached) produces a new image and dangles whatever
# agentcontainer:<harness> pointed at before (docker moves the tag, not the image). Those
# pile up fast since nothing else references them. The `project=agentcontainer` label
# (see Dockerfile) scopes this prune to our own leftovers, not unrelated dangling images
# elsewhere on the host. run.sh always runs containers with --rm, so no stopped
# containers should be left to clean up here.
docker image prune -f --filter "label=project=agentcontainer" --filter "dangling=true" >/dev/null
