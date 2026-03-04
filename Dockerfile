FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    ca-certificates \
    clang \
    make \
    jq \
    sudo \
    && rm -rf /var/lib/apt/lists/*

# Docker CLI (static binary, client only).
# Daemon runs on host; agents talk via mounted socket.
ARG DOCKER_VERSION=27.5.1
ARG DOCKER_SHA256=4f798b3ee1e0140eab5bf30b0edc4e84f4cdb53255a429dc3bbae9524845d640
RUN curl -fsSL \
      "https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_VERSION}.tgz" \
      -o /tmp/docker.tgz \
    && echo "${DOCKER_SHA256}  /tmp/docker.tgz" \
       | sha256sum -c - \
    && tar -xzf /tmp/docker.tgz \
       --strip-components=1 \
       -C /usr/local/bin/ docker/docker \
    && rm /tmp/docker.tgz

# Claude Code refuses --dangerously-skip-permissions as root.
RUN useradd -m -s /bin/bash agent \
    && echo "agent ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/agent
USER agent

# Language toolchains are installed by SWARM_SETUP, not here.
# Docker socket is bind-mounted at runtime by launch.sh when the
# swarm config has "docker_socket": true (needed for Kurtosis).

RUN curl -fsSL https://claude.ai/install.sh -o /tmp/claude-install.sh \
    && bash /tmp/claude-install.sh \
    && rm /tmp/claude-install.sh
ENV PATH="/home/agent/.local/bin:${PATH}"

# Trust mounted bare repos and allow file:// transport for submodules.
RUN git config --global --add safe.directory '*' \
    && git config --global protocol.file.allow always

COPY --chmod=755 lib/harness.sh /harness.sh
COPY --chmod=644 lib/agent-system-prompt.md /agent-system-prompt.md
COPY --chmod=644 VERSION /swarm-version

WORKDIR /workspace

ENTRYPOINT ["/harness.sh"]
