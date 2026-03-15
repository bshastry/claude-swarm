#!/bin/bash
# runner-claude.sh — Claude Code agent runner for fsearch.
#
# This file shows how to write a custom runner that
# adds project-specific logic around the agent call.
# Pass it via: --runner examples/greenfield-cli/runner-claude.sh

# The run_agent function is called by swarm_agent_loop.
# It receives:
#   $1 — prompt file path (relative to workspace root).
#   $2 — workspace directory (absolute).
#   $3 — agent ID.
#
# Return codes:
#   0 — success.
#   1 — non-fatal error (counts toward idle).
#   2 — rate limit (triggers backoff, no idle count).
#   3+ — fatal (agent exits immediately).
run_agent() {
    local prompt_file="$1" workdir="$2" agent_id="$3"
    cd "$workdir"

    # Build prompt: task + coordination rules.
    local full_prompt
    full_prompt="$(cat "$prompt_file")"
    if [ -n "${SWARM_COORDINATION_PROMPT:-}" ]; then
        full_prompt="${full_prompt}

${SWARM_COORDINATION_PROMPT}"
    fi

    # Run Claude Code.
    local rc=0
    claude --dangerously-skip-permissions \
        -p "$full_prompt" \
        --model "${CLAUDE_MODEL:-claude-sonnet-4-6}" \
        --verbose \
        2>/dev/null || rc=$?

    case $rc in
        0) return 0 ;;
        2) return 2 ;;
        *) return 1 ;;
    esac
}
