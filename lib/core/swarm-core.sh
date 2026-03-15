#!/bin/bash
# swarm-core.sh — Generic multi-agent coordination library.
#
# Git-based, orchestrator-free coordination for N autonomous
# agents. Agent-runtime agnostic: works with any CLI tool
# that can read a prompt and write to a git repo.
#
# Usage:
#   source lib/core/swarm-core.sh
#   swarm_init_repo /path/to/project
#   swarm_agent_loop my_run_fn "prompts/task.md" 1
#
# The caller provides a run function:
#   my_run_fn(prompt_file, workdir, agent_id) → exit_code
#
# See lib/core/example.sh for a complete example.

set -euo pipefail

# --- Configuration defaults -----------------------------------------

SWARM_MAX_IDLE="${SWARM_MAX_IDLE:-3}"
SWARM_BRANCH="${SWARM_BRANCH:-agent-work}"
SWARM_GIT_USER="${SWARM_GIT_USER:-swarm-agent}"
SWARM_GIT_EMAIL="${SWARM_GIT_EMAIL:-agent@swarm.local}"
SWARM_STATS_DIR="${SWARM_STATS_DIR:-}"
SWARM_BACKOFF_INIT="${SWARM_BACKOFF_INIT:-300}"
SWARM_BACKOFF_CAP="${SWARM_BACKOFF_CAP:-1800}"
SWARM_INJECT_RULES="${SWARM_INJECT_RULES:-true}"
SWARM_COORDINATION_PROMPT=""

# --- Internal state -------------------------------------------------

_SWARM_BARE=""
_SWARM_WORKDIR=""
_SWARM_IDLE=0
_SWARM_BACKOFF="${SWARM_BACKOFF_INIT}"
_SWARM_AGENT_ID=""

# --- Core API -------------------------------------------------------

# Initialize a bare repo from a source repository.
# Creates the coordination branch if it does not exist.
#
# Args:
#   $1 — path to source repo (must be a git repo).
#   $2 — path for the bare repo (created if absent).
#
# Outputs:
#   Sets _SWARM_BARE to the bare repo path.
swarm_init_repo() {
    local src="$1" bare="$2"
    if [ ! -d "$src/.git" ] && ! git -C "$src" rev-parse --git-dir >/dev/null 2>&1; then
        echo "ERROR: ${src} is not a git repository." >&2
        return 1
    fi
    if [ -d "$bare" ]; then
        # Check for unharvested commits before overwriting.
        local bare_head
        bare_head=$(git -C "$bare" rev-parse \
            "refs/heads/${SWARM_BRANCH}" 2>/dev/null || true)
        if [ -n "$bare_head" ]; then
            if ! git -C "$src" cat-file -e "$bare_head" \
                2>/dev/null; then
                echo "ERROR: ${bare} has unharvested commits" \
                     "(${bare_head:0:7} not in source)." >&2
                return 1
            fi
            if ! git -C "$src" merge-base --is-ancestor \
                "$bare_head" HEAD 2>/dev/null; then
                echo "ERROR: ${bare} has unharvested commits" \
                     "(${bare_head:0:7} not ancestor of" \
                     "HEAD)." >&2
                return 1
            fi
        fi
        rm -rf "$bare"
    fi
    git clone --bare "$src" "$bare"
    git -C "$bare" branch "$SWARM_BRANCH" HEAD 2>/dev/null \
        || true
    git -C "$bare" symbolic-ref HEAD \
        "refs/heads/${SWARM_BRANCH}"
    _SWARM_BARE="$bare"
}

# Clone the bare repo into a workspace for an agent.
#
# Args:
#   $1 — bare repo path.
#   $2 — workspace path (created by git clone).
#
# Outputs:
#   Sets _SWARM_WORKDIR. Configures git user.
swarm_clone_workspace() {
    local bare="$1" workdir="$2"
    if [ -d "$workdir/.git" ]; then
        _SWARM_WORKDIR="$workdir"
        return 0
    fi
    git clone "$bare" "$workdir"
    cd "$workdir"
    git checkout "$SWARM_BRANCH"
    git config user.name "$SWARM_GIT_USER"
    git config user.email "$SWARM_GIT_EMAIL"
    _SWARM_WORKDIR="$workdir"
}

# Generate a coordination prompt for an agent.
# Reads the template from coordination.md and substitutes
# the agent ID and branch name.
#
# Args:
#   $1 — agent ID.
#
# Returns:
#   The prompt text on stdout.
swarm_coordination_prompt() {
    local agent_id="$1"
    local tmpl_dir
    tmpl_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local tmpl="${tmpl_dir}/coordination.md"
    if [ ! -f "$tmpl" ]; then
        echo "ERROR: ${tmpl} not found." >&2
        return 1
    fi
    sed -e "s/\${AGENT_ID}/${agent_id}/g" \
        -e "s/\${BRANCH}/${SWARM_BRANCH}/g" \
        "$tmpl"
}

