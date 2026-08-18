# test/cases/c160_budget_exhausted.sh — budget_usd_total set very low
# (0.01) against a mock that reports total_cost_usd 0.01 per invocation:
# the very first session already meets/exceeds the budget, so the top of
# the NEXT loop iteration must halt before launching a second session.
# Exit 29, budget.exhausted journaled, only one mock invocation happened.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
printf '# RUN\n\nMinimal run.\n' > "$STATE/RUN.md"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":6,"budget_usd_total":0.01}
EOF

export RELAY_SKIP_PROBE=1
export RELAY_MOCK_SCRIPT="work"

mkconsent "$STATE"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

JOURNAL="$STATE/journal.log"

assert_rc 29 "$RC" "c160_rc"
assert_grep "$JOURNAL" 'budget\.exhausted' "c160_budget_exhausted_journaled"

ACTIONSCNT=$(wc -l < "$RELAY_MOCK_DIR/actions" | tr -d ' ')
assert_eq "1" "$ACTIONSCNT" "c160_only_one_session_ran"

exit 0
