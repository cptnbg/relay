# test/cases/c090_malformed_recovery.sh — malformed,work,complete: the
# malformed handoff is valid JSON of the wrong shape (no "next" array), which
# a syntax check would miss but the schema check must catch. Same
# expectations as c080: handoff.invalid journaled, next session in
# mode=recovery, final exit 0.
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
export RELAY_MOCK_SCRIPT="malformed,work,complete"

mkconsent "$STATE"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

JOURNAL="$STATE/journal.log"

assert_rc 0 "$RC" "c090_rc"
assert_grep "$JOURNAL" 'handoff\.invalid' "c090_handoff_invalid_journaled"

SESSION2_LINE=$(grep -F -- "$(printf '\tsession.start\t')" "$JOURNAL" | sed -n '2p')
assert_contains "$SESSION2_LINE" "mode=recovery" "c090_session2_ran_in_recovery_mode"

assert_grep "$JOURNAL" 'complete\.verified' "c090_complete_verified"

exit 0
