#!/bin/bash
# shellcheck disable=SC2034
set -euo pipefail

# Unit tests for harness.sh stat extraction and logic.
# No Docker or API key required.

PASS=0
FAIL=0
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: ${label}"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: ${label}"
        echo "        expected: ${expected}"
        echo "        actual:   ${actual}"
        FAIL=$((FAIL + 1))
    fi
}

# --- Helpers: same jq expressions used in harness.sh ---

extract_stats() {
    local logfile="$1"
    local cost dur api_ms turns tok_in tok_out cache_rd cache_cr
    cost=$(jq -r '.total_cost_usd // 0' "$logfile" 2>/dev/null || true)
    cost="${cost:-0}"
    dur=$(jq -r '.duration_ms // 0' "$logfile" 2>/dev/null || true)
    dur="${dur:-0}"
    api_ms=$(jq -r '.duration_api_ms // 0' "$logfile" 2>/dev/null || true)
    api_ms="${api_ms:-0}"
    turns=$(jq -r '.num_turns // 0' "$logfile" 2>/dev/null || true)
    turns="${turns:-0}"
    tok_in=$(jq -r '.usage.input_tokens // 0' "$logfile" 2>/dev/null || true)
    tok_in="${tok_in:-0}"
    tok_out=$(jq -r '.usage.output_tokens // 0' "$logfile" 2>/dev/null || true)
    tok_out="${tok_out:-0}"
    cache_rd=$(jq -r '.usage.cache_read_input_tokens // 0' "$logfile" 2>/dev/null || true)
    cache_rd="${cache_rd:-0}"
    cache_cr=$(jq -r '.usage.cache_creation_input_tokens // 0' "$logfile" 2>/dev/null || true)
    cache_cr="${cache_cr:-0}"
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s" \
        "$(date +%s)" "$cost" "$tok_in" "$tok_out" \
        "$cache_rd" "$cache_cr" "$dur" "$api_ms" "$turns"
}

extract_error() {
    local logfile="$1"
    local is_err err_result
    is_err=$(jq -r '.is_error // false' "$logfile" \
      2>/dev/null || true)
    is_err="${is_err:-false}"
    err_result=$(jq -r '.result // ""' "$logfile" \
      2>/dev/null || true)
    err_result="${err_result:-}"
    printf "%s\t%s" "$is_err" "$err_result"
}

# ============================================================
echo "=== 1. Full JSON output parsing ==="

cat > "$TMPDIR/full.json" <<'EOF'
{
  "total_cost_usd": 0.1292,
  "duration_ms": 19000,
  "duration_api_ms": 15000,
  "num_turns": 6,
  "usage": {
    "input_tokens": 800,
    "output_tokens": 644,
    "cache_read_input_tokens": 117000,
    "cache_creation_input_tokens": 5000
  }
}
EOF

LINE=$(extract_stats "$TMPDIR/full.json")
IFS=$'\t' read -r ts cost tok_in tok_out cache_rd cache_cr dur api_ms turns <<< "$LINE"

assert_eq "cost"     "0.1292"  "$cost"
assert_eq "tok_in"   "800"     "$tok_in"
assert_eq "tok_out"  "644"     "$tok_out"
assert_eq "cache_rd" "117000"  "$cache_rd"
assert_eq "cache_cr" "5000"    "$cache_cr"
assert_eq "dur"      "19000"   "$dur"
assert_eq "api_ms"   "15000"   "$api_ms"
assert_eq "turns"    "6"       "$turns"

# ============================================================
echo ""
echo "=== 2. Minimal JSON (missing fields default to 0) ==="

cat > "$TMPDIR/minimal.json" <<'EOF'
{ "total_cost_usd": 0.05 }
EOF

LINE=$(extract_stats "$TMPDIR/minimal.json")
IFS=$'\t' read -r ts cost tok_in tok_out cache_rd cache_cr dur api_ms turns <<< "$LINE"

assert_eq "cost"     "0.05" "$cost"
assert_eq "tok_in"   "0"    "$tok_in"
assert_eq "tok_out"  "0"    "$tok_out"
assert_eq "cache_rd" "0"    "$cache_rd"
assert_eq "dur"      "0"    "$dur"
assert_eq "turns"    "0"    "$turns"

# ============================================================
echo ""
echo "=== 3. Invalid JSON fallback ==="

echo "not json at all" > "$TMPDIR/garbage.txt"

