#!/bin/bash
set -euo pipefail

# swarm-docker.sh — Launch one container per idea.
#
# One container = one substantial task. Inside, N claude
# agents run as parallel processes coordinating via git.
#
# Usage:
#
#   # Greenfield: build something from scratch.
#   ./swarm-docker.sh greenfield \
#       --prompt prompts/build-cli.md \
#       --agents 3 \
#       --out ./my-project
#
#   # Improve: modify an existing GitHub repo.
#   ./swarm-docker.sh improve \
#       --repo https://github.com/user/project \
#       --prompt prompts/add-tests.md \
#       --agents 4
#
#   # Synthesize: combine repos into a new project.
#   ./swarm-docker.sh synthesize \
#       --repos https://github.com/a/x,https://github.com/b/y \
#       --prompt prompts/unify.md \
#       --agents 5 \
#       --out ./unified
#
# The container exits when all agents idle. Results appear
# in --out (or a default directory).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="swarm-core"

# --- Parse arguments ------------------------------------------------

MODE=""
PROMPT=""
NUM_AGENTS=3
OUT_DIR=""
REPO_URL=""
REPO_URLS=""
BRANCH=""
MODEL="${CLAUDE_MODEL:-claude-sonnet-4-6}"
MAX_IDLE="${SWARM_MAX_IDLE:-3}"
SETUP_SCRIPT=""
DETACH=false
CONTAINER_NAME=""
AGENT_PROMPTS=""

usage() {
    cat <<'USAGE'
Usage: swarm-docker.sh MODE [OPTIONS]

Launch one Docker container for a substantial task. N
claude agents run inside as parallel processes.

Modes:
  greenfield    Build a new project from scratch.
  improve       Modify an existing GitHub repo.
  synthesize    Combine multiple repos into one project.

Options:
  --prompt FILE    Task prompt file (required).
  --agents N       Parallel agents inside container
                   (default: 3).
  --out DIR        Host directory for results
                   (default: ./swarm-out-<mode>).
  --repo URL       GitHub URL (improve mode).
  --repos A,B      Comma-separated URLs (synthesize).
  --branch NAME    Branch to work on (improve mode).
  --model NAME     Claude model (default: claude-sonnet-4-6).
  --max-idle N     Idle sessions before exit (default: 3).
  --setup FILE     Setup script to run inside container
                   before agents start.
  --agent-prompts  Comma-separated prompt files for
       A,B,C      per-agent assignment. Agent 1 gets A,
                   agent 2 gets B, etc. Extras use --prompt.
  --name NAME      Container name (default: auto).
  --detach         Run in background.

Environment:
  ANTHROPIC_API_KEY       Required.
  CLAUDE_CODE_OAUTH_TOKEN Alternative to API key.
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
        --prompt)   PROMPT="$2"; shift 2 ;;
        --agents)   NUM_AGENTS="$2"; shift 2 ;;
        --out)      OUT_DIR="$2"; shift 2 ;;
        --repo)     REPO_URL="$2"; shift 2 ;;
        --repos)    REPO_URLS="$2"; shift 2 ;;
        --branch)   BRANCH="$2"; shift 2 ;;
        --model)    MODEL="$2"; shift 2 ;;
        --max-idle) MAX_IDLE="$2"; shift 2 ;;
        --setup)    SETUP_SCRIPT="$2"; shift 2 ;;
        --agent-prompts) AGENT_PROMPTS="$2"; shift 2 ;;
        --name)     CONTAINER_NAME="$2"; shift 2 ;;
        --detach)   DETACH=true; shift ;;
        -h|--help)  usage ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            usage
            ;;
    esac
done

# --- Validate -------------------------------------------------------

if [ -z "$PROMPT" ]; then
    echo "ERROR: --prompt is required." >&2
    exit 1
fi

if [ ! -f "$PROMPT" ]; then
    echo "ERROR: Prompt file not found: ${PROMPT}" >&2
    exit 1
fi

case "$MODE" in
    greenfield|improve|synthesize) ;;
    *)
        echo "ERROR: Unknown mode: ${MODE}" >&2
        usage
        ;;
esac

if [ "$MODE" = "improve" ] && [ -z "$REPO_URL" ]; then
    echo "ERROR: --repo is required for improve mode." >&2
    exit 1
fi

if [ "$MODE" = "synthesize" ] && [ -z "$REPO_URLS" ]; then
    echo "ERROR: --repos is required for synthesize mode." >&2
    exit 1
fi

