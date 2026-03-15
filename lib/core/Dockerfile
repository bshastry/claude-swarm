FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    ca-certificates \
    jq \
    sudo \
    && rm -rf /var/lib/apt/lists/*

# Non-root user. Claude Code refuses --dangerously-skip-
# permissions as root.
RUN useradd -m -s /bin/bash agent \
    && echo "agent ALL=(ALL) NOPASSWD:ALL" \
       > /etc/sudoers.d/agent
USER agent

# Claude Code CLI.
RUN curl -fsSL https://claude.ai/install.sh \
       -o /tmp/claude-install.sh \
    && bash /tmp/claude-install.sh \
    && rm /tmp/claude-install.sh
ENV PATH="/home/agent/.local/bin:${PATH}"

# Trust any mounted repo path.
RUN git config --global --add safe.directory '*' \
    && git config --global protocol.file.allow always

# Copy the library and entrypoint.
COPY --chmod=755 swarm-core.sh /swarm/swarm-core.sh
COPY --chmod=644 coordination.md /swarm/coordination.md
COPY --chmod=755 entrypoint.sh /entrypoint.sh

# Output directory for project and logs.
RUN mkdir -p /output/project /output/logs
VOLUME ["/output"]

WORKDIR /workspace

ENTRYPOINT ["/entrypoint.sh"]