LINE=$(extract_stats "$TMPDIR/garbage.txt")
IFS=$'\t' read -r ts cost tok_in tok_out cache_rd cache_cr dur api_ms turns <<< "$LINE"

assert_eq "cost fallback"  "0" "$cost"
assert_eq "turns fallback" "0" "$turns"
assert_eq "dur fallback"   "0" "$dur"

# ============================================================
echo ""
echo "=== 4. Empty file fallback ==="

: > "$TMPDIR/empty.json"

LINE=$(extract_stats "$TMPDIR/empty.json")
IFS=$'\t' read -r ts cost tok_in tok_out cache_rd cache_cr dur api_ms turns <<< "$LINE"

assert_eq "cost empty"  "0" "$cost"
assert_eq "turns empty" "0" "$turns"

# ============================================================
echo ""
echo "=== 5. TSV line format ==="

LINE=$(extract_stats "$TMPDIR/full.json")
FIELD_COUNT=$(echo "$LINE" | awk -F'\t' '{print NF}')
assert_eq "9 tab-separated fields" "9" "$FIELD_COUNT"

# ============================================================
echo ""
echo "=== 6. INJECT_GIT_RULES logic ==="

build_append_args() {
    local inject="$1" file_exists="$2"
    local -a APPEND_ARGS=()
    if [ "$inject" = "true" ] && [ "$file_exists" = "true" ]; then
        APPEND_ARGS+=(--append-system-prompt-file /agent-system-prompt.md)
    fi
    echo "${#APPEND_ARGS[@]}"
}

assert_eq "inject=true, file=true"   "2" "$(build_append_args true true)"
assert_eq "inject=false, file=true"  "0" "$(build_append_args false true)"
assert_eq "inject=true, file=false"  "0" "$(build_append_args true false)"
assert_eq "inject=false, file=false" "0" "$(build_append_args false false)"

# ============================================================
echo ""
echo "=== 7. Idle counter logic ==="

simulate_idle() {
    local before="$1" after="$2" idle_count="$3" max_idle="$4"
    if [ "$before" = "$after" ]; then
        idle_count=$((idle_count + 1))
        if [ "$idle_count" -ge "$max_idle" ]; then
            echo "exit"
        else
            echo "idle:${idle_count}"
        fi
    else
        echo "reset"
    fi
}

assert_eq "same SHA increments"    "idle:1"  "$(simulate_idle abc123 abc123 0 3)"
assert_eq "same SHA at limit"      "exit"    "$(simulate_idle abc123 abc123 2 3)"
assert_eq "different SHA resets"   "reset"   "$(simulate_idle abc123 def456 2 3)"
assert_eq "max_idle=1 immediate"   "exit"    "$(simulate_idle abc123 abc123 0 1)"

# ============================================================
echo ""
echo "=== 8. prepare-commit-msg hook appends trailers ==="

# Mirrors the hook installed by harness.sh. Exercises it against
# a real git repo so we test actual commit behaviour.
HOOK_REPO="$TMPDIR/hook-repo"
mkdir -p "$HOOK_REPO"
git init -q "$HOOK_REPO"
git -C "$HOOK_REPO" config user.name "test"
git -C "$HOOK_REPO" config user.email "test@test"

mkdir -p "$HOOK_REPO/.git/hooks"
cat > "$HOOK_REPO/.git/hooks/prepare-commit-msg" <<'HOOK'
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
chmod +x "$HOOK_REPO/.git/hooks/prepare-commit-msg"

# Commit with prompt + setup.
touch "$HOOK_REPO/file.txt"
git -C "$HOOK_REPO" add file.txt
CLAUDE_MODEL="claude-opus-4-6" CLAUDE_VERSION="1.0.32" SWARM_VERSION="0.1.0" \
    SWARM_RUN_CONTEXT="netherfuzz@a3f8c21 (main)" \
    SWARM_CFG_PROMPT="prompts/task.md" SWARM_CFG_SETUP="scripts/setup.sh" \
    git -C "$HOOK_REPO" commit -m "test commit" --quiet

MSG=$(git -C "$HOOK_REPO" log -1 --format='%B')
assert_eq "hook model trailer" \
    "Model: claude-opus-4-6" \
    "$(echo "$MSG" | grep '^Model:')"
assert_eq "hook tools trailer" \
    "Tools: claude-swarm 0.1.0, Claude Code 1.0.32" \
    "$(echo "$MSG" | grep '^Tools:')"
