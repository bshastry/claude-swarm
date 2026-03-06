#!/bin/bash
set -euo pipefail

# Container entrypoint: clone, setup, loop claude sessions.

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    cat <<HELP
Usage: $0

Container entrypoint for claude-swarm agents. Not intended to
be run directly -- launched automatically inside Docker by
launch.sh.

Clones the bare repo, runs optional setup, then loops claude
sessions until the agent is idle for MAX_IDLE cycles.

Required environment:
  SWARM_PROMPT   Path to prompt file (relative to repo root).
  CLAUDE_MODEL   Model to use for claude sessions.

Optional environment:
  AGENT_ID       Agent identifier (default: unnamed).
  SWARM_SETUP    Setup script to run before first session.
  MAX_IDLE       Idle sessions before exit (default: 3).
  INJECT_GIT_RULES  Inject git coordination rules (default: true).
HELP
    exit 0
fi

AGENT_ID="${AGENT_ID:-unnamed}"

# Fallback: if Docker socket is mounted but not readable
# by the agent user (launcher did not pass --group-add),
# fix permissions via sudo. Only fires on EACCES (not
# readable), NOT on daemon-down (ECONNREFUSED). The
# agent user has passwordless sudo.
if [ -S /var/run/docker.sock ] && [ ! -r /var/run/docker.sock ]; then
    echo "[harness:${AGENT_ID}] Fixing Docker socket permissions..."
    sudo chmod 660 /var/run/docker.sock
fi

CLAUDE_MODEL="${CLAUDE_MODEL:-claude-opus-4-6}"
SWARM_PROMPT="${SWARM_PROMPT:?SWARM_PROMPT is required.}"
SWARM_SETUP="${SWARM_SETUP:-}"
MAX_IDLE="${MAX_IDLE:-3}"
INJECT_GIT_RULES="${INJECT_GIT_RULES:-true}"
STATS_FILE="/agent_logs/stats_agent_${AGENT_ID}.tsv"

GIT_USER_NAME="${GIT_USER_NAME:-swarm-agent}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-agent@claude-swarm.local}"
git config --global user.name "$GIT_USER_NAME"
git config --global user.email "$GIT_USER_EMAIL"

# Capture CLI version once for the prepare-commit-msg hook.
CLAUDE_VERSION=$(claude --version 2>/dev/null || echo "unknown")
CLAUDE_VERSION="${CLAUDE_VERSION%% *}"
export CLAUDE_VERSION
export SWARM_RUN_CONTEXT="${SWARM_RUN_CONTEXT:-unknown}"
export SWARM_CFG_PROMPT="${SWARM_CFG_PROMPT:-${SWARM_PROMPT}}"
export SWARM_CFG_SETUP="${SWARM_CFG_SETUP:-${SWARM_SETUP}}"

echo "[harness:${AGENT_ID}] Starting (model=${CLAUDE_MODEL}, prompt=${SWARM_PROMPT})..."

if [ ! -d "/workspace/.git" ]; then
    echo "[harness:${AGENT_ID}] Cloning upstream to /workspace..."
    git clone /upstream /workspace
    cd /workspace

    # Init only submodules whose mirrors were mounted into the
    # container. Client submodules without mirrors keep their
    # upstream URLs and are left for the agent to init on demand.
    if [ -f .gitmodules ]; then
        git config --file .gitmodules --get-regexp 'submodule\..*\.path' | \
        while read -r key path; do
            name="${key#submodule.}"
            name="${name%.path}"
            if [ -d "/mirrors/${name}" ]; then
                git config "submodule.${name}.url" "/mirrors/${name}"
                git submodule update --init -- "$path"
            fi
        done
    fi

    git checkout agent-work

    # Run project-specific setup if provided.
    # Do NOT wrap in sudo: setup scripts use inline sudo for
    # privileged ops, and wrapping strips Docker-injected env
    # vars (ANTHROPIC_API_KEY, GITHUB_TOKEN, etc.).
    if [ -n "$SWARM_SETUP" ] && [ -f "$SWARM_SETUP" ]; then
        echo "[harness:${AGENT_ID}] Running ${SWARM_SETUP}..."
        bash "$SWARM_SETUP"
    fi

    # Disable Claude Code's Co-Authored-By trailer; the hook-injected
    # trailers (Model/Agent) are the single source of truth.
    mkdir -p .claude
    printf '{"attribution":{"commit":"","pr":""}}\n' > .claude/settings.local.json

    # Install prepare-commit-msg hook to append provenance trailers.
    # Fires on every commit including git commit -m.
    SWARM_VERSION=$(cat /swarm-version 2>/dev/null || echo "unknown")
    export SWARM_VERSION
    mkdir -p .git/hooks
    cat > .git/hooks/prepare-commit-msg <<'HOOK'
