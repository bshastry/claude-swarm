# Task: Add tests and harden error handling

## Goal

Improve this existing project by adding comprehensive
tests and hardening error handling. The project already
works but has gaps in test coverage and inconsistent
error reporting.

## Scope

### Phase 1 — Audit (every session)

1. Run `git log --oneline -10` to see recent commits.
2. Run the existing test suite to understand current state.
3. Read the source files to find untested code paths.

### Phase 2 — Pick one task

Choose ONE of the following (whichever is most needed
based on current state):

**Add tests for untested functions.**
- Write table-driven tests where appropriate.
- Cover edge cases: empty input, nil, large input,
  concurrent access.
- Aim for meaningful coverage, not line-count gaming.

**Harden error handling.**
- Replace panics with returned errors.
- Add context to wrapped errors (`fmt.Errorf("...: %w")`).
- Ensure resources are cleaned up (defer Close).

**Fix flaky or failing tests.**
- If existing tests fail, fix them before adding new ones.

### Phase 3 — Verify

1. Run the full test suite.
2. Run the linter / vet tool if available.
3. Confirm no regressions.

## Rules

- Do NOT refactor working code that is unrelated to your
  task.
- Do NOT change public API signatures unless fixing a bug.
- Do NOT add dependencies.
- One logical change per commit.
- After pushing, stop.
