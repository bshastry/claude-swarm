#!/bin/bash
set -euo pipefail

# swarm-run.sh — High-level launcher for common use cases.
#
# Three modes:
#
#   greenfield  — Create a new project from scratch.
#   improve     — Clone a GitHub repo, make changes.
#   synthesize  — Clone multiple repos as references,
#                 build a new project from them.
#
# Usage:
#   ./swarm-run.sh greenfield \
#       --prompt prompts/build-cli.md \
#       --agents 3 \
#       --out /tmp/my-new-project
#
#   ./swarm-run.sh improve \
#       --repo https://github.com/user/project \
#       --prompt prompts/add-tests.md \
#       --agents 2
#
#   ./swarm-run.sh synthesize \
#       --repos https://github.com/a/auth,https://github.com/b/db \
#       --prompt prompts/build-unified-api.md \
#       --agents 4 \
#       --out /tmp/unified-api
#
# Requires:
#   - A run function defined in a file passed via --runner,
#     or defaults to the Claude Code runner.
#   - ANTHROPIC_API_KEY or equivalent for your agent.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=swarm-core.sh
source "${SCRIPT_DIR}/swarm-core.sh"

# --- Defaults -------------------------------------------------------

MODE=""
PROMPT=""
NUM_AGENTS=3
OUT_DIR=""
REPO_URL=""
REPO_URLS=""
RUNNER=""
BRANCH=""
MODEL="${CLAUDE_MODEL:-claude-sonnet-4-6}"

# --- Built-in runners -----------------------------------------------

# Default runner: Claude Code.
_builtin_claude_runner() {
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
        --model "$MODEL" \
        --verbose \
        2>/dev/null || rc=$?

    # Map common Claude exit codes to swarm conventions.
    case $rc in
        0) return 0 ;;
        2) return 2 ;;  # Rate limit.
        *) return 1 ;;  # Non-fatal.
    esac
}

# --- Parse arguments ------------------------------------------------

usage() {
    cat <<'USAGE'
Usage: swarm-run.sh MODE [OPTIONS]

Modes:
  greenfield   Create a new project from scratch.
  improve      Clone a GitHub repo and make changes.
  synthesize   Combine multiple repos into a new project.

Options:
  --prompt FILE    Task prompt (required).
  --agents N       Number of parallel agents (default: 3).
  --out DIR        Output directory (required for greenfield
                   and synthesize; defaults to cloned repo
                   for improve).
  --repo URL       GitHub repo URL (improve mode).
  --branch NAME    Branch to work on (improve mode,
                   default: repo default branch).
  --repos A,B,C    Comma-separated repo URLs (synthesize).
  --runner FILE    Bash file that defines a function called
                   run_agent(prompt, workdir, agent_id).
                   Defaults to built-in Claude Code runner.
  --model NAME     Model for built-in runner
                   (default: claude-sonnet-4-6).
  --max-idle N     Idle sessions before exit (default: 3).
USAGE
    exit 1
}

MODE="${1:-}"
shift || true

if [ -z "$MODE" ]; then
    usage
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --prompt)  PROMPT="$2"; shift 2 ;;
        --agents)  NUM_AGENTS="$2"; shift 2 ;;
        --out)     OUT_DIR="$2"; shift 2 ;;
        --repo)    REPO_URL="$2"; shift 2 ;;
        --branch)  BRANCH="$2"; shift 2 ;;
        --repos)   REPO_URLS="$2"; shift 2 ;;
        --runner)  RUNNER="$2"; shift 2 ;;
        --model)   MODEL="$2"; shift 2 ;;
        --max-idle) SWARM_MAX_IDLE="$2"; shift 2 ;;
        -h|--help) usage ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            usage
            ;;
    esac
done

if [ -z "$PROMPT" ]; then
    echo "ERROR: --prompt is required." >&2
    exit 1
fi

# Load custom runner or use built-in.
if [ -n "$RUNNER" ]; then
    # shellcheck source=/dev/null
    source "$RUNNER"
    RUN_FN="run_agent"
else
    RUN_FN="_builtin_claude_runner"
fi

# --- Mode: greenfield -----------------------------------------------

mode_greenfield() {
    if [ -z "$OUT_DIR" ]; then
        echo "ERROR: --out is required for greenfield." >&2
        exit 1
    fi

    echo "=== Greenfield: ${OUT_DIR} ==="

    # Create an empty git repo as the starting point.
    mkdir -p "$OUT_DIR"
    cd "$OUT_DIR"
    if [ ! -d .git ]; then
        git init
        git commit --allow-empty -m "Initial empty commit."
    fi

    # Copy prompt into the repo so agents can read it.
    local prompt_basename
    prompt_basename="$(basename "$PROMPT")"
    mkdir -p prompts
    cp "$PROMPT" "prompts/${prompt_basename}"
    git add -A
    git diff --cached --quiet \
        || git commit -m "Add task prompt."

    local bare="/tmp/swarm-greenfield-$(basename "$OUT_DIR")"
    swarm_init_repo "$OUT_DIR" "$bare"

    # Launch agents in parallel.
    local pids=()
    for i in $(seq 1 "$NUM_AGENTS"); do
        local ws="/tmp/swarm-gf-agent-${i}"
        rm -rf "$ws"
        swarm_clone_workspace "$bare" "$ws"
        (
            swarm_agent_loop "$RUN_FN" \
                "prompts/${prompt_basename}" "$i"
        ) &
        pids+=($!)
        echo "  Agent ${i} started (pid $!)."
    done

    echo "Waiting for ${#pids[@]} agents..."
    local failed=0
    for pid in "${pids[@]}"; do
        wait "$pid" || failed=$((failed + 1))
    done

    # Harvest results back into the project.
    swarm_harvest "$OUT_DIR" "$bare"
    rm -rf "$bare"

    echo "=== Done. Results in ${OUT_DIR} ==="
    if [ "$failed" -gt 0 ]; then
        echo "  (${failed} agent(s) exited with errors.)"
    fi
}