if [ -z "${ANTHROPIC_API_KEY:-}" ] \
    && [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    echo "ERROR: ANTHROPIC_API_KEY or" \
         "CLAUDE_CODE_OAUTH_TOKEN required." >&2
    exit 1
fi

# --- Defaults -------------------------------------------------------

if [ -z "$OUT_DIR" ]; then
    OUT_DIR="./swarm-out-${MODE}"
fi
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

if [ -z "$CONTAINER_NAME" ]; then
    CONTAINER_NAME="swarm-${MODE}-$$"
fi

# Resolve prompt to absolute path.
PROMPT="$(cd "$(dirname "$PROMPT")" && pwd)/$(basename "$PROMPT")"

# --- Build image if needed ------------------------------------------

if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    echo "--- Building ${IMAGE_NAME} image ---"
    docker build -t "$IMAGE_NAME" -f "${SCRIPT_DIR}/Dockerfile" \
        "$SCRIPT_DIR"
fi

# --- Assemble docker run command ------------------------------------

DOCKER_ARGS=(
    --name "$CONTAINER_NAME"
    --rm
    -v "${OUT_DIR}:/output:rw"
    -v "${PROMPT}:/prompt.md:ro"
    -e "MODE=${MODE}"
    -e "SWARM_PROMPT=/prompt.md"
    -e "NUM_AGENTS=${NUM_AGENTS}"
    -e "CLAUDE_MODEL=${MODEL}"
    -e "SWARM_MAX_IDLE=${MAX_IDLE}"
)

# Credentials.
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    DOCKER_ARGS+=(-e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}")
fi
if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    DOCKER_ARGS+=(-e "CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN}")
fi
if [ -n "${ANTHROPIC_BASE_URL:-}" ]; then
    DOCKER_ARGS+=(-e "ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL}")
fi

# Mode-specific env.
if [ -n "$REPO_URL" ]; then
    DOCKER_ARGS+=(-e "REPO_URL=${REPO_URL}")
fi
if [ -n "$REPO_URLS" ]; then
    DOCKER_ARGS+=(-e "REPO_URLS=${REPO_URLS}")
fi
if [ -n "$BRANCH" ]; then
    DOCKER_ARGS+=(-e "BRANCH=${BRANCH}")
fi

# Setup script: mount into container.
if [ -n "$SETUP_SCRIPT" ]; then
    if [ ! -f "$SETUP_SCRIPT" ]; then
        echo "ERROR: Setup script not found:" \
             "${SETUP_SCRIPT}" >&2
        exit 1
    fi
    SETUP_SCRIPT="$(cd "$(dirname "$SETUP_SCRIPT")" \
        && pwd)/$(basename "$SETUP_SCRIPT")"
    DOCKER_ARGS+=(
        -v "${SETUP_SCRIPT}:/setup.sh:ro"
        -e "SWARM_SETUP=/setup.sh"
    )
fi

# Per-agent prompts: mount each file and pass container
# paths via AGENT_PROMPTS env var.
if [ -n "$AGENT_PROMPTS" ]; then
    IFS=',' read -ra AP <<< "$AGENT_PROMPTS"
    CONTAINER_PATHS=()
    IDX=0
    for p in "${AP[@]}"; do
        IDX=$((IDX + 1))
        if [ ! -f "$p" ]; then
            echo "ERROR: Agent prompt not found: ${p}" >&2
            exit 1
        fi
        abs="$(cd "$(dirname "$p")" && pwd)/$(basename "$p")"
        cpath="/agent-prompts/agent-${IDX}.md"
        DOCKER_ARGS+=(-v "${abs}:${cpath}:ro")
        CONTAINER_PATHS+=("$cpath")
    done
    joined=$(IFS=','; echo "${CONTAINER_PATHS[*]}")
    DOCKER_ARGS+=(-e "AGENT_PROMPTS=${joined}")
fi

if [ "$DETACH" = "true" ]; then
    DOCKER_ARGS+=(-d)
fi

# --- Launch ---------------------------------------------------------

echo "=== Launching: ${CONTAINER_NAME} ==="
echo "  Mode:    ${MODE}"
echo "  Agents:  ${NUM_AGENTS}"
echo "  Model:   ${MODEL}"
echo "  Output:  ${OUT_DIR}"
echo ""

docker run "${DOCKER_ARGS[@]}" "$IMAGE_NAME"

if [ "$DETACH" = "true" ]; then
    echo ""
    echo "Container running in background."
    echo "  Logs:    docker logs -f ${CONTAINER_NAME}"
    echo "  Stop:    docker stop ${CONTAINER_NAME}"
    echo "  Results: ${OUT_DIR}/"
else
    echo ""
    echo "=== Container finished ==="
    echo "  Results: ${OUT_DIR}/project/"
    echo "  Logs:    ${OUT_DIR}/logs/"
fi