assert_eq "hook run trailer" \
    "> Run: netherfuzz@a3f8c21 (main)" \
    "$(echo "$MSG" | grep '^> Run:')"
assert_eq "hook cfg trailer" \
    "> Cfg: prompts/task.md, scripts/setup.sh" \
    "$(echo "$MSG" | grep '^> Cfg:')"
assert_eq "hook subject preserved" \
    "test commit" \
    "$(echo "$MSG" | head -1)"

# Second commit with different model, no setup script.
echo "x" > "$HOOK_REPO/file2.txt"
git -C "$HOOK_REPO" add file2.txt
CLAUDE_MODEL="MiniMax-M2.5" CLAUDE_VERSION="1.0.30" SWARM_VERSION="0.1.0" \
    SWARM_RUN_CONTEXT="gethfuzz@b4e9d12 (develop)" \
    SWARM_CFG_PROMPT="prompts/fuzz.md" SWARM_CFG_SETUP="" \
    git -C "$HOOK_REPO" commit -m "second commit" --quiet

MSG2=$(git -C "$HOOK_REPO" log -1 --format='%B')
assert_eq "hook model trailer 2" \
    "Model: MiniMax-M2.5" \
    "$(echo "$MSG2" | grep '^Model:')"
assert_eq "hook tools trailer 2" \
    "Tools: claude-swarm 0.1.0, Claude Code 1.0.30" \
    "$(echo "$MSG2" | grep '^Tools:')"
assert_eq "hook run trailer 2" \
    "> Run: gethfuzz@b4e9d12 (develop)" \
    "$(echo "$MSG2" | grep '^> Run:')"
assert_eq "hook cfg no setup" \
    "> Cfg: prompts/fuzz.md" \
    "$(echo "$MSG2" | grep '^> Cfg:')"

# Idempotent: if trailers already present, hook does not duplicate.
echo "y" > "$HOOK_REPO/file3.txt"
git -C "$HOOK_REPO" add file3.txt
CLAUDE_MODEL="claude-opus-4-6" CLAUDE_VERSION="1.0.32" SWARM_VERSION="0.1.0" \
    SWARM_RUN_CONTEXT="test@abc1234 (main)" \
    SWARM_CFG_PROMPT="p.md" SWARM_CFG_SETUP="" \
    git -C "$HOOK_REPO" commit -m "$(printf 'manual trailers\n\nModel: already-set')" --quiet

MSG3=$(git -C "$HOOK_REPO" log -1 --format='%B')
MODEL_COUNT=$(echo "$MSG3" | grep -c '^Model:' || true)
assert_eq "hook no duplicate" "1" "$MODEL_COUNT"

# ============================================================
echo ""
echo "=== 9. Version string stripping ==="

# Mirrors the CLAUDE_VERSION="${CLAUDE_VERSION%% *}" in harness.sh.
strip_version() { local v="$1"; echo "${v%% *}"; }

assert_eq "strip suffix"   "2.1.52"  "$(strip_version '2.1.52 (Claude Code)')"
assert_eq "no suffix"      "2.1.52"  "$(strip_version '2.1.52')"
assert_eq "unknown"         "unknown" "$(strip_version 'unknown')"

# ============================================================
echo ""
echo "=== 10. Attribution settings file ==="

# Mirrors the .claude/settings.local.json written by harness.sh.
ATTR_JSON='{"attribution":{"commit":"","pr":""}}'
echo "$ATTR_JSON" > "$TMPDIR/settings.local.json"

assert_eq "attr valid JSON" "true" \
    "$(jq empty "$TMPDIR/settings.local.json" 2>/dev/null && echo true || echo false)"
assert_eq "attr commit empty" "" \
    "$(echo "$ATTR_JSON" | jq -r '.attribution.commit')"
assert_eq "attr pr empty" "" \
    "$(echo "$ATTR_JSON" | jq -r '.attribution.pr')"

# ============================================================
echo ""
echo "=== 11. Error detection: rate limit ==="

cat > "$TMPDIR/ratelimit.json" <<'EOF'
{
  "type": "result",
  "is_error": true,
  "result": "You've hit your limit · resets 1am (UTC)",
  "total_cost_usd": 0,
  "num_turns": 1,
  "duration_ms": 357
}
EOF

LINE=$(extract_error "$TMPDIR/ratelimit.json")
IFS=$'\t' read -r is_err err_result <<< "$LINE"

