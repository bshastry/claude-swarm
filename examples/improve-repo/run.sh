#!/bin/bash
set -euo pipefail

# run.sh — Launch an improve swarm against a GitHub repo.
#
# Usage:
#   ANTHROPIC_API_KEY=sk-... \
#   REPO=https://github.com/user/project \
#       ./examples/improve-repo/run.sh
#
# Options (via environment):
#   REPO=url         GitHub repo URL (required).
#   BRANCH=name      Branch to create/use (default: swarm-improve).
#   AGENTS=N         Number of agents (default: 2).
#   MODEL=name       Claude model (default: claude-sonnet-4-6).
#   MAX_IDLE=N       Idle sessions before exit (default: 3).
#   PROMPT=path      Custom prompt file (default: bundled prompt).
#   OUT_DIR=path     Where to clone (default: /tmp/swarm-improve-<repo>).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "${SCRIPT_DIR}/../../lib/core" && pwd)"

if [ -z "${REPO:-}" ]; then
    echo "ERROR: REPO is required." >&2
    echo "  REPO=https://github.com/user/project $0" >&2
    exit 1
fi

AGENTS="${AGENTS:-2}"
MODEL="${MODEL:-claude-sonnet-4-6}"
PROMPT="${PROMPT:-${SCRIPT_DIR}/prompt.md}"
BRANCH="${BRANCH:-swarm-improve}"

export CLAUDE_MODEL="$MODEL"
export SWARM_MAX_IDLE="${MAX_IDLE:-3}"

ARGS=(
    improve
    --repo "$REPO"
    --prompt "$PROMPT"
    --agents "$AGENTS"
    --model "$MODEL"
    --branch "$BRANCH"
)

if [ -n "${OUT_DIR:-}" ]; then
    ARGS+=(--out "$OUT_DIR")
fi

exec "$CORE_DIR/swarm-run.sh" "${ARGS[@]}"
