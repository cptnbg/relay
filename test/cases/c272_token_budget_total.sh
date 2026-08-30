PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com \
  commit -q -m "chore: add plan.md" >/dev/null 2>&1
mkdir -p "$STATE/work"
mkrunmd "$STATE"
export RELAY_SKIP_PROBE=1

# The run-level token budget: the twin of budget_usd_total in the units a
# subscription operator actually spends. The mock's fixed envelope reports
# 52411+2048+8192+1024 = 63675 tokens per session; a 100000 cap lets session 1
# through the pre-spawn gate (63675 < 100000), lets session 2 run, then refuses
# session 3 at 127350 — proving the gate reads the ACCUMULATED total. Works in
# api billing too: the gates are orthogonal to the billing vocabulary.
printf '{"max_sessions":9,"budget_tokens_total":100000}\n' > "$STATE/config.json"
mkconsent "$STATE"
export RELAY_MOCK_SCRIPT="work"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
assert_rc 29 "$?" "c272_exit_budget"
assert_json "$STATE/state.json" '.status' "budget" "c272_status"
assert_json "$STATE/state.json" '.reason' "tokens" "c272_reason_splits_the_code"
assert_grep "$STATE/journal.log" 'budget.tokens-exhausted' "c272_journaled"
assert_grep "$STATE/journal.log" 'session.tokens	n=1 used=63675 total=63675' "c272_per_session_line"
assert_json "$STATE/state.json" '.tokens_total' "127350" "c272_total_persisted"
assert_eq "2" "$(grep -c '^[0-9]* work$\|work$' "$RELAY_MOCK_DIR/actions")" "c272_two_sessions_ran"

# Zero (the default) means off: same setup completes untouched.
STATE2="$PWD/state2"
mkdir -p "$STATE2/work"
mkrunmd "$STATE2"
printf '{"max_sessions":9}\n' > "$STATE2/config.json"
mkconsent "$STATE2"
rm -f "$RELAY_MOCK_DIR/invocation_count"
PROJ2="$PWD/proj2"; mkrepo "$PROJ2"
printf '# Plan\n\n1. s\n' > "$PROJ2/plan.md"
git -C "$PROJ2" add -A >/dev/null 2>&1
git -C "$PROJ2" -c user.name=mock -c user.email=mock@example.com commit -q -m p >/dev/null 2>&1
export RELAY_MOCK_SCRIPT="work,complete"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ2" "$STATE2" >"$PWD/out2.log" 2>"$PWD/err2.log"
assert_rc 0 "$?" "c272_zero_means_off"
# Found live: a run completing in session 1 left tokens_total null, and a
# resume would have re-initialised the budget counter to zero. Every terminal
# exit now persists it.
assert_json "$STATE2/state.json" '.tokens_total' "127350" "c272_completed_run_persists_total"
assert_no_grep "$STATE2/journal.log" 'budget.tokens-exhausted' "c272_no_false_gate"
assert_grep "$STATE2/journal.log" 'session.tokens' "c272_accounting_always_on"
exit 0
