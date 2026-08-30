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

# billing is vocabulary, not mechanics: an unknown value refuses like every
# other enum; subscription journals itself; and doctor tells a subscription
# project without a token budget that its only run rail is notional USD.
printf '{"max_sessions":2,"billing":"paypal"}\n' > "$STATE/config.json"
mkconsent "$STATE"
export RELAY_MOCK_SCRIPT="work,complete"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
assert_rc 78 "$?" "c274_bogus_billing_refused"
assert_grep "$STATE/journal.log" 'config.billing-invalid' "c274_journaled"

printf '{"max_sessions":4,"billing":"subscription"}\n' > "$STATE/config.json"
mkconsent "$STATE"
rm -f "$RELAY_MOCK_DIR/invocation_count"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out2.log" 2>"$PWD/err2.log"
assert_rc 0 "$?" "c274_subscription_runs"
assert_grep "$STATE/journal.log" 'billing.mode	subscription' "c274_mode_journaled"

DOCTOR="$ROOT/plugins/relay/scripts/relay-doctor.sh"
bash "$DOCTOR" "$PROJ" "$STATE" >"$PWD/d1.out" 2>"$PWD/d1.err"
assert_grep "$PWD/d1.err" 'only run-level rail is the NOTIONAL' "c274_doctor_advises_token_budget"
printf '{"max_sessions":4,"billing":"subscription","budget_tokens_total":500000}\n' > "$STATE/config.json"
mkconsent "$STATE"
bash "$DOCTOR" "$PROJ" "$STATE" >"$PWD/d2.out" 2>"$PWD/d2.err"
assert_no_grep "$PWD/d2.err" 'only run-level rail is the NOTIONAL' "c274_doctor_quiet_when_budgeted"
printf '{"max_sessions":4}\n' > "$STATE/config.json"
mkconsent "$STATE"
bash "$DOCTOR" "$PROJ" "$STATE" >"$PWD/d3.out" 2>"$PWD/d3.err"
assert_no_grep "$PWD/d3.err" 'only run-level rail is the NOTIONAL' "c274_doctor_quiet_on_api"
exit 0