# --- Mode: improve --------------------------------------------------

mode_improve() {
    if [ -z "$REPO_URL" ]; then
        echo "ERROR: --repo is required for improve." >&2
        exit 1
    fi

    echo "=== Improve: ${REPO_URL} ==="

    # Clone the target repo.
    local repo_name
    repo_name="$(basename "$REPO_URL" .git)"
    local repo_dir="${OUT_DIR:-/tmp/swarm-improve-${repo_name}}"

    if [ ! -d "$repo_dir/.git" ]; then
        git clone "$REPO_URL" "$repo_dir"
    fi
    cd "$repo_dir"

    if [ -n "$BRANCH" ]; then
        git checkout "$BRANCH" 2>/dev/null \
            || git checkout -b "$BRANCH"
    fi

    # Copy prompt into the repo.
    local prompt_basename
    prompt_basename="$(basename "$PROMPT")"
    mkdir -p prompts
    cp "$PROMPT" "prompts/${prompt_basename}"
    git add -A
    git diff --cached --quiet \
        || git commit -m "Add swarm task prompt."

    local bare="/tmp/swarm-improve-${repo_name}-bare"
    swarm_init_repo "$repo_dir" "$bare"

    # Launch agents.
    local pids=()
    for i in $(seq 1 "$NUM_AGENTS"); do
        local ws="/tmp/swarm-imp-agent-${i}"
        rm -rf "$ws"
        swarm_clone_workspace "$bare" "$ws"
        (
            swarm_agent_loop "$RUN_FN" \
                "prompts/${prompt_basename}" "$i"
        ) &
        pids+=($!)
        echo "  Agent ${i} started (pid $!)."
    done

    echo "Waiting for ${#pids[@]} agents..."
    local failed=0
    for pid in "${pids[@]}"; do
        wait "$pid" || failed=$((failed + 1))
    done

    swarm_harvest "$repo_dir" "$bare"
    rm -rf "$bare"

    echo "=== Done. Results in ${repo_dir} ==="
    if [ "$failed" -gt 0 ]; then
        echo "  (${failed} agent(s) exited with errors.)"
    fi
}

# --- Mode: synthesize -----------------------------------------------

mode_synthesize() {
    if [ -z "$REPO_URLS" ]; then
        echo "ERROR: --repos is required for synthesize." >&2
        exit 1
    fi
    if [ -z "$OUT_DIR" ]; then
        echo "ERROR: --out is required for synthesize." >&2
        exit 1
    fi

    echo "=== Synthesize: ${OUT_DIR} ==="

    # Clone reference repos into a refs/ directory inside
    # the output project. Agents read these as context.
    mkdir -p "$OUT_DIR"
    cd "$OUT_DIR"
    if [ ! -d .git ]; then
        git init
        git commit --allow-empty -m "Initial empty commit."
    fi

    mkdir -p refs
    IFS=',' read -ra URLS <<< "$REPO_URLS"
    local ref_list=""
    for url in "${URLS[@]}"; do
        local name
        name="$(basename "$url" .git)"
        local ref_dir="refs/${name}"
        if [ ! -d "$ref_dir" ]; then
            echo "  Cloning reference: ${url} → ${ref_dir}"
            git clone --depth 1 "$url" "$ref_dir"
            # Remove .git from reference clones so they
            # become plain source trees in our repo.
            rm -rf "${ref_dir}/.git"
        fi
        ref_list="${ref_list}  - refs/${name}/\n"
    done

    # Generate a manifest so agents know what references
    # are available.
    printf "# Reference repositories\n\n" > refs/MANIFEST.md
    printf "The following source repositories are available " \
        >> refs/MANIFEST.md
    printf "as read-only references in refs/:\n\n" \
        >> refs/MANIFEST.md
    # shellcheck disable=SC2059
    printf "$ref_list" >> refs/MANIFEST.md

    # Copy prompt.
    local prompt_basename
    prompt_basename="$(basename "$PROMPT")"
    mkdir -p prompts
    cp "$PROMPT" "prompts/${prompt_basename}"

    git add -A
    git diff --cached --quiet \
        || git commit -m "Add references and task prompt."

    local bare="/tmp/swarm-synth-$(basename "$OUT_DIR")-bare"
    swarm_init_repo "$OUT_DIR" "$bare"

    # Launch agents.
    local pids=()
    for i in $(seq 1 "$NUM_AGENTS"); do
        local ws="/tmp/swarm-synth-agent-${i}"
        rm -rf "$ws"
        swarm_clone_workspace "$bare" "$ws"
        (
            swarm_agent_loop "$RUN_FN" \
                "prompts/${prompt_basename}" "$i"
        ) &
        pids+=($!)
        echo "  Agent ${i} started (pid $!)."
    done

    echo "Waiting for ${#pids[@]} agents..."
    local failed=0
    for pid in "${pids[@]}"; do
        wait "$pid" || failed=$((failed + 1))
    done

    swarm_harvest "$OUT_DIR" "$bare"
    rm -rf "$bare"

    echo "=== Done. Results in ${OUT_DIR} ==="
    if [ "$failed" -gt 0 ]; then
        echo "  (${failed} agent(s) exited with errors.)"
    fi
}

# --- Dispatch -------------------------------------------------------

case "$MODE" in
    greenfield)  mode_greenfield ;;
    improve)     mode_improve ;;
    synthesize)  mode_synthesize ;;
    -h|--help)   usage ;;
    *)
        echo "ERROR: Unknown mode: ${MODE}" >&2
        usage
        ;;
esac