# Run the main agent loop. Calls the user-provided run
# function repeatedly until the agent idles out.
#
# Args:
#   $1 — name of the run function
#         (called as: run_fn prompt workdir agent_id).
#   $2 — path to prompt file (relative to workspace root).
#   $3 — agent ID.
#   $4 — max idle sessions (optional, default SWARM_MAX_IDLE).
#
# The run function should return:
#   0   — success (session completed normally).
#   1   — non-fatal error (counts toward idle).
#   2   — rate limit (triggers backoff, does not count
#          toward idle).
#   3+  — fatal error (agent exits immediately).
swarm_agent_loop() {
    local run_fn="$1"
    local prompt="$2"
    local agent_id="$3"
    local max_idle="${4:-${SWARM_MAX_IDLE}}"

    _SWARM_AGENT_ID="$agent_id"
    _SWARM_IDLE=0
    _SWARM_BACKOFF="$SWARM_BACKOFF_INIT"

    if [ -z "$_SWARM_WORKDIR" ]; then
        echo "ERROR: call swarm_clone_workspace first." >&2
        return 1
    fi
    cd "$_SWARM_WORKDIR"

    # Optionally generate the coordination prompt once.
    if [ "$SWARM_INJECT_RULES" = "true" ]; then
        SWARM_COORDINATION_PROMPT=$(
            swarm_coordination_prompt "$agent_id"
        )
        export SWARM_COORDINATION_PROMPT
    fi

    _swarm_log "Starting (max_idle=${max_idle})."

    while true; do
        # Sync to latest.
        git fetch origin
        git reset --hard "origin/${SWARM_BRANCH}"

        local before
        before=$(git rev-parse "origin/${SWARM_BRANCH}")

        _swarm_log "Session at $(git rev-parse --short=6 HEAD)."

        # Call the user-provided run function.
        local rc=0
        "$run_fn" "$prompt" "$_SWARM_WORKDIR" "$agent_id" \
            || rc=$?

        # Handle return code.
        case $rc in
            0)
                _SWARM_BACKOFF="$SWARM_BACKOFF_INIT"
                ;;
            1)
                _swarm_log "Non-fatal error (rc=1)."
                _swarm_sleep 30
                ;;
            2)
                # Rate limit: backoff, do not count idle.
                local jitter=$((RANDOM % 60))
                _swarm_log "Rate limited; sleeping" \
                    "$((_SWARM_BACKOFF + jitter))s."
                _swarm_sleep $((_SWARM_BACKOFF + jitter))
                _SWARM_BACKOFF=$((_SWARM_BACKOFF * 2))
                if [ "$_SWARM_BACKOFF" -gt \
                    "$SWARM_BACKOFF_CAP" ]; then
                    _SWARM_BACKOFF="$SWARM_BACKOFF_CAP"
                fi
                continue
                ;;
            *)
                _swarm_log "Fatal error (rc=${rc}). Exiting."
                return "$rc"
                ;;
        esac

        # Check for new commits from any agent.
        git fetch origin
        local after
        after=$(git rev-parse "origin/${SWARM_BRANCH}")

        if [ "$before" = "$after" ]; then
            _SWARM_IDLE=$((_SWARM_IDLE + 1))
            _swarm_log "No commits (idle" \
                "${_SWARM_IDLE}/${max_idle})."
            if [ "$_SWARM_IDLE" -ge "$max_idle" ]; then
                _swarm_log "Idle limit. Exiting."
                return 0
            fi
        else
            _SWARM_IDLE=0
            _SWARM_BACKOFF="$SWARM_BACKOFF_INIT"
            _swarm_log "New commits detected. Restarting."
        fi
    done
}

# Merge the coordination branch into a target branch.
#
# Args:
#   $1 — path to the source repo (not bare).
#   $2 — bare repo path.
#   $3 — target branch (default: current branch).
swarm_harvest() {
    local repo="$1" bare="$2" target="${3:-}"
    cd "$repo"
    if [ -z "$target" ]; then
        target=$(git rev-parse --abbrev-ref HEAD)
    fi
    local remote_name="swarm-bare"
    git remote remove "$remote_name" 2>/dev/null || true
    git remote add "$remote_name" "$bare"
    git fetch "$remote_name" "$SWARM_BRANCH"
    local merge_head
    merge_head=$(git rev-parse "${remote_name}/${SWARM_BRANCH}")
    local base
    base=$(git merge-base HEAD "$merge_head" 2>/dev/null \
        || true)
    if [ "$merge_head" = "$base" ]; then
        _swarm_log "Nothing to harvest."
        git remote remove "$remote_name"
        return 0
    fi
    git merge --no-ff \
        -m "Merge swarm results from ${SWARM_BRANCH}" \
        "${remote_name}/${SWARM_BRANCH}"
    git remote remove "$remote_name"
    _swarm_log "Harvested into ${target}."
}

# Record a stats line (TSV) for a completed session.
#
# Args:
#   $1 — agent ID.
#   $2 — cost (USD, float).
#   $3 — input tokens.
#   $4 — output tokens.
#   $5 — duration (ms).
#   $6 — turns.
swarm_record_stats() {
    local agent_id="$1" cost="$2" tok_in="$3" \
        tok_out="$4" dur="$5" turns="$6"
    local dir="${SWARM_STATS_DIR:-/tmp}"
    local file="${dir}/stats_agent_${agent_id}.tsv"
    mkdir -p "$dir"
    printf "%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$(date +%s)" "$cost" "$tok_in" "$tok_out" \
        "$dur" "$turns" >> "$file"
}

# --- Internal helpers -----------------------------------------------

_swarm_log() {
    echo "[swarm:${_SWARM_AGENT_ID:-core}] $*"
}

# Signal-aware sleep. Responds to SIGTERM (e.g. from
# docker stop) instead of blocking until SIGKILL.
_swarm_sleep() {
    local secs="$1"
    trap 'exit 0' TERM INT
    sleep "$secs" &
    wait $! || true
    trap - TERM INT
}
