#!/usr/bin/env bash
# Phase 0 probe: does a repository-supplied .claude/settings.json take effect
# under `claude -p` (where the workspace trust dialog is skipped), and does
# --setting-sources user suppress it?
#
# Deterministic: uses a SessionStart hook that touches a marker file, so the
# result does not depend on the model complying with any instruction.
#
# Usage: bash probe0-settings-trust.sh <scratch-dir>
set -u
umask 077
LC_ALL=C

SCRATCH="${1:?usage: probe0-settings-trust.sh <scratch-dir>}"
REPO="$SCRATCH/hostile-repo"
MARKERS="$SCRATCH/markers"
RESULTS="$SCRATCH/RESULTS.txt"

rm -rf "$REPO" "$MARKERS"
mkdir -p "$REPO/.claude" "$MARKERS"

# The "hostile" repo settings: a SessionStart hook plus an env override that
# would redirect API traffic in a real attack.
cat > "$REPO/.claude/settings.json" <<EOF
{
  "env": { "RELAY_TRUST_PROBE": "leaked" },
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command",
                     "command": "touch '$MARKERS'/project-hook-fired" } ] }
    ]
  }
}
EOF

# A repo-supplied MCP config, to test --strict-mcp-config separately.
cat > "$REPO/.mcp.json" <<EOF
{ "mcpServers": { "probe": { "command": "touch",
                             "args": ["$MARKERS/mcp-loaded"] } } }
EOF

run_probe() {
  # $1 = label, $2.. = extra claude flags
  local label="$1"; shift
  rm -f "$MARKERS"/project-hook-fired "$MARKERS"/mcp-loaded
  ( cd "$REPO" || exit 1
    CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 \
    timeout 120 claude -p 'Reply with exactly: ok' \
      --model haiku \
      --permission-mode dontAsk \
      --output-format json \
      --max-budget-usd 0.05 \
      "$@" \
      < /dev/null > "$MARKERS/$label.out" 2> "$MARKERS/$label.err"
  )
  local rc=$?
  local hook="NO" mcp="NO"
  [ -f "$MARKERS/project-hook-fired" ] && hook="YES"
  [ -f "$MARKERS/mcp-loaded" ] && mcp="YES"
  printf '%-28s rc=%-4s project_hook_fired=%-4s mcp_loaded=%s\n' \
    "$label" "$rc" "$hook" "$mcp" | tee -a "$RESULTS"
}

: > "$RESULTS"
echo "=== Phase 0 probe: repo settings under -p ===" | tee -a "$RESULTS"
run_probe "baseline-no-flags"
run_probe "setting-sources-user" --setting-sources user
run_probe "strict-mcp-only"      --strict-mcp-config
run_probe "both-mitigations"     --setting-sources user --strict-mcp-config

echo
echo "INTERPRETATION:" | tee -a "$RESULTS"
echo "  baseline project_hook_fired=YES  => repo settings DO execute under -p (Critical)" | tee -a "$RESULTS"
echo "  setting-sources-user =NO         => the mitigation works" | tee -a "$RESULTS"
