#!/bin/bash
set -euo pipefail

# Render stream-json NDJSON agent logs as readable text.
# Usage:
#   view-agent.sh [--follow] [--full] [--list] AGENT_ID [SESSION_FILE]

if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required." >&2
    exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null \
  || pwd)"
SWARM_DATA_DIR="${SWARM_DATA_DIR:-${REPO_ROOT}/.swarm}"

usage() {
    cat <<HELP
Usage: $0 [OPTIONS] AGENT_ID [SESSION_FILE]

Render agent session logs as human-readable text.

Options:
  --follow   Live-tail the current session (tail -F).
  --full     Show full tool results (default: 10 lines).
  --list     List all sessions for the given agent.
  -h, --help Show this help.

Arguments:
  AGENT_ID       Agent number (e.g. 1, 2, post).
  SESSION_FILE   Specific .jsonl file (optional;
                 defaults to latest.jsonl).

Examples:
  $0 3                     # latest session, agent 3
  $0 --follow 3            # live tail agent 3
  $0 --list 3              # list all sessions
  $0 --full 3 session.jsonl  # full output, specific file

Notes:
  --follow uses tail -F, which re-opens the file when
  the latest.jsonl symlink target changes between
  sessions.
HELP
    exit 0
}

FOLLOW=false
FULL=false
LIST=false

while [ $# -gt 0 ]; do
    case "$1" in
        --follow) FOLLOW=true; shift ;;
        --full)   FULL=true; shift ;;
        --list)   LIST=true; shift ;;
        -h|--help) usage ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *)  break ;;
    esac
done

AGENT_ID="${1:?AGENT_ID required (e.g. 1, 2, post)}"
shift
SESSION_FILE="${1:-}"

LOG_DIR="${SWARM_DATA_DIR}/logs/agent-${AGENT_ID}"

if [ ! -d "$LOG_DIR" ]; then
    echo "ERROR: ${LOG_DIR} not found." >&2
    exit 1
fi

if $LIST; then
    echo "Sessions for agent-${AGENT_ID}:"
    find "$LOG_DIR" -maxdepth 1 -name '*.jsonl' \
        ! -type l -exec ls -lt {} + 2>/dev/null \
        || echo "  (none)"
    exit 0
fi

if [ -z "$SESSION_FILE" ]; then
    SESSION_FILE="${LOG_DIR}/latest.jsonl"
fi

if [ ! -f "$SESSION_FILE" ]; then
    echo "ERROR: ${SESSION_FILE} not found." >&2
    exit 1
fi

# Single jq filter parameterized by $truncate.
# --full sets truncate=false; default is true.
# shellcheck disable=SC2016
JQ_FILTER='
if .type == "system" and .subtype == "init" then
    "\n=== SESSION START ===\n"
    + "Model: \(.model // "unknown")\n"
    + "Session: \(.session_id // "unknown")\n"
    + "Tools: \(.tools // [] | length)\n"
    + "===================\n"
elif .type == "assistant" then
    .message.content[]
    | if .type == "text" then
        "\n\u001b[1;34m[Agent]\u001b[0m " + .text + "\n"
      elif .type == "tool_use" then
        "\n\u001b[1;33m[" + .name + "]\u001b[0m "
        + (if $truncate then
             .input | tostring | .[0:200]
           else
             .input | tostring
           end) + "\n"
      else empty
      end
elif .type == "user" then
    .message.content[]
    | if .type == "tool_result" then
        "\u001b[0;36m  [result]\u001b[0m "
        + ((.content // "")
           | tostring
           | if $truncate then
               split("\n")
               | if length > 10 then
                   .[0:10] | join("\n")
                   | . + "\n  ... (truncated)"
                 else join("\n")
                 end
             else .
             end) + "\n"
      else empty
      end
elif .type == "result" then
    "\n=== SESSION END ===\n"
    + "Cost:     $\(.total_cost_usd // 0)\n"
    + "Tokens:   \(.usage.input_tokens // 0) in"
    + " / \(.usage.output_tokens // 0) out\n"
    + "Cache:    \(.usage.cache_read_input_tokens // 0)"
    + " read"
    + " / \(.usage.cache_creation_input_tokens // 0)"
    + " created\n"
    + "Duration: \(.duration_ms // 0)ms"
    + " (API: \(.duration_api_ms // 0)ms)\n"
    + "Turns:    \(.num_turns // 0)\n"
    + "Error:    \(.is_error // false)\n"
    + "===================\n"
else empty
end
'

TRUNC_ARG="--argjson truncate true"
if $FULL; then
    TRUNC_ARG="--argjson truncate false"
fi

if $FOLLOW; then
    # tail -F re-opens on rename (symlink target change).
    # jq --unbuffered prevents output stalling.
    # shellcheck disable=SC2086
    tail -F "$SESSION_FILE" \
        | jq --unbuffered -rR $TRUNC_ARG \
            "fromjson? | ${JQ_FILTER}"
else
    # shellcheck disable=SC2086
    jq -rR $TRUNC_ARG "fromjson? | ${JQ_FILTER}" \
        < "$SESSION_FILE"
fi
