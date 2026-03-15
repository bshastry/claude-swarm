# swarm-core — Multi-agent coordination library

A minimal, agent-runtime-agnostic library for running N
autonomous agents in parallel on a shared codebase. Agents
coordinate through Git. No message queue, no central
orchestrator, no framework lock-in.

## How it works

```
                    ┌─────────────┐
                    │  Bare repo  │
                    │ (agent-work │
                    │   branch)   │
                    └──────┬──────┘
                 ┌─────────┼─────────┐
                 │         │         │
            ┌────▼───┐ ┌───▼────┐ ┌──▼─────┐
            │Agent 1 │ │Agent 2 │ │Agent N │
            │ fetch  │ │ fetch  │ │ fetch  │
            │ work   │ │ work   │ │ work   │
            │ push   │ │ push   │ │ push   │
            └────────┘ └────────┘ └────────┘
                 │         │         │
                 └─────────┼─────────┘
                           ▼
                    ┌─────────────┐
                    │  Harvest    │
                    │  (merge)    │
                    └─────────────┘
```

Each agent runs in a loop:
1. `git fetch` — get latest state.
2. Call your `run_fn` — do one unit of work.
3. Check for new commits — did anyone push?
4. If no new commits for N sessions — exit (idle).
5. Otherwise — loop.

Agents push to a shared branch. On conflict, the agent
rebases and retries (enforced by the coordination prompt
injected into every session).

## Quick start

### Greenfield — build a project from scratch

```bash
ANTHROPIC_API_KEY=sk-... \
    ./lib/core/swarm-run.sh greenfield \
    --prompt prompts/my-task.md \
    --agents 3 \
    --out /tmp/my-project
```

### Improve — modify an existing GitHub repo

```bash
ANTHROPIC_API_KEY=sk-... \
    ./lib/core/swarm-run.sh improve \
    --repo https://github.com/user/project \
    --prompt prompts/add-tests.md \
    --agents 2 \
    --branch swarm-improvements
```

### Synthesize — combine repos into a new project

```bash
ANTHROPIC_API_KEY=sk-... \
    ./lib/core/swarm-run.sh synthesize \
    --repos https://github.com/a/auth,https://github.com/b/db \
    --prompt prompts/unified-api.md \
    --agents 4 \
    --out /tmp/unified-api
```

## Architecture

### Files

```
lib/core/
├── swarm-core.sh        Library. Source this.
├── swarm-run.sh         CLI wrapper (greenfield/improve/synthesize).
├── coordination.md      Git rules template injected into agents.
├── example.sh           Minimal standalone example.
├── prompts/
│   ├── greenfield.md.example
│   ├── improve.md.example
│   └── synthesize.md.example
└── README.md            This file.

examples/
├── greenfield-cli/      Build a CLI tool from scratch.
│   ├── run.sh           One-command launcher.
│   ├── prompt.md        Task description.
│   └── runner-claude.sh Custom runner (optional).
└── improve-repo/        Add tests to existing repo.
    ├── run.sh           One-command launcher.
    ├── prompt.md        Task description.
    └── runner-claude.sh Custom runner (optional).
```

### Core API (swarm-core.sh)

Source the library, then call these functions:

```bash
source lib/core/swarm-core.sh
```

#### `swarm_init_repo SRC BARE`

Create a bare repo from a source git repo. Sets up the
coordination branch (`agent-work` by default).

- Refuses to overwrite a bare repo with unharvested
  commits.
- Idempotent on the branch (safe to call twice).

#### `swarm_clone_workspace BARE WORKDIR`

Clone the bare repo into a workspace for one agent.
Configures git user, checks out the coordination branch.

#### `swarm_agent_loop RUN_FN PROMPT AGENT_ID [MAX_IDLE]`

The main loop. Calls `RUN_FN` repeatedly until the agent
idles out.

- `RUN_FN` receives `(prompt_file, workdir, agent_id)`.
- Return codes from `RUN_FN`:
  - `0` — success.
  - `1` — non-fatal error (counts toward idle).
  - `2` — rate limit (exponential backoff, does NOT
    count toward idle).
  - `3+` — fatal (agent exits immediately).
- Idle detection: if no new commits appear on the
  coordination branch for `MAX_IDLE` consecutive sessions,
  the agent exits cleanly.
- Backoff: starts at 300s, doubles each rate-limit hit,
  caps at 1800s. Adds random jitter (0–60s).

#### `swarm_harvest REPO BARE [TARGET_BRANCH]`

Merge the coordination branch into the target branch
(default: current branch of REPO). Uses `--no-ff` to
preserve the merge point.

#### `swarm_record_stats ID COST IN OUT DUR TURNS`

Append a TSV stats line. Optional; useful for cost
tracking.

#### `swarm_coordination_prompt AGENT_ID`

Generate the git coordination rules for an agent. Returns
the prompt text on stdout. Automatically injected by
`swarm_agent_loop` when `SWARM_INJECT_RULES=true`
(default).

### Configuration (environment variables)

| Variable | Default | Purpose |
|----------|---------|---------|
| `SWARM_MAX_IDLE` | `3` | Idle sessions before exit. |
| `SWARM_BRANCH` | `agent-work` | Coordination branch name. |
| `SWARM_GIT_USER` | `swarm-agent` | Git committer name. |
| `SWARM_GIT_EMAIL` | `agent@swarm.local` | Git committer email. |
| `SWARM_STATS_DIR` | `/tmp` | Directory for stats TSV files. |
| `SWARM_BACKOFF_INIT` | `300` | Initial rate-limit backoff (seconds). |
| `SWARM_BACKOFF_CAP` | `1800` | Maximum backoff (seconds). |
| `SWARM_INJECT_RULES` | `true` | Inject coordination prompt. |

