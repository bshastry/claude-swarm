#!/bin/bash
set -euo pipefail

# Create bare repos, build image, launch N agent containers.
# Usage: ./launch.sh {start|stop|logs N|status|wait|post-process}

REPO_ROOT="$(git rev-parse --show-toplevel)"
SWARM_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(basename "$REPO_ROOT")"
SWARM_RUN_HASH="$(git -C "$REPO_ROOT" rev-parse --short=7 HEAD 2>/dev/null || echo "unknown")"
SWARM_RUN_BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
SWARM_RUN_CONTEXT="${PROJECT}@${SWARM_RUN_HASH} (${SWARM_RUN_BRANCH})"
SWARM_DATA_DIR="${SWARM_DATA_DIR:-${REPO_ROOT}/.swarm}"
BARE_REPO="${SWARM_DATA_DIR}/bare"
IMAGE_NAME="${PROJECT}-agent"

# Populate _CRED_ENV with -e flags for Docker credential
# injection. Caller copies the result after invocation.
# Compatible with bash 3.2+ (no nameref).
_CRED_ENV=()
build_cred_env() {
    local auth=$1 api_key=$2 base_url=${3:-}
    _CRED_ENV=()
    case "$auth" in
        oauth)
            [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] \
                && _CRED_ENV+=(-e \
                    "CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN}")
            ;;
        apikey)
            local resolved="${api_key:-${ANTHROPIC_API_KEY:-}}"
            [ -n "$resolved" ] \
                && _CRED_ENV+=(-e "ANTHROPIC_API_KEY=${resolved}")
            ;;
        *)
            local resolved="${api_key:-${ANTHROPIC_API_KEY:-}}"
            [ -n "$resolved" ] \
                && _CRED_ENV+=(-e "ANTHROPIC_API_KEY=${resolved}")
            [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] \
                && _CRED_ENV+=(-e \
                    "CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN}")
            ;;
    esac
    if [ -n "$base_url" ]; then
        _CRED_ENV+=(-e "ANTHROPIC_BASE_URL=${base_url}")
    elif [ -n "${ANTHROPIC_BASE_URL:-}" ]; then
        _CRED_ENV+=(-e "ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL}")
    fi
    [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ] \
        && _CRED_ENV+=(-e "ANTHROPIC_AUTH_TOKEN=${ANTHROPIC_AUTH_TOKEN}")
    return 0
}

# Docker containers may create files owned by a different UID inside
# bind-mounted host directories.  Plain rm -rf fails without root.
# Use a throwaway Alpine container (Docker is already required) so
# we never need sudo/su -c.
rm_docker_dir() {
    local dir="$1"
    # Guard against empty or root paths.
    if [ -z "$dir" ] || [ "$dir" = "/" ]; then
        echo "ERROR: rm_docker_dir called with" \
             "unsafe path: '${dir}'" >&2
        return 1
    fi
    [ -d "$dir" ] || return 0
    local parent base
    parent="$(dirname "$dir")"
    base="$(basename "$dir")"
    docker run --rm -v "${parent}:${parent}" alpine \
        rm -rf "${parent}/${base}" 2>/dev/null \
        || rm -rf "$dir" 2>/dev/null || true
}

CONFIG_FILE="${SWARM_CONFIG:-}"
if [ -z "$CONFIG_FILE" ] && [ -f "$REPO_ROOT/swarm.json" ]; then
    CONFIG_FILE="$REPO_ROOT/swarm.json"
fi

