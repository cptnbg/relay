# test/cases/c121_escalation_reverts_to_default.sh — noop,noop,work,work
# with stall_limit 3: sessions 1-2 are unproductive and trigger the fable
# escalation exactly as in c120, but session 3 (tier=fable) is PRODUCTIVE
# ("work"), so the tier must revert to the configured default (opus) for
# session 4. max_sessions 4 caps the run right after that, so the final
# exit is 23 (capped) rather than 0 — that's expected and fine here; the
# thing under test is the tier on session 4's session.start line.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
printf '# RUN\n\nMinimal run.\n' > "$STATE/RUN.md"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":4,"stall_limit":3,"max_fable_sessions":3,"model_tier":"opus"}
EOF

export RELAY_SKIP_PROBE=1
export RELAY_MOCK_SCRIPT="noop,noop,work,work"

bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

JOURNAL="$STATE/journal.log"

assert_rc 23 "$RC" "c121_rc_capped_after_recovery"

SESSION3_LINE=$(grep -F -- "$(printf '\tsession.start\t')" "$JOURNAL" | sed -n '3p')
assert_contains "$SESSION3_LINE" "tier=fable" "c121_third_session_escalated"

SESSION4_LINE=$(grep -F -- "$(printf '\tsession.start\t')" "$JOURNAL" | sed -n '4p')
assert_contains "$SESSION4_LINE" "tier=opus" "c121_fourth_session_reverted_to_default"

exit 0
