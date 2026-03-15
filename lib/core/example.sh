#!/bin/bash
# example.sh — Minimal swarm using swarm-core.sh.
#
# Demonstrates how to plug any agent runtime into the
# coordination library. Replace my_agent with your own
# CLI tool (claude, aider, custom script, etc.).
#
# Usage:
#   # Terminal 1: start agent 1
#   ANTHROPIC_API_KEY=sk-... ./lib/core/example.sh \
#       /path/to/project 1 prompts/task.md
#
#   # Terminal 2: start agent 2
#   ANTHROPIC_API_KEY=sk-... ./lib/core/example.sh \
#       /path/to/project 2 prompts/task.md
#
#   # Both agents coordinate via git. When both idle,
#   # harvest results:
#   source lib/core/swarm-core.sh
#   swarm_harvest /path/to/project /tmp/my-swarm-bare

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=swarm-core.sh
source "${SCRIPT_DIR}/swarm-core.sh"

# --- Configuration --------------------------------------------------

REPO="${1:?Usage: $0 REPO AGENT_ID PROMPT}"
AGENT_ID="${2:?Usage: $0 REPO AGENT_ID PROMPT}"
PROMPT="${3:?Usage: $0 REPO AGENT_ID PROMPT}"

BARE="/tmp/$(basename "$REPO")-swarm-bare"
WORKSPACE="/tmp/$(basename "$REPO")-agent-${AGENT_ID}"

# --- Agent runtime (replace this) -----------------------------------

# This is the pluggable part. Swap this function to use
# any agent runtime. Return codes:
#   0 — success
#   1 — non-fatal error (counts toward idle)
#   2 — rate limit (triggers backoff)
#   3+ — fatal (agent exits)
my_agent() {
    local prompt_file="$1" workdir="$2" agent_id="$3"
    cd "$workdir"

    # Build the full prompt: task + coordination rules.
    local full_prompt
    full_prompt="$(cat "$prompt_file")"
    if [ -n "${SWARM_COORDINATION_PROMPT:-}" ]; then
        full_prompt="${full_prompt}

${SWARM_COORDINATION_PROMPT}"
    fi

    # Example: Claude Code.
    # Replace with: aider, gpt-engineer, custom script, etc.
    claude --dangerously-skip-permissions \
        -p "$full_prompt" \
        --model "${CLAUDE_MODEL:-claude-sonnet-4-6}" \
        --verbose \
        2>/dev/null || return 1

    return 0
}

# --- Main -----------------------------------------------------------

# Initialize bare repo (only first agent needs this;
# subsequent calls detect it exists and skip).
if [ ! -d "$BARE" ]; then
    swarm_init_repo "$REPO" "$BARE"
fi

# Clone workspace for this agent.
swarm_clone_workspace "$BARE" "$WORKSPACE"

# Run the loop. Agent exits when idle.
swarm_agent_loop my_agent "$PROMPT" "$AGENT_ID"

echo "Agent ${AGENT_ID} finished."
