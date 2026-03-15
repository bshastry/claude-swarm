#!/bin/bash
set -euo pipefail

# entrypoint.sh — Container entrypoint for swarm-core.
#
# Runs N agent processes inside a single container for one
# high-level idea. The idea is expressed as a mode
# (greenfield, improve, synthesize) plus a prompt.
#
# This is the container-side equivalent of swarm-run.sh.
# The host launches ONE container per idea; inside, N
# claude processes coordinate via a bare git repo.
#
# Required environment:
#   MODE             greenfield | improve | synthesize
#   SWARM_PROMPT     Prompt file (mounted or inline).
#   ANTHROPIC_API_KEY  API key for Claude.
#
# Optional environment:
#   NUM_AGENTS       Number of parallel agents (default: 3).
#   CLAUDE_MODEL     Model name (default: claude-sonnet-4-6).
#   SWARM_MAX_IDLE   Idle sessions before exit (default: 3).
#   SWARM_SETUP      Setup script path (relative to repo).
#   REPO_URL         GitHub URL (improve mode, required).
#   REPO_URLS        Comma-separated URLs (synthesize).
#   BRANCH           Branch for improve mode.
#   AGENT_PROMPTS    Comma-separated prompt files for
#                    per-agent assignment (optional).
#                    If fewer prompts than agents, extras
#                    use the main SWARM_PROMPT.

# shellcheck source=swarm-core.sh
source /swarm/swarm-core.sh

MODE="${MODE:?MODE is required (greenfield|improve|synthesize).}"
SWARM_PROMPT="${SWARM_PROMPT:?SWARM_PROMPT is required.}"
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-sonnet-4-6}"
NUM_AGENTS="${NUM_AGENTS:-3}"
SWARM_SETUP="${SWARM_SETUP:-}"
REPO_URL="${REPO_URL:-}"
REPO_URLS="${REPO_URLS:-}"
BRANCH="${BRANCH:-}"
AGENT_PROMPTS="${AGENT_PROMPTS:-}"
export SWARM_STATS_DIR="/output/logs"

OUT_DIR="/output/project"

# Bare repo on the mounted volume so agent work survives
# container crashes. Harvest is best-effort on exit.
BARE="/output/bare"

echo "=== swarm-core container ==="
echo "  Mode:   ${MODE}"
echo "  Agents: ${NUM_AGENTS}"
echo "  Model:  ${CLAUDE_MODEL}"
echo "  Prompt: ${SWARM_PROMPT}"
echo ""

# --- Crash-safe harvest ---------------------------------------------

# If the container is killed (docker stop, OOM, etc.) the
# bare repo on the volume still has all agent commits.
# This trap attempts a final harvest on any exit.
_HARVEST_DONE=false
_emergency_harvest() {
    if [ "$_HARVEST_DONE" = "true" ]; then
        return
    fi
    # Kill any remaining agent processes.
    # shellcheck disable=SC2046
    kill $(jobs -p) 2>/dev/null || true
    wait 2>/dev/null || true
    if [ -d "$BARE" ] && [ -d "$OUT_DIR/.git" ]; then
        echo ""
        echo "--- Emergency harvest (container exiting) ---"
        swarm_harvest "$OUT_DIR" "$BARE" || true
    fi
}
trap _emergency_harvest EXIT

# --- Claude runner --------------------------------------------------