## Writing a run function

The run function is the only thing you implement. It
receives a prompt, a working directory, and an agent ID.
It does one unit of work and returns.

### Minimal Claude Code runner

```bash
run_agent() {
    local prompt=$1 workdir=$2 id=$3
    cd "$workdir"

    local full_prompt
    full_prompt="$(cat "$prompt")"
    if [ -n "${SWARM_COORDINATION_PROMPT:-}" ]; then
        full_prompt="${full_prompt}

${SWARM_COORDINATION_PROMPT}"
    fi

    claude --dangerously-skip-permissions \
        -p "$full_prompt" \
        --model claude-sonnet-4-6 \
        --verbose 2>/dev/null || return 1
}
```

### Aider runner

```bash
run_agent() {
    local prompt=$1 workdir=$2 id=$3
    cd "$workdir"
    aider --message "$(cat "$prompt")" \
        --auto-commits \
        --yes || return 1
}
```

### Custom script runner

```bash
run_agent() {
    local prompt=$1 workdir=$2 id=$3
    cd "$workdir"

    # Your logic here. Read the prompt, do work,
    # git add/commit/push.
    python my_agent.py \
        --task "$prompt" \
        --workdir "$workdir" || return 1
}
```

### Return code contract

| Code | Meaning | Behavior |
|------|---------|----------|
| `0` | Success | Reset backoff. Check for idle. |
| `1` | Non-fatal error | Sleep 30s. Count toward idle. |
| `2` | Rate limited | Exponential backoff. No idle count. |
| `3+` | Fatal error | Agent exits immediately. |

## Writing effective prompts

The prompt is the most important part. Bad prompts produce
duplicate work. Good prompts produce convergent progress.

### Rules for multi-agent prompts

**1. Start with "read the state."**
Always tell agents to check `git log` and read existing
files before doing anything. Otherwise they duplicate
work.

**2. Define a pick-one protocol.**
List the possible tasks in priority order. Tell the agent
to pick ONE that is not yet done. This prevents two agents
from implementing the same feature.

```markdown
Pick ONE of the following (whichever is most needed):
- If go.mod does not exist: create it.
- If main.go has no flag parsing: add it.
- If tests do not exist: write them.
- If tests fail: fix them.
```

**3. Tell them to stop after pushing.**
Agents must stop after one push. The harness restarts
them with the latest state. If agents keep working after
pushing, they diverge from other agents' changes.

**4. Scope the work.**
Name specific files or directories. Agents that wander
the whole codebase step on each other's toes.

**5. Include verification commands.**
Tell agents exactly how to check their work:
`go test ./...`, `npm test`, `pytest`, etc.

### Anti-patterns

- "Implement the entire project." — Too vague. Agents
  duplicate each other's work.
- No mention of existing state. — Agents overwrite each
  other.
- No stop-after-push rule. — Agents drift from shared
  state.
- Overly prescriptive file-level assignments. — Prevents
  agents from adapting to what others have done.

## Scaling to N agents

The library scales horizontally. There is no coordinator
process — each agent independently decides what to do
based on the repo state.

### Practical limits

| N | Expected behavior |
|---|-------------------|
| 1–3 | Clean. Minimal conflicts. |
| 4–8 | Occasional rebase conflicts. Agents resolve them. |
| 9–15 | Frequent rebases. Works but slower per-agent. |
| 16+ | Diminishing returns. Push serialization bottleneck. |

### Tuning for high N

- **Partition the prompt.** Give different agent groups
  different prompts targeting different parts of the
  codebase. Use `swarm-run.sh` with `--runner` to assign
  different task scopes.
- **Increase MAX_IDLE.** With many agents, idle detection
  triggers too early because everyone is waiting for
  everyone else. Use `--max-idle 5` or higher.
- **Use branch-per-task.** For N>10, consider modifying
  the coordination prompt to use per-agent branches
  and a separate merge step. (Not built in yet — this
  is the next evolution of the library.)

## Lifecycle of a swarm run

```
1. Init          swarm_init_repo creates bare repo.
2. Clone         swarm_clone_workspace per agent.
3. Loop          swarm_agent_loop runs sessions.
   ├── Fetch     git fetch origin
   ├── Run       your run_fn does work
   ├── Check     compare SHAs (new commits?)
   ├── Idle?     no new commits → idle++
   │   └── Exit  idle >= max_idle → done
   └── Active    new commits → idle=0, restart
4. Harvest       swarm_harvest merges into target.
```

## Comparison with full claude-swarm

| Feature | swarm-core | claude-swarm |
|---------|-----------|-------------|
| Agent runtime | Any | Claude Code only |
| Container isolation | No (BYO) | Docker built-in |
| Dashboard | No | Yes (TUI) |
| Cost tracking | `swarm_record_stats` | Full dashboard |
| Config format | Env vars + CLI flags | swarm.json |
| Post-processing | No | Yes (post_process agent) |
| Auth management | BYO | OAuth + API key routing |
| Setup scripts | BYO | Built-in |

Use swarm-core when you want the coordination primitives
without the Docker/dashboard overhead. Use full
claude-swarm when you want batteries-included.

## Examples

See `examples/` for complete working examples:

- `examples/greenfield-cli/` — Build a Go CLI tool from
  scratch with 3 agents.
- `examples/improve-repo/` — Add tests to an existing
  GitHub repo with 2 agents.

Each example includes:
- `run.sh` — one-command launcher.
- `prompt.md` — task description.
- `runner-claude.sh` — customizable agent runner.
