# test/cases/c080_crash_recovery.sh — crash,work,complete: the crash writes
# a truncated (invalid-JSON) handoff. The journal must show handoff.invalid
# and the NEXT session must run in mode=recovery. Final exit 0.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
printf '# RUN\n\nMinimal run.\n' > "$STATE/RUN.md"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":6}
EOF

export RELAY_SKIP_PROBE=1
export RELAY_MOCK_SCRIPT="crash,work,complete"

bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

JOURNAL="$STATE/journal.log"

assert_rc 0 "$RC" "c080_rc"
assert_grep "$JOURNAL" 'handoff\.invalid' "c080_handoff_invalid_journaled"

SESSION2_LINE=$(grep -F -- "$(printf '\tsession.start\t')" "$JOURNAL" | sed -n '2p')
assert_contains "$SESSION2_LINE" "mode=recovery" "c080_session2_ran_in_recovery_mode"

assert_grep "$JOURNAL" 'complete\.verified' "c080_complete_verified"

exit 0
