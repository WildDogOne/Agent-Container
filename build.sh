#!/bin/sh
# Builds one image per harness, devcontainer:<harness>. With no arguments, builds every
# harness under harnesses/; otherwise just the ones named (e.g. `./build.sh claude`).
set -eu
cd "$(dirname "$0")"

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
  echo "build.sh: building devcontainer:$harness" >&2
  docker build --no-cache -f image/Dockerfile --build-arg "HARNESS=$harness" -t "devcontainer:$harness" .
done

# --no-cache means every rebuild produces a brand-new image and dangles whatever
# devcontainer:<harness> pointed at before (docker moves the tag, not the image). Those
# pile up fast since nothing else references them. The `project=devcontainer` label
# (see Dockerfile) scopes this prune to our own leftovers, not unrelated dangling images
# elsewhere on the host. run.sh always runs containers with --rm, so no stopped
# containers should be left to clean up here.
docker image prune -f --filter "label=project=devcontainer" --filter "dangling=true" >/dev/null