if [ -n "$CONFIG_FILE" ]; then
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "ERROR: Config file ${CONFIG_FILE} not found." >&2
        exit 1
    fi
    if ! command -v jq &>/dev/null; then
        echo "ERROR: jq is required to parse config files." >&2
        exit 1
    fi
    SWARM_PROMPT=$(jq -r '.prompt // empty' "$CONFIG_FILE")
    SWARM_SETUP=$(jq -r '.setup // empty' "$CONFIG_FILE")
    MAX_IDLE=$(jq -r '.max_idle // 3' "$CONFIG_FILE")
    INJECT_GIT_RULES=$(jq -r 'if has("inject_git_rules") then .inject_git_rules else true end' "$CONFIG_FILE")
    GIT_USER_NAME=$(jq -r '.git_user.name // "swarm-agent"' "$CONFIG_FILE")
    GIT_USER_EMAIL=$(jq -r '.git_user.email // "agent@claude-swarm.local"' "$CONFIG_FILE")
    DOCKER_SOCKET=$(jq -r 'if .docker_socket then "true" else "false" end' "$CONFIG_FILE")
    NUM_AGENTS=$(jq '[.agents[].count] | add' "$CONFIG_FILE")
    # Parse generic env vars from config (if present).
    CUSTOM_ENV_ARGS=()
    while IFS='=' read -r key value; do
        [ -n "$key" ] && CUSTOM_ENV_ARGS+=(-e "${key}=${value}")
    done < <(jq -r '.env // {} | to_entries[] | "\(.key)=\(.value)"' "$CONFIG_FILE")
    # Parse custom volume mounts from config (if present).
    # Format: "host_path:container_path[:mode]" where
    # host_path is relative to repo root or absolute.
    CUSTOM_VOL_ARGS=()
    while IFS= read -r vol_spec; do
        [ -z "$vol_spec" ] && continue
        IFS=: read -r _vol_host _vol_container _vol_mode \
            <<< "$vol_spec"
        # Reject specs missing the container path.
        if [ -z "$_vol_container" ]; then
            echo "WARNING: malformed volume spec" \
                "'${vol_spec}'; skipped." >&2
            continue
        fi
        # Resolve relative host paths to repo root.
        if [[ "$_vol_host" != /* ]]; then
            _vol_host="${REPO_ROOT}/${_vol_host}"
        fi
        if [ -d "$_vol_host" ]; then
            CUSTOM_VOL_ARGS+=(-v "${_vol_host}:${_vol_container}:${_vol_mode:-ro}")
            echo "Volume: ${_vol_host} -> ${_vol_container} (${_vol_mode:-ro})"
        else
            echo "WARNING: volume source ${_vol_host}" \
                "not found; skipped." >&2
        fi
    done < <(jq -r '.volumes // [] | .[]' "$CONFIG_FILE")
else
    NUM_AGENTS="${SWARM_NUM_AGENTS:-3}"
    CLAUDE_MODEL="${SWARM_MODEL:-claude-opus-4-6}"
    SWARM_PROMPT="${SWARM_PROMPT:-}"
    SWARM_SETUP="${SWARM_SETUP:-}"
    MAX_IDLE="${SWARM_MAX_IDLE:-3}"
    INJECT_GIT_RULES="${SWARM_INJECT_GIT_RULES:-true}"
    GIT_USER_NAME="${SWARM_GIT_USER_NAME:-swarm-agent}"
    GIT_USER_EMAIL="${SWARM_GIT_USER_EMAIL:-agent@claude-swarm.local}"
    DOCKER_SOCKET="false"
    EFFORT_LEVEL="${SWARM_EFFORT:-}"
    CUSTOM_ENV_ARGS=()
    CUSTOM_VOL_ARGS=()
fi

cmd_start() {
    if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -z "$CONFIG_FILE" ]; then
        echo "ERROR: ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN must be set." >&2
        exit 1
    fi

    if ! command -v docker &>/dev/null; then
        echo "ERROR: docker is not installed." >&2
        exit 1
    fi

    if [ -z "$SWARM_PROMPT" ]; then
        if [ -n "$CONFIG_FILE" ]; then
            echo "ERROR: 'prompt' is missing in ${CONFIG_FILE}." >&2
        else
            echo "ERROR: SWARM_PROMPT is not set." >&2
        fi
        exit 1
    fi

    if [ ! -f "$REPO_ROOT/$SWARM_PROMPT" ]; then
        echo "ERROR: ${SWARM_PROMPT} not found." >&2
        exit 1
    fi

    # Refuse to overwrite a bare repo that has unharvested commits.
    # Use ancestry, not SHA equality: safe to overwrite only if
    # agent-work exists in the local object store AND is already
    # an ancestor of local HEAD (meaning harvest.sh pulled it in).
    # SHAs differ after new local commits on top of the harvest.
    if [ -d "$BARE_REPO" ]; then
        BARE_HEAD=$(git -C "$BARE_REPO" rev-parse refs/heads/agent-work 2>/dev/null || true)
        if [ -n "$BARE_HEAD" ]; then
            if ! git cat-file -e "$BARE_HEAD" 2>/dev/null; then
                echo "ERROR: ${BARE_REPO} has unharvested agent commits" \
                     "(commit ${BARE_HEAD:0:7} not found locally)." >&2
                echo "       Run harvest.sh first, or remove it manually:" >&2
                echo "       rm -rf ${BARE_REPO}" >&2
                exit 1
            fi
            if ! git merge-base --is-ancestor "$BARE_HEAD" HEAD 2>/dev/null; then
                echo "ERROR: ${BARE_REPO} has unharvested agent commits" \
                     "(${BARE_HEAD:0:7} is not an ancestor of HEAD)." >&2
                echo "       Run harvest.sh first, or remove it manually:" >&2
                echo "       rm -rf ${BARE_REPO}" >&2
                exit 1
            fi
        fi
    fi

    mkdir -p "$SWARM_DATA_DIR"

    echo "--- Creating bare repo ---"
    rm_docker_dir "$BARE_REPO"
    git clone --bare "$REPO_ROOT" "$BARE_REPO"

    git -C "$BARE_REPO" branch agent-work HEAD 2>/dev/null || true
    git -C "$BARE_REPO" symbolic-ref HEAD refs/heads/agent-work

    # Mirror each submodule so containers can init without network.
    cd "$REPO_ROOT"
    git submodule foreach --quiet 'echo "$name|$toplevel/.git/modules/$sm_path"' | \
    while IFS='|' read -r name gitdir; do
        safe_name="${name//\//_}"
        mirror="/tmp/${PROJECT}-mirror-${safe_name}.git"
        rm -rf "$mirror"
        echo "--- Mirroring submodule: ${name} ---"
        git clone --bare "$gitdir" "$mirror"
    done

    echo "--- Building agent image ---"
    docker build -t "$IMAGE_NAME" -f "$SWARM_DIR/Dockerfile" "$SWARM_DIR"

    # -- Auth smoke test ----------------------------------
    # Run a throwaway container to verify credentials work
    # before launching agents and running 10-min setup.
    local SKIP_SMOKE="${SWARM_SKIP_SMOKE:-false}"
    if [ "$SKIP_SMOKE" != "true" ]; then
        echo "--- Auth smoke test ---"
        local smoke_auth="" smoke_api_key="" smoke_base_url=""
        if [ -n "$CONFIG_FILE" ]; then
            smoke_auth=$(jq -r \
                '.agents[0].auth // ""' "$CONFIG_FILE")
            smoke_api_key=$(jq -r \
                '.agents[0].api_key // ""' "$CONFIG_FILE")
            smoke_base_url=$(jq -r \
                '.agents[0].base_url // ""' "$CONFIG_FILE")
        fi
        if [ -z "$smoke_auth" ] && [ -n "$smoke_api_key" ]; then
            smoke_auth="apikey"
        fi

        build_cred_env "$smoke_auth" "$smoke_api_key" \
            "$smoke_base_url"
        local SMOKE_CRED=("${_CRED_ENV[@]+"${_CRED_ENV[@]}"}")

        local smoke_json="/tmp/${PROJECT}-smoke.json"
        local smoke_err="/tmp/${PROJECT}-smoke.err"
        # shellcheck disable=SC2317
        _smoke_cleanup() {
            rm -f "$smoke_json" "$smoke_err"
        }
        trap _smoke_cleanup RETURN

        local SMOKE_RC=0
        timeout 60 docker run --rm \
            --entrypoint claude \
            "${SMOKE_CRED[@]+"${SMOKE_CRED[@]}"}" \
            "$IMAGE_NAME" \
            --dangerously-skip-permissions \
            -p "respond with the single word: ok" \
            --max-turns 1 \
            --output-format json \
            > "$smoke_json" \
            2>"$smoke_err" \
        || SMOKE_RC=$?

        if [ "$SMOKE_RC" -eq 124 ]; then
            echo "ERROR: Auth smoke test timed out (60s)." >&2
            cat "$smoke_err" >&2
            exit 1
        fi

        if [ "$SMOKE_RC" -ne 0 ]; then
            echo "ERROR: Auth smoke test exited with" \
                 "code ${SMOKE_RC}." >&2
            cat "$smoke_err" >&2
            exit 1
        fi

        if jq -e '.is_error == true' "$smoke_json" \
            >/dev/null 2>&1; then
            echo "ERROR: Auth smoke test failed." >&2
            jq -r '.result' "$smoke_json" >&2
            exit 1
        fi

        echo "--- Auth smoke test passed ---"
    fi

    # Build mirror volume args from discovered submodules.
    git submodule foreach --quiet 'echo "$name"' | while read -r name; do
        safe_name="${name//\//_}"
        mirror="/tmp/${PROJECT}-mirror-${safe_name}.git"
        echo "-v ${mirror}:/mirrors/${name}:ro"
    done > "/tmp/${PROJECT}-mirror-vols.txt"

    # Build per-agent config (model|base_url|api_key|effort|auth|prompt|delay per line).
    # Uses pipe delimiter because bash IFS=$'\t' collapses consecutive tabs.
    AGENTS_CFG="/tmp/${PROJECT}-agents.cfg"
    if [ -n "$CONFIG_FILE" ]; then
        jq -r '.agents[] | range(.count) as $i |
            [.model, (.base_url // ""), (.api_key // ""),
             (.effort // ""), (.auth // ""),
             (.prompt // ""), (.delay // 0 | tostring)
            ] | join("|")' \
            "$CONFIG_FILE" > "$AGENTS_CFG"
    else
        : > "$AGENTS_CFG"
        for _i in $(seq 1 "$NUM_AGENTS"); do
            printf '%s|||%s|||0\n' "$CLAUDE_MODEL" "${EFFORT_LEVEL:-}" >> "$AGENTS_CFG"
        done
    fi

    # Read mirror volume mounts (shared across all containers).
    MIRROR_ARGS=()
    while read -r line; do
        # shellcheck disable=SC2206
        MIRROR_ARGS+=($line)
    done < "/tmp/${PROJECT}-mirror-vols.txt"

    # Mount Docker socket when config requests it (for Kurtosis).
    # --group-add: match host socket GID so agent user can access.
    # --network host: Kurtosis publishes ports on 127.0.0.1;
    #   bridge-networked containers cannot reach them.
    # Note: stat -c is GNU coreutils (Linux-only, not macOS).
    DOCKER_SOCK_ARGS=()
    if [ "$DOCKER_SOCKET" = "true" ]; then
        DOCKER_SOCK_ARGS+=(-v "/var/run/docker.sock:/var/run/docker.sock")
        DOCKER_SOCK_ARGS+=(--network host)
        if [ -S /var/run/docker.sock ]; then
            local sock_gid
            sock_gid=$(stat -c '%g' /var/run/docker.sock)
            DOCKER_SOCK_ARGS+=(--group-add "$sock_gid")
        else
            echo "WARNING: docker_socket=true but" \
                "/var/run/docker.sock not found;" \
                "--group-add skipped." >&2
        fi
    fi

    AGENT_IDX=0
    while IFS='|' read -r agent_model agent_base_url agent_api_key agent_effort agent_auth agent_prompt agent_delay; do
        AGENT_IDX=$((AGENT_IDX + 1))

        # Default delay to 0; guard sleep under set -e.
        # NOTE: sleep is BLOCKING — launch.sh will not
        # return until the delay completes. This is
        # intentional: Sonnet must be the last agent in
        # the config. Callers should background launch.sh
        # if they need immediate control (run.sh does this).
        agent_delay="${agent_delay:-0}"
        if [ "$agent_delay" -gt 0 ] 2>/dev/null; then
            echo "  Delaying ${agent_delay}s before" \
                "launch..."
            sleep "$agent_delay"
        fi

        # Per-agent prompt (falls back to top-level).
        local agent_swarm_prompt="${agent_prompt:-${SWARM_PROMPT}}"
        if [ -n "$agent_prompt" ] \
            && [ ! -f "$REPO_ROOT/$agent_prompt" ]; then
            echo "WARNING: agent prompt" \
                "${agent_prompt} not found;" \
                "using top-level prompt." >&2
            agent_swarm_prompt="$SWARM_PROMPT"
        fi

        AGENT_LOG_DIR="${SWARM_DATA_DIR}/logs/agent-${AGENT_IDX}"
        mkdir -p "$AGENT_LOG_DIR"
        NAME="${IMAGE_NAME}-${AGENT_IDX}"
        docker rm -f "$NAME" 2>/dev/null || true

        echo "--- Launching ${NAME} (${agent_model}${agent_effort:+ effort=${agent_effort}}${agent_auth:+ auth=${agent_auth}}) ---"
        # Auto-tag agents with a custom api_key as "apikey".
        if [ -z "$agent_auth" ] && [ -n "$agent_api_key" ]; then
            agent_auth="apikey"
        fi

        build_cred_env "$agent_auth" "$agent_api_key" \
            "$agent_base_url"
        local AGENT_CRED=("${_CRED_ENV[@]+"${_CRED_ENV[@]}"}")

        local EXTRA_ENV=()
        local eff="${agent_effort:-${EFFORT_LEVEL:-}}"
        [ -n "$eff" ] \
            && EXTRA_ENV+=(-e "CLAUDE_CODE_EFFORT_LEVEL=${eff}")

        docker run -d \
            --name "$NAME" \
            -v "${BARE_REPO}:/upstream:rw" \
            -v "${AGENT_LOG_DIR}:/agent_logs" \
            "${MIRROR_ARGS[@]+"${MIRROR_ARGS[@]}"}" \
            "${DOCKER_SOCK_ARGS[@]+"${DOCKER_SOCK_ARGS[@]}"}" \
            "${CUSTOM_VOL_ARGS[@]+"${CUSTOM_VOL_ARGS[@]}"}" \
            "${AGENT_CRED[@]+"${AGENT_CRED[@]}"}" \
            "${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}" \
            "${CUSTOM_ENV_ARGS[@]+"${CUSTOM_ENV_ARGS[@]}"}" \
            -e "CLAUDE_MODEL=${agent_model}" \
            -e "SWARM_PROMPT=${agent_swarm_prompt}" \
            -e "SWARM_SETUP=${SWARM_SETUP}" \
            -e "MAX_IDLE=${MAX_IDLE}" \
            -e "GIT_USER_NAME=${GIT_USER_NAME}" \
            -e "GIT_USER_EMAIL=${GIT_USER_EMAIL}" \
            -e "INJECT_GIT_RULES=${INJECT_GIT_RULES}" \
            -e "AGENT_ID=${AGENT_IDX}" \
            -e "SWARM_AUTH_MODE=${agent_auth}" \
            -e "SWARM_RUN_CONTEXT=${SWARM_RUN_CONTEXT}" \
            -e "SWARM_CFG_PROMPT=${agent_swarm_prompt}" \
            -e "SWARM_CFG_SETUP=${SWARM_SETUP}" \
            "$IMAGE_NAME"
    done < "$AGENTS_CFG"

    rm -f "/tmp/${PROJECT}-mirror-vols.txt" "/tmp/${PROJECT}-agents.cfg"

    # Write state file so a standalone dashboard can pick up config.
    local state_model_summary state_config_label
    if [ -n "$CONFIG_FILE" ]; then
        state_model_summary=$(jq -r \
            '[.agents[] | "\(.count)x \(.model | split("/") | .[-1])"] | join(", ")' \
            "$CONFIG_FILE")
        state_config_label=$(basename "$CONFIG_FILE")
    else
        state_model_summary="${NUM_AGENTS}x ${CLAUDE_MODEL}"
        state_config_label="env vars"
    fi
    cat > "/tmp/${PROJECT}-swarm.env" <<ENVEOF
SWARM_TITLE="${SWARM_TITLE:-}"
SWARM_PROMPT="${SWARM_PROMPT}"
SWARM_NUM_AGENTS="${NUM_AGENTS}"
SWARM_MODEL_SUMMARY="${state_model_summary}"
SWARM_CONFIG_LABEL="${state_config_label}"
ENVEOF

    echo ""
    echo "--- ${NUM_AGENTS} agents launched ---"
    echo ""
    echo "Monitor:"
    echo "  $0 status"
    echo "  $0 logs 1"
    echo ""
    echo "Stop:"
    echo "  $0 stop"
    echo ""
    echo "Bare repo: ${BARE_REPO}"
}

cmd_stop() {
    echo "--- Stopping agents ---"
    for i in $(seq 1 "$NUM_AGENTS"); do
        NAME="${IMAGE_NAME}-${i}"
        docker stop "$NAME" 2>/dev/null && echo "  stopped ${NAME}" \
            || echo "  ${NAME} not running"
    done
    rm -f "/tmp/${PROJECT}-swarm.env"
}

cmd_logs() {
    local n="${1:-1}"
    docker logs -f "${IMAGE_NAME}-${n}"
}

cmd_status() {
    for i in $(seq 1 "$NUM_AGENTS"); do
        NAME="${IMAGE_NAME}-${i}"
        printf "%-30s " "${NAME}:"
        docker inspect -f '{{.State.Status}}' "$NAME" 2>/dev/null \
            || echo "not found"
    done
}

cmd_wait() {
    echo "--- Waiting for all agents to finish ---"

    while true; do
        sleep 10
        local all_done=true running=0 exited=0
        for i in $(seq 1 "$NUM_AGENTS"); do
            local state
            state=$(docker inspect -f '{{.State.Status}}' "${IMAGE_NAME}-${i}" 2>/dev/null || echo "not found")
            case "$state" in
                running) running=$((running + 1)); all_done=false ;;
                exited)  exited=$((exited + 1)) ;;
            esac
        done

        printf "\r  %d running, %d exited " "$running" "$exited"

        if $all_done; then
            echo ""
            echo "All agents finished."
            break
        fi
    done

    if [ -n "$CONFIG_FILE" ]; then
        local pp_prompt
        pp_prompt=$(jq -r '.post_process.prompt // empty' "$CONFIG_FILE")
        if [ -n "$pp_prompt" ]; then
            echo ""
            cmd_post_process
            return
        fi
    fi

    echo ""
    echo "--- Harvesting results ---"
    "$SWARM_DIR/harvest.sh"
}

cmd_post_process() {
    if [ -z "$CONFIG_FILE" ]; then
        echo "ERROR: post-process requires a config file with a post_process section." >&2
        exit 1
    fi

    local pp_prompt pp_model pp_base_url pp_api_key pp_effort pp_auth
    pp_prompt=$(jq -r '.post_process.prompt // empty' "$CONFIG_FILE")
    pp_model=$(jq -r '.post_process.model // "claude-opus-4-6"' "$CONFIG_FILE")
    pp_base_url=$(jq -r '.post_process.base_url // empty' "$CONFIG_FILE")
    pp_api_key=$(jq -r '.post_process.api_key // empty' "$CONFIG_FILE")
    pp_effort=$(jq -r '.post_process.effort // empty' "$CONFIG_FILE")
    pp_auth=$(jq -r '.post_process.auth // empty' "$CONFIG_FILE")

    if [ -z "$pp_prompt" ]; then
        echo "ERROR: post_process.prompt is not set in ${CONFIG_FILE}." >&2
        exit 1
    fi

    if [ ! -d "$BARE_REPO" ]; then
        echo "ERROR: ${BARE_REPO} not found." >&2
        exit 1
    fi

    local NAME="${IMAGE_NAME}-post"
    docker rm -f "$NAME" 2>/dev/null || true

    # Build mirror volume args from existing mirrors.
    local MIRROR_ARGS=()
    cd "$REPO_ROOT"
    git submodule foreach --quiet 'echo "$name"' 2>/dev/null | while read -r name; do
        local safe_name="${name//\//_}"
        local mirror="/tmp/${PROJECT}-mirror-${safe_name}.git"
        if [ -d "$mirror" ]; then
            echo "-v ${mirror}:/mirrors/${name}:ro"
        fi
    done > "/tmp/${PROJECT}-pp-vols.txt"
    while read -r line; do
        # shellcheck disable=SC2206
        MIRROR_ARGS+=($line)
    done < "/tmp/${PROJECT}-pp-vols.txt"
    rm -f "/tmp/${PROJECT}-pp-vols.txt"

    if [ -z "$pp_auth" ] && [ -n "$pp_api_key" ]; then
        pp_auth="apikey"
    fi

    build_cred_env "$pp_auth" "$pp_api_key" "$pp_base_url"
    local PP_CRED=("${_CRED_ENV[@]+"${_CRED_ENV[@]}"}")

    local EXTRA_ENV=()
    [ -n "$pp_effort" ] \
        && EXTRA_ENV+=(-e "CLAUDE_CODE_EFFORT_LEVEL=${pp_effort}")

    # Mount Docker socket when config requests it (for Kurtosis).
    local DOCKER_SOCK_ARGS=()
    if [ "$DOCKER_SOCKET" = "true" ]; then
        DOCKER_SOCK_ARGS+=(-v "/var/run/docker.sock:/var/run/docker.sock")
        DOCKER_SOCK_ARGS+=(--network host)
        if [ -S /var/run/docker.sock ]; then
            local sock_gid
            sock_gid=$(stat -c '%g' /var/run/docker.sock)
            DOCKER_SOCK_ARGS+=(--group-add "$sock_gid")
        else
            echo "WARNING: docker_socket=true but" \
                "/var/run/docker.sock not found;" \
                "--group-add skipped." >&2
        fi
    fi

    PP_LOG_DIR="${SWARM_DATA_DIR}/logs/agent-post"
    mkdir -p "$PP_LOG_DIR"

    echo "--- Starting post-processing (${pp_model}) ---"
    docker run -d \
        --name "$NAME" \
        -v "${BARE_REPO}:/upstream:rw" \
        -v "${PP_LOG_DIR}:/agent_logs" \
        "${MIRROR_ARGS[@]+"${MIRROR_ARGS[@]}"}" \
        "${DOCKER_SOCK_ARGS[@]+"${DOCKER_SOCK_ARGS[@]}"}" \
        "${CUSTOM_VOL_ARGS[@]+"${CUSTOM_VOL_ARGS[@]}"}" \
        "${PP_CRED[@]+"${PP_CRED[@]}"}" \
        "${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}" \
        "${CUSTOM_ENV_ARGS[@]+"${CUSTOM_ENV_ARGS[@]}"}" \
        -e "CLAUDE_MODEL=${pp_model}" \
        -e "SWARM_PROMPT=${pp_prompt}" \
        -e "SWARM_SETUP=${SWARM_SETUP:-}" \
        -e "MAX_IDLE=${MAX_IDLE}" \
        -e "GIT_USER_NAME=${GIT_USER_NAME}" \
        -e "GIT_USER_EMAIL=${GIT_USER_EMAIL}" \
        -e "INJECT_GIT_RULES=${INJECT_GIT_RULES}" \
        -e "AGENT_ID=post" \
        -e "SWARM_AUTH_MODE=${pp_auth}" \
        -e "SWARM_RUN_CONTEXT=${SWARM_RUN_CONTEXT}" \
        -e "SWARM_CFG_PROMPT=${pp_prompt}" \
        -e "SWARM_CFG_SETUP=${SWARM_SETUP:-}" \
        "$IMAGE_NAME"

    echo "Post-processing agent launched: ${NAME}"
    echo "Waiting for completion..."

    while true; do
        sleep 10
        local state
        state=$(docker inspect -f '{{.State.Status}}' "$NAME" 2>/dev/null || echo "not found")
        if [ "$state" = "running" ]; then
            printf "."
            continue
        fi
        echo ""
        echo "Post-processing agent finished (${state})."
        break
    done

    echo ""
    echo "--- Harvesting results ---"
    "$SWARM_DIR/harvest.sh"
}

cmd_clean() {
    local mode="${1:-}"
    if [ "$mode" = "--all" ]; then
        echo "--- Removing ${SWARM_DATA_DIR} ---"
        rm_docker_dir "$SWARM_DATA_DIR"
    else
        echo "--- Cleaning logs (preserving bare repo) ---"
        rm_docker_dir "${SWARM_DATA_DIR}/logs"
    fi
    # Clean up legacy /tmp mirrors.
    rm -f "/tmp/${PROJECT}-swarm.env"
    rm -f "/tmp/${PROJECT}-mirror-vols.txt"
    rm -f "/tmp/${PROJECT}-agents.cfg"
    echo "Done."
}

cmd_help() {
    cat <<HELP
Usage: $0 COMMAND [OPTIONS]

Orchestrate Claude Code agents in Docker containers.

Commands:
  start [--dashboard]  Build image, create bare repo, launch agents.
                       With --dashboard, open the TUI after launch.
  stop                 Stop all running agent containers.
  logs N               Tail logs for agent N (default: 1).
  status               Show running/stopped state for each agent.
  wait                 Block until all agents exit, then harvest.
  post-process         Run the post-processing agent from the config.
  clean            Remove session logs from .swarm/logs/.
  clean --all      Remove entire .swarm/ directory.

Environment:
  ANTHROPIC_API_KEY         API key (required unless OAuth token or config).
  CLAUDE_CODE_OAUTH_TOKEN   OAuth token for subscription-based auth.
  SWARM_CONFIG              Path to swarm.json config file.
  SWARM_PROMPT              Prompt file path (env-var mode).
  SWARM_MODEL               Model name (default: claude-opus-4-6).
  SWARM_NUM_AGENTS          Agent count (default: 3).
  SWARM_MAX_IDLE            Idle sessions before exit (default: 3).
  SWARM_EFFORT              Reasoning effort: low, medium, high.
  SWARM_TITLE               Dashboard title override.
  SWARM_DATA_DIR            Persistent data dir (default: $REPO/.swarm).
  SWARM_SKIP_SMOKE          Skip auth smoke test (default: false).
HELP
}

case "${1:-start}" in
    -h|--help)     cmd_help ;;
    start)
        cmd_start
        if [ "${2:-}" = "--dashboard" ]; then
            exec "$SWARM_DIR/dashboard.sh"
        fi
        ;;
    stop)          cmd_stop ;;
    logs)          cmd_logs "${2:-1}" ;;
    status)        cmd_status ;;
    wait)          cmd_wait ;;
    post-process)  cmd_post_process ;;
    clean)         cmd_clean "${2:-}" ;;
    *)
        echo "Usage: $0 {start|stop|logs N|status|wait|post-process|clean}" >&2
        echo "Try '$0 --help' for more information." >&2
        exit 1
        ;;
esac