_claude_runner() {
    local prompt_file="$1" workdir="$2" agent_id="$3"
    cd "$workdir"

    local full_prompt
    full_prompt="$(cat "$prompt_file")"
    if [ -n "${SWARM_COORDINATION_PROMPT:-}" ]; then
        full_prompt="${full_prompt}

${SWARM_COORDINATION_PROMPT}"
    fi

    local logdir="/output/logs/agent-${agent_id}"
    mkdir -p "$logdir"
    local logfile="${logdir}/session_$(date +%s).jsonl"

    local rc=0
    claude --dangerously-skip-permissions \
        -p "$full_prompt" \
        --model "$CLAUDE_MODEL" \
        --verbose \
        --output-format stream-json \
        > "$logfile" 2>"${logfile}.err" || rc=$?

    # Extract and log stats.
    local summary
    summary=$(grep '^{.*"type":"result"' "$logfile" \
        | tail -1 || true)
    if [ -n "$summary" ] \
        && echo "$summary" | jq -e . >/dev/null 2>&1
    then
        local cost tok_in tok_out dur turns
        cost=$(echo "$summary" \
            | jq -r '.total_cost_usd // 0')
        tok_in=$(echo "$summary" \
            | jq -r '.usage.input_tokens // 0')
        tok_out=$(echo "$summary" \
            | jq -r '.usage.output_tokens // 0')
        dur=$(echo "$summary" \
            | jq -r '.duration_ms // 0')
        turns=$(echo "$summary" \
            | jq -r '.num_turns // 0')
        swarm_record_stats "$agent_id" "$cost" \
            "$tok_in" "$tok_out" "$dur" "$turns"
        echo "[agent:${agent_id}]" \
            "cost=\$${cost}" \
            "tokens=${tok_in}/${tok_out}" \
            "turns=${turns}."
    fi

    # Check for errors.
    local is_err
    is_err=$(echo "$summary" \
        | jq -r '.is_error // false' 2>/dev/null \
        || echo "false")

    if [ "$is_err" = "true" ]; then
        local err_msg
        err_msg=$(echo "$summary" \
            | jq -r '.result // ""' 2>/dev/null \
            || true)
        echo "[agent:${agent_id}] ERROR: ${err_msg}"
        if echo "$err_msg" \
            | grep -qiE \
              "hit your limit|rate.limit|quota"; then
            return 2
        fi
        return 1
    fi

    case $rc in
        0) return 0 ;;
        *) return 1 ;;
    esac
}

# --- Repo setup per mode -------------------------------------------

setup_greenfield() {
    echo "--- Greenfield: creating empty project ---"
    mkdir -p "$OUT_DIR"
    cd "$OUT_DIR"
    git init
    git config user.name "${SWARM_GIT_USER:-swarm-agent}"
    git config user.email \
        "${SWARM_GIT_EMAIL:-agent@swarm.local}"
    git commit --allow-empty -m "Initial empty commit."

    # Copy prompt(s) into the repo.
    _copy_prompts
    git add -A
    git commit -m "Add task prompt."
}

setup_improve() {
    if [ -z "$REPO_URL" ]; then
        echo "ERROR: REPO_URL required for improve." >&2
        exit 1
    fi

    echo "--- Improve: cloning ${REPO_URL} ---"
    git clone "$REPO_URL" "$OUT_DIR"
    cd "$OUT_DIR"
    git config user.name "${SWARM_GIT_USER:-swarm-agent}"
    git config user.email \
        "${SWARM_GIT_EMAIL:-agent@swarm.local}"

    if [ -n "$BRANCH" ]; then
        git checkout "$BRANCH" 2>/dev/null \
            || git checkout -b "$BRANCH"
    fi

    _copy_prompts
    git add -A
    git diff --cached --quiet \
        || git commit -m "Add swarm task prompt."
}

setup_synthesize() {
    if [ -z "$REPO_URLS" ]; then
        echo "ERROR: REPO_URLS required for synthesize." >&2
        exit 1
    fi

    echo "--- Synthesize: cloning references ---"
    mkdir -p "$OUT_DIR"
    cd "$OUT_DIR"
    git init
    git config user.name "${SWARM_GIT_USER:-swarm-agent}"
    git config user.email \
        "${SWARM_GIT_EMAIL:-agent@swarm.local}"
    git commit --allow-empty -m "Initial empty commit."

    mkdir -p refs
    IFS=',' read -ra URLS <<< "$REPO_URLS"
    local ref_list=""
    for url in "${URLS[@]}"; do
        local name
        name="$(basename "$url" .git)"
        echo "  Cloning: ${url}"
        git clone --depth 1 "$url" "refs/${name}"
        rm -rf "refs/${name}/.git"
        ref_list="${ref_list}  - refs/${name}/\n"
    done

    printf "# Reference repositories\n\n" > refs/MANIFEST.md
    printf "Available as read-only in refs/:\n\n" \
        >> refs/MANIFEST.md
    # shellcheck disable=SC2059
    printf "$ref_list" >> refs/MANIFEST.md

    _copy_prompts
    git add -A
    git commit -m "Add references and task prompt."
}