assert_eq "rate limit is_error" "true" "$is_err"
assert_eq "rate limit message" \
    "You've hit your limit · resets 1am (UTC)" \
    "$err_result"
# Verify grep pattern matches.
echo "$err_result" | grep -qi \
    "hit your limit\|rate.limit\|quota"
assert_eq "rate limit grep matches" "0" "$?"

# ============================================================
echo ""
echo "=== 12. Error detection: non-rate-limit ==="

cat > "$TMPDIR/autherr.json" <<'EOF'
{
  "type": "result",
  "is_error": true,
  "result": "Authentication failed: invalid token",
  "total_cost_usd": 0,
  "num_turns": 1
}
EOF

LINE=$(extract_error "$TMPDIR/autherr.json")
IFS=$'\t' read -r is_err err_result <<< "$LINE"

assert_eq "auth err is_error" "true" "$is_err"
# Should NOT match rate-limit pattern.
grep_rc=0
echo "$err_result" | grep -qi \
    "hit your limit\|rate.limit\|quota" || grep_rc=$?
assert_eq "auth err not rate limit" "1" \
    "$grep_rc"

# ============================================================
echo ""
echo "=== 13. Error detection: successful session ==="

cat > "$TMPDIR/success.json" <<'EOF'
{
  "type": "result",
  "is_error": false,
  "result": "Task completed successfully",
  "total_cost_usd": 5.23,
  "num_turns": 42
}
EOF

LINE=$(extract_error "$TMPDIR/success.json")
IFS=$'\t' read -r is_err err_result <<< "$LINE"

assert_eq "success is_error" "false" "$is_err"

# ============================================================
echo ""
echo "=== 14. Error detection: malformed JSON ==="

echo "not json" > "$TMPDIR/garbage2.txt"

LINE=$(extract_error "$TMPDIR/garbage2.txt")
IFS=$'\t' read -r is_err err_result <<< "$LINE"

assert_eq "garbage is_error default" "false" "$is_err"

# ============================================================
echo ""
echo "=== 15. Error detection: empty file ==="

: > "$TMPDIR/empty2.json"

LINE=$(extract_error "$TMPDIR/empty2.json")
IFS=$'\t' read -r is_err err_result <<< "$LINE"

assert_eq "empty is_error default" "false" "$is_err"

# ============================================================
echo ""
echo "=== 16. False positive guard ==="

# Successful session whose result text mentions
# rate limiting — must NOT trigger backoff.
cat > "$TMPDIR/fp.json" <<'EOF'
{
  "type": "result",
  "is_error": false,
  "result": "I checked and you've hit your limit on the API",
  "total_cost_usd": 3.50,
  "num_turns": 15
}
EOF

LINE=$(extract_error "$TMPDIR/fp.json")
IFS=$'\t' read -r is_err err_result <<< "$LINE"

assert_eq "fp is_error false" "false" "$is_err"
# The grep would match, but is_err is false so the
# rate-limit block should never be entered.
# This test documents the invariant.

# ============================================================
echo ""
echo "=== 17. Backoff escalation ==="

# Simulate exponential backoff sequence.
simulate_backoff() {
    local backoff="$1" max="$2"
    backoff=$((backoff * 2))
    if [ "$backoff" -gt "$max" ]; then
        backoff="$max"
    fi
    echo "$backoff"
}

assert_eq "300->600"   "600"  "$(simulate_backoff 300 1800)"
assert_eq "600->1200"  "1200" "$(simulate_backoff 600 1800)"
assert_eq "1200->1800" "1800" "$(simulate_backoff 1200 1800)"
assert_eq "1800 cap"   "1800" "$(simulate_backoff 1800 1800)"

# ============================================================
echo ""
echo "=== 18. Stderr surfacing ==="

echo "error: connection refused" > "$TMPDIR/test.err"
echo "at line 42" >> "$TMPDIR/test.err"
echo "in function foo()" >> "$TMPDIR/test.err"
echo "extra line" >> "$TMPDIR/test.err"

STDERR_OUT=$(head -3 "$TMPDIR/test.err")
LINE_COUNT=$(echo "$STDERR_OUT" | wc -l)
assert_eq "stderr head -3 lines" "3" \
    "$(echo "$LINE_COUNT" | tr -d ' ')"
assert_eq "stderr first line" \
    "error: connection refused" \
    "$(echo "$STDERR_OUT" | head -1)"

# ============================================================
echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
