# test/cases/c110_overlong_handoff_normalized.sh — a handoff with the right
# shape but over-long entries is truncated to the caps and USED, not discarded.
#
# Regression from the AEIA run. Session 9 wrote a structurally perfect handoff
# whose only fault was ten entries over 280 characters (longest 1,583). It was
# rejected whole: the session's entire position was lost, the stall counter
# advanced, and the next session ran in recovery — $2.55 for the session plus
# the recovery behind it. Opus stayed under the cap and sonnet did not, so this
# fires on a tier switch, which is a thing relay does automatically.
#
# Truncation enforces the same bound the cap exists for — how much
# agent-authored text reaches the next prompt — so nothing is weakened. The
# injection filter and drift detector run afterwards on the normalized content.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
printf '# RUN\n\nMinimal run.\n' > "$STATE/RUN.md"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":2}
EOF

export RELAY_SKIP_PROBE=1
export RELAY_MOCK_SCRIPT="verbose,complete"

mkconsent "$STATE"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

JOURNAL="$STATE/journal.log"

assert_grep "$JOURNAL" 'handoff\.normalized' "c180_normalization_journaled"
# Accepted, not discarded: an over-long handoff must not advance the stall
# counter or trigger recovery.
assert_grep "$JOURNAL" 'handoff\.ok' "c180_handoff_accepted"
assert_no_grep "$JOURNAL" 'handoff\.invalid' "c180_not_rejected"
assert_no_grep "$JOURNAL" 'mode=recovery' "c180_no_recovery_session"

# Assert against the ARCHIVED session-1 handoff, not continue.json: session 2
# overwrites the live file with its own, so checking there would silently test
# the wrong document.
ARCHIVED=$(ls "$STATE"/handoffs/001-*.json 2>/dev/null | head -1)
assert_file "$ARCHIVED" "c180_session1_handoff_archived"

# Every entry is inside the cap, and the content survived rather than being
# replaced by a placeholder.
assert_json "$ARCHIVED" \
  '[.done[],.next[],(.files_touched//[])[],(.open_questions//[])[]] | map(select(length > 280)) | length' \
  "0" "c180_all_entries_capped"
assert_json "$ARCHIVED" '.next | length > 0' "true" "c180_next_survived"
assert_grep "$ARCHIVED" 'VERBOSE-HANDOFF-MARKER' "c180_leading_content_kept"
assert_grep "$ARCHIVED" '\.\.\.' "c180_truncation_marked"

assert_rc 0 "$RC" "c180_run_completed"

exit 0
