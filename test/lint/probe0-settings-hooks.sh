#!/usr/bin/env bash
# Phase 0 probe: can relay deliver its hooks through the inline --settings
# payload (so they exist ONLY in relay's own child sessions), instead of
# registering them globally via the plugin's hooks/hooks.json?
#
# The entire "no global hook" security decision depends on this being YES.
#
# Also checks: does an inline --settings JSON string work at all, and does a
# PostToolUse hook delivered this way actually fire on tool calls?
#
# Usage: bash probe0-settings-hooks.sh <scratch-dir>
set -u
umask 077
LC_ALL=C

SCRATCH="${1:?usage: probe0-settings-hooks.sh <scratch-dir>}"
WORK="$SCRATCH/work"
MARKERS="$SCRATCH/markers"
RESULTS="$SCRATCH/RESULTS-hooks.txt"

rm -rf "$WORK" "$MARKERS"
mkdir -p "$WORK" "$MARKERS"

# Inline settings payload: SessionStart + PostToolUse hooks, plus a deny rule
# we can use to confirm permissions from --settings are honored too.
SETTINGS=$(jq -nc --arg m "$MARKERS" '
{
  hooks: {
    SessionStart: [ { hooks: [ { type: "command",
                                 command: ("touch " + $m + "/settings-sessionstart") } ] } ],
    PostToolUse:  [ { matcher: "Bash",
                      hooks: [ { type: "command",
                                 command: ("touch " + $m + "/settings-posttooluse") } ] } ]
  },
  permissions: { deny: ["Bash(curl:*)"] }
}')

printf '%s\n' "$SETTINGS" > "$MARKERS/payload.json"

: > "$RESULTS"
echo "=== Phase 0 probe: hooks delivered via inline --settings ===" | tee -a "$RESULTS"

( cd "$WORK" || exit 1
  CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 \
  timeout 180 claude -p 'Use the Bash tool to run exactly: echo hello. Then reply ok.' \
    --model haiku \
    --permission-mode dontAsk \
    --setting-sources user \
    --strict-mcp-config \
    --settings "$SETTINGS" \
    --output-format json \
    --max-budget-usd 0.10 \
    < /dev/null > "$MARKERS/hooks.out" 2> "$MARKERS/hooks.err"
)
rc=$?

ss="NO"; pt="NO"
[ -f "$MARKERS/settings-sessionstart" ] && ss="YES"
[ -f "$MARKERS/settings-posttooluse" ] && pt="YES"

printf 'inline --settings accepted   rc=%s\n' "$rc" | tee -a "$RESULTS"
printf 'SessionStart hook fired      %s\n' "$ss" | tee -a "$RESULTS"
printf 'PostToolUse  hook fired      %s\n' "$pt" | tee -a "$RESULTS"

echo "--- result json keys ---" | tee -a "$RESULTS"
jq -r 'keys | join(", ")' < "$MARKERS/hooks.out" 2>/dev/null | tee -a "$RESULTS" \
  || { echo "(not valid json; head follows)" | tee -a "$RESULTS"; head -c 400 "$MARKERS/hooks.out" | tee -a "$RESULTS"; }

echo "--- usage/cost fields present? ---" | tee -a "$RESULTS"
jq -r '{session_id, num_turns, total_cost_usd, is_error, subtype} | to_entries
       | map("\(.key)=\(.value|tostring)") | join("  ")' \
   < "$MARKERS/hooks.out" 2>/dev/null | tee -a "$RESULTS"

echo | tee -a "$RESULTS"
echo "INTERPRETATION: PostToolUse=YES => relay ships zero global hooks." | tee -a "$RESULTS"