# Copy the main prompt and any per-agent prompts into the
# repo under prompts/.
_copy_prompts() {
    mkdir -p prompts
    cp "$SWARM_PROMPT" "prompts/task.md"

    if [ -n "$AGENT_PROMPTS" ]; then
        IFS=',' read -ra AP <<< "$AGENT_PROMPTS"
        local idx=0
        for p in "${AP[@]}"; do
            idx=$((idx + 1))
            if [ -f "$p" ]; then
                cp "$p" "prompts/agent-${idx}.md"
                echo "  Prompt for agent ${idx}:" \
                    "$(basename "$p")"
            else
                echo "  WARNING: ${p} not found;" \
                    "agent ${idx} uses default prompt." >&2
            fi
        done
    fi
}

# Resolve which prompt file an agent should use.
# Per-agent prompt takes priority; falls back to task.md.
_agent_prompt() {
    local agent_id="$1"
    local per_agent="prompts/agent-${agent_id}.md"
    if [ -f "$per_agent" ]; then
        echo "$per_agent"
    else
        echo "prompts/task.md"
    fi
}

# --- Main -----------------------------------------------------------

# 1. Set up the project repo based on mode.
case "$MODE" in
    greenfield)  setup_greenfield ;;
    improve)     setup_improve ;;
    synthesize)  setup_synthesize ;;
    *)
        echo "ERROR: Unknown mode: ${MODE}" >&2
        echo "  Valid: greenfield, improve, synthesize" >&2
        exit 1
        ;;
esac

# 2. Run optional project setup script.
cd "$OUT_DIR"
if [ -n "$SWARM_SETUP" ] && [ -f "$SWARM_SETUP" ]; then
    echo "--- Running setup: ${SWARM_SETUP} ---"
    bash "$SWARM_SETUP"
fi

# Source PATH additions from setup (Rust, Go, etc.).
# shellcheck source=/dev/null
[ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"
export PATH="/usr/local/go/bin:$HOME/go/bin:${PATH}"

# 3. Create bare repo for coordination.
#    Stored on the volume (/output/bare) so agent work
#    survives container crashes.
echo "--- Initializing coordination repo ---"
swarm_init_repo "$OUT_DIR" "$BARE"

# 4. Launch N agents as parallel processes.
echo "--- Launching ${NUM_AGENTS} agents ---"
mkdir -p /output/logs

PIDS=()
for i in $(seq 1 "$NUM_AGENTS"); do
    WS="/tmp/swarm-agent-${i}"
    rm -rf "$WS"
    swarm_clone_workspace "$BARE" "$WS"

    AGENT_PROMPT=$(_agent_prompt "$i")
    (
        swarm_agent_loop _claude_runner "$AGENT_PROMPT" "$i"
    ) &
    PIDS+=($!)
    echo "  Agent ${i} started (pid $!," \
        "prompt=$(basename "$AGENT_PROMPT"))."
done

# 5. Wait for all agents to finish.
echo ""
echo "--- All agents running. Waiting for idle... ---"
FAILED=0
for pid in "${PIDS[@]}"; do
    wait "$pid" || FAILED=$((FAILED + 1))
done

# 6. Harvest results back into the project.
echo ""
echo "--- Harvesting results ---"
swarm_harvest "$OUT_DIR" "$BARE"
_HARVEST_DONE=true

echo ""
echo "=== Done ==="
echo "  Project: ${OUT_DIR}"
echo "  Logs:    /output/logs/"
echo "  Bare:    ${BARE}"
if [ "$FAILED" -gt 0 ]; then
    echo "  Warning: ${FAILED} agent(s) exited with errors."
fi
echo ""
echo "All agent work is persisted on the mounted volume."
echo "The bare repo at ${BARE} contains the full commit"
echo "history from all agents."
