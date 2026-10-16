FROM ubuntu:24.04

# Built by build.sh with the repo root as context: everything up to the HARNESS section
# at the bottom is shared by every harness, the rest comes from harnesses/<name>/.

# Lets build.sh find and prune old, now-untagged versions of this image left behind by
# --no-cache rebuilds (each rebuild retags devcontainer:<harness> onto the new image,
# dangling the previous one) without touching unrelated dangling images on the host.
LABEL project=devcontainer

ARG DEBIAN_FRONTEND=noninteractive

# Packages are hand-installed rather than via devcontainer.json "features", since there's
# no devcontainer.json here at all. NodeSource for a current Node, since Ubuntu 24.04's
# own "nodejs" is 18.x/EOL and too old for npm-distributed harnesses (Claude Code needs
# >=22); "gh" isn't in Ubuntu's default repos.
# openssh-client (not -server): outbound git-over-SSH only - see entrypoint.sh/run.sh
# for host ssh-agent forwarding. Nothing listens for inbound SSH in this image.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && chmod go+r /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" > /etc/apt/sources.list.d/nodesource.list \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends \
    nodejs \
    docker.io \
    docker-compose-v2 \
    gh \
    ripgrep \
    jq \
    fzf \
    zsh \
    git \
    openssh-client \
    bash \
    sudo \
    # squid: loopback-only egress allowlist proxy, see squid.conf.
    squid \
    # unzip: required by the Bun installer below (bun ships as a .zip release).
    unzip \
    && rm -rf /var/lib/apt/lists/*

# The allowlist itself (/etc/squid/allowed-domains.txt) is assembled per harness at the
# bottom of this file.
COPY image/squid.conf /etc/squid/squid.conf
# CRLF -> LF on everything COPYed in from the build context (here and below): a Windows
# checkout with core.autocrlf=true, or a gitignored file saved in Notepad, would
# otherwise give squid "example.com\r" domains and the shell scripts a "/bin/sh\r"
# interpreter. .gitattributes covers tracked files; this also covers the personal ones.
RUN sed -i 's/\r$//' /etc/squid/squid.conf

# Ubuntu 24.04's own python3 is 3.12; 3.14 comes from the deadsnakes PPA (needs
# software-properties-common's add-apt-repository - there's no plain apt source line
# that's stable across releases). update-alternatives repoints the system
# /usr/bin/python3 and adds /usr/bin/python at 3.14, so a project's .venv (created with
# either binary, on whatever host actually runs `docker build`) resolves the same way
# inside this container. Trade-off: apt's own python3-apt module stays compiled
# against 3.12, so python3-dependent apt tooling (add-apt-repository, unattended-upgrade)
# would break if invoked again after this point - not used anywhere else in this image
# or its runtime scripts, so left as-is rather than avoided.
RUN apt-get update && apt-get install -y --no-install-recommends software-properties-common \
    && add-apt-repository -y ppa:deadsnakes/ppa \
    && apt-get update && apt-get install -y --no-install-recommends \
    python3.14 \
    python3.14-venv \
    && update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.14 1 \
    && update-alternatives --install /usr/bin/python python /usr/bin/python3.14 1 \
    && rm -rf /var/lib/apt/lists/*

# Sourced by every zsh invocation (login or not, interactive or not), unlike
# /etc/profile.d which plain zsh doesn't read - so this applies the same whether you
# land here via `docker exec` or the entrypoint's own login shell. Walks up from $PWD
# rather than a fixed path, since this image doesn't know in advance which project
# directory a given session will open (see run.sh's cwd mount).
RUN mkdir -p /etc/zsh && cat <<'EOF' > /etc/zsh/zshenv.venv
_venv_dir=$PWD
while [ -n "$_venv_dir" ] && [ "$_venv_dir" != "/" ]; do
  if [ -f "$_venv_dir/.venv/bin/activate" ]; then
    . "$_venv_dir/.venv/bin/activate"
    break
  fi
  _venv_dir=${_venv_dir%/*}
done
unset _venv_dir
EOF
RUN echo '[ -f /etc/zsh/zshenv.venv ] && . /etc/zsh/zshenv.venv' >> /etc/zsh/zshenv

# Belt-and-suspenders alongside entrypoint.sh's explicit --preserve-env: covers any
# other login/PAM-aware program that reads /etc/environment directly (sudo's own PAM
# session module included, depending on /etc/pam.d/sudo config).
RUN cat <<'EOF' >> /etc/environment
HTTP_PROXY=http://127.0.0.1:3128
HTTPS_PROXY=http://127.0.0.1:3128
NO_PROXY=localhost,127.0.0.1
http_proxy=http://127.0.0.1:3128
https_proxy=http://127.0.0.1:3128
no_proxy=localhost,127.0.0.1
EOF

COPY image/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN sed -i 's/\r$//' /usr/local/bin/entrypoint.sh && chmod +x /usr/local/bin/entrypoint.sh

# Create a non-root "dev" user at UID/GID 1000. entrypoint.sh remaps it to the
# invoking host user's UID/GID at startup (passed in by run.sh), so files created in
# the container stay owned by that user on the host. docker.io's postinst already creates the
# "docker" group. Ubuntu's base image already ships a default "ubuntu" user/group
# at 1000:1000, so it has to go first to free up that UID/GID.
ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=$USER_UID
RUN if getent passwd ubuntu >/dev/null; then userdel -r ubuntu; fi \
    && if getent group ubuntu >/dev/null; then groupdel ubuntu; fi \
    && groupadd -g $USER_GID $USERNAME \
    && useradd -m -u $USER_UID -g $USER_GID -s /bin/zsh $USERNAME \
    && usermod -aG docker $USERNAME \
    && echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$USERNAME \
    && chmod 0440 /etc/sudoers.d/$USERNAME

# uv/uvx: MCP servers registered with a harness (e.g. `uvx mcp-atlassian`) exec uvx
# directly, so it has to be a real binary on PATH rather than something uvx's own
# on-demand package fetch could paper over. Static binary straight to /usr/local/bin
# (already on PATH for both root and dev, see USERNAME block above) rather than the
# installer's default ~/.local/bin, since root's $HOME isn't dev's $HOME and this
# needs to work for both.
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

# Bun: runtime for MCP servers started via `bun run`, e.g. the official "telegram"
# Claude Code plugin's (the plugin itself lives in the harness's bind-mounted config
# dir, so only the `bun` binary needs to be in the image). Same /usr/local/bin
# reasoning as uv above, and for the same reason it matters even more here: entrypoint.sh's `sudo -u dev` calls don't preserve PATH, so a bun install
# living under a home directory (root's or dev's) would silently vanish once dropped
# to dev - sudo resets PATH to its own fixed secure_path, which only covers the usual
# /usr/local/bin, /usr/bin, etc.
RUN curl -fsSL https://bun.sh/install | env BUN_INSTALL=/usr/local bash

# Optional per-machine extra dependencies (custom MCP servers' own runtime
# requirements, extra apt/npm/uv packages, etc.) - see config/extra-setup.sh.example.
# config/extra-setup.sh itself is gitignored (personal, like config/allowed-domains.txt);
# build.sh seeds a no-op copy from the .example if it's missing, so a fresh clone still
# builds with nothing extra installed. Runs as root, after Node/Python/uv/bun are
# already on PATH, in the same unrestricted build-time network as the rest of this file.
COPY config/extra-setup.sh /tmp/extra-setup.sh
RUN sed -i 's/\r$//' /tmp/extra-setup.sh && chmod +x /tmp/extra-setup.sh && /tmp/extra-setup.sh && rm /tmp/extra-setup.sh

# --- HARNESS ---------------------------------------------------------------------
# Everything below comes from harnesses/$HARNESS/ (see harnesses/README.md):
# install.sh installs the tool, harness.conf tells entrypoint.sh what to start by
# default, and the egress allowlist is the shared defaults + the harness's own domains
# + your config/allowed-domains.txt. sort -u drops exact duplicates (an older personal
# list that still repeats the defaults is harmless).
ARG HARNESS
RUN test -n "$HARNESS" || { echo "build with --build-arg HARNESS=<name> (see build.sh)" >&2; exit 1; }
LABEL harness=$HARNESS

COPY harnesses/${HARNESS}/ /tmp/harness/
RUN find /tmp/harness -type f -exec sed -i 's/\r$//' {} + \
    && mkdir -p /etc/devcontainer \
    && cp /tmp/harness/harness.conf /etc/devcontainer/harness.conf \
    && sh /tmp/harness/install.sh \
    && rm -rf /tmp/harness

COPY image/allowed-domains.txt /tmp/domains/00-default.txt
COPY harnesses/${HARNESS}/allowed-domains.txt /tmp/domains/10-harness.txt
COPY config/allowed-domains.txt /tmp/domains/20-local.txt
RUN cat /tmp/domains/*.txt | sed 's/\r$//; s/#.*//; s/[[:space:]]//g' | grep -v '^$' | sort -u \
    > /etc/squid/allowed-domains.txt \
    && rm -rf /tmp/domains

# Stays root: entrypoint.sh needs it to start dockerd/squid, then drops to dev itself
# (via `sudo -u dev`) before running the actual command.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