#!/bin/bash
if ! grep -q '^Model:' "$1"; then
    printf '\nModel: %s\nTools: claude-swarm %s, Claude Code %s\n' \
        "$CLAUDE_MODEL" "$SWARM_VERSION" "$CLAUDE_VERSION" >> "$1"
    printf '> Run: %s\n' "$SWARM_RUN_CONTEXT" >> "$1"
    cfg="$SWARM_CFG_PROMPT"
    [ -n "$SWARM_CFG_SETUP" ] && cfg="${cfg}, ${SWARM_CFG_SETUP}"
    printf '> Cfg: %s\n' "$cfg" >> "$1"
fi
HOOK
    chmod +x .git/hooks/prepare-commit-msg

    # Source PATH additions made by setup (Rust, Go, etc.)
    # so that the claude session inherits them.
    # shellcheck source=/dev/null
    [ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"
    export PATH="/usr/local/go/bin:$HOME/go/bin:${PATH}"

    mkdir -p /agent_logs
    echo "[harness:${AGENT_ID}] Setup complete."
fi

cd /workspace

IDLE_COUNT=0
BACKOFF=300
RATE_LIMIT_COUNT=0

while true; do
    # Reset to latest. Do not re-init submodules; setup changes would be lost.
    git fetch origin
    git reset --hard origin/agent-work

    BEFORE=$(git rev-parse origin/agent-work)
    COMMIT=$(git rev-parse --short=6 HEAD)
    LOGFILE="/agent_logs/agent_${AGENT_ID}_${COMMIT}_$(date +%s).jsonl"
    mkdir -p /agent_logs
    ln -sf "$(basename "$LOGFILE")" /agent_logs/latest.jsonl

    echo "[harness:${AGENT_ID}] Starting session at ${COMMIT}..."

    APPEND_ARGS=()
    if [ "$INJECT_GIT_RULES" = "true" ] && [ -f /agent-system-prompt.md ]; then
        APPEND_ARGS+=(--append-system-prompt-file /agent-system-prompt.md)
    fi

    claude --dangerously-skip-permissions \
           -p "$(cat "$SWARM_PROMPT")" \
           --model "$CLAUDE_MODEL" \
           --verbose \
           --output-format stream-json \
           "${APPEND_ARGS[@]+"${APPEND_ARGS[@]}"}" \
           > "$LOGFILE" 2>"${LOGFILE}.err" || true

    # Extract the result event from NDJSON stream.
    # The last line with type=result contains session
    # summary (cost, tokens, duration, errors).
    SUMMARY=$(grep '^{.*"type":"result"' "$LOGFILE" \
      | tail -1 || true)
    if [ -z "$SUMMARY" ]; then
        # No result event: session crashed before
        # producing summary. Treat as error.
        is_err="true"
        err_result="No result event in JSONL output"
    else
        is_err=$(echo "$SUMMARY" \
          | jq -r '.is_error // false' 2>/dev/null \
          || true)
        is_err="${is_err:-false}"
        err_result=$(echo "$SUMMARY" \
          | jq -r '.result // ""' 2>/dev/null \
          || true)
        err_result="${err_result:-}"
    fi

    # Extract usage stats from the result event.
    # Guard: if SUMMARY matched a non-JSON line, jq
    # will fail. Validate before parsing.
    if [ -n "$SUMMARY" ] \
        && echo "$SUMMARY" | jq -e . >/dev/null 2>&1
    then
        cost=$(echo "$SUMMARY" \
          | jq -r '.total_cost_usd // 0')
        dur=$(echo "$SUMMARY" \
          | jq -r '.duration_ms // 0')
        api_ms=$(echo "$SUMMARY" \
          | jq -r '.duration_api_ms // 0')
        turns=$(echo "$SUMMARY" \
          | jq -r '.num_turns // 0')
        tok_in=$(echo "$SUMMARY" \
          | jq -r '.usage.input_tokens // 0')
        tok_out=$(echo "$SUMMARY" \
          | jq -r '.usage.output_tokens // 0')
        cache_rd=$(echo "$SUMMARY" \
          | jq -r \
          '.usage.cache_read_input_tokens // 0')
        cache_cr=$(echo "$SUMMARY" \
          | jq -r \
          '.usage.cache_creation_input_tokens // 0')
    else
        cost=0 dur=0 api_ms=0 turns=0
        tok_in=0 tok_out=0 cache_rd=0 cache_cr=0
    fi
    mkdir -p "$(dirname "$STATS_FILE")"
    # Skip TSV for error sessions (e.g. rate limit)
    # to avoid inflating dashboard turn count.
    if [ "$is_err" != "true" ]; then
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
            "$(date +%s)" "$cost" "$tok_in" "$tok_out" \
            "$cache_rd" "$cache_cr" "$dur" "$api_ms" \
            "$turns" \
            >> "$STATS_FILE"
    fi
    echo "[harness:${AGENT_ID}] Session cost=\$${cost} tokens=${tok_in}/${tok_out} turns=${turns} duration=${dur}ms"

    # --- Error surfacing (BUG-003) ---
    err_file="${LOGFILE}.err"
    if [ "$is_err" = "true" ]; then
        echo "[harness:${AGENT_ID}] ERROR: ${err_result}"

        # Rate-limit backoff (BUG-002): sleep + retry
        # instead of counting toward idle limit.
        if echo "$err_result" \
            | grep -qiE \
              "hit your limit|rate.limit|quota"; then
            JITTER=$((RANDOM % 60))
            RATE_LIMIT_COUNT=$((RATE_LIMIT_COUNT + 1))
            echo "[harness:${AGENT_ID}]" \
                 "rate-limit ${RATE_LIMIT_COUNT}" \
                 "(sleeping $((BACKOFF + JITTER))s)..."
            # Signal-aware sleep: responds to docker
            # stop SIGTERM instead of blocking until
            # SIGKILL after the 10s grace period.
            trap 'exit 0' TERM INT
            sleep $((BACKOFF + JITTER)) &
            wait $! || true
            trap - TERM INT
            # Exponential backoff, cap at 30 min.
            BACKOFF=$((BACKOFF * 2))
            if [ "$BACKOFF" -gt 1800 ]; then
                BACKOFF=1800
            fi
            continue
        fi

        # Non-rate-limit errors (auth failure, network,
        # corrupt prompt): slow down cycling but still
        # count toward idle limit. Auth failures need
        # operator intervention, not infinite retry.
        trap 'exit 0' TERM INT
        sleep 30 &
        wait $! || true
        trap - TERM INT
    fi
    if [ -s "$err_file" ]; then
        echo "[harness:${AGENT_ID}] STDERR:" \
             "$(head -3 "$err_file")"
    fi
    # Reset backoff on any non-error session.
    if [ "$is_err" != "true" ]; then
        BACKOFF=300
        RATE_LIMIT_COUNT=0
    fi

    git fetch origin
    AFTER=$(git rev-parse origin/agent-work)

    if [ "$BEFORE" = "$AFTER" ]; then
        IDLE_COUNT=$((IDLE_COUNT + 1))
        echo "[harness:${AGENT_ID}] No commits pushed (idle ${IDLE_COUNT}/${MAX_IDLE})."
        if [ "$IDLE_COUNT" -ge "$MAX_IDLE" ]; then
            echo "[harness:${AGENT_ID}] Idle limit reached, exiting."
            exit 0
        fi
    else
        IDLE_COUNT=0
        BACKOFF=300
        RATE_LIMIT_COUNT=0
        echo "[harness:${AGENT_ID}] Session ended. Restarting..."
    fi
done
