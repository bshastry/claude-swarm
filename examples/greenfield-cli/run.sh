#!/bin/bash
set -euo pipefail

# run.sh — Launch a greenfield swarm to build fsearch.
#
# Usage:
#   ANTHROPIC_API_KEY=sk-... ./examples/greenfield-cli/run.sh
#
# Options (via environment):
#   AGENTS=N         Number of agents (default: 3).
#   MODEL=name       Claude model (default: claude-sonnet-4-6).
#   MAX_IDLE=N       Idle sessions before exit (default: 3).
#   OUT_DIR=path     Output directory (default: /tmp/fsearch).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "${SCRIPT_DIR}/../../lib/core" && pwd)"

AGENTS="${AGENTS:-3}"
MODEL="${MODEL:-claude-sonnet-4-6}"
OUT_DIR="${OUT_DIR:-/tmp/fsearch}"

export CLAUDE_MODEL="$MODEL"
export SWARM_MAX_IDLE="${MAX_IDLE:-3}"

exec "$CORE_DIR/swarm-run.sh" greenfield \
    --prompt "${SCRIPT_DIR}/prompt.md" \
    --agents "$AGENTS" \
    --model "$MODEL" \
    --out "$OUT_DIR"
