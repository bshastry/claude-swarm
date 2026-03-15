#!/bin/bash
# runner-claude.sh — Claude Code agent runner for improve.
#
# Identical to the greenfield runner. Included separately
# so each example is self-contained and you can customize
# per use case (e.g. add setup commands, linter calls).

run_agent() {
    local prompt_file="$1" workdir="$2" agent_id="$3"
    cd "$workdir"

    local full_prompt
    full_prompt="$(cat "$prompt_file")"
    if [ -n "${SWARM_COORDINATION_PROMPT:-}" ]; then
        full_prompt="${full_prompt}

${SWARM_COORDINATION_PROMPT}"
    fi

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
