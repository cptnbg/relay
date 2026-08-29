# test/cases/c107_budget_cap_is_not_a_usage_limit.sh — a session stopped by
# --max-budget-usd delivered real work. Treat it as a session, not as weather.
#
# From relay's first real run: session 1 exited rc=1, is_error true, subtype
# error_max_budget_usd, terminal_reason budget_exhausted — having committed two
# phases and written a valid handoff. Two things must hold.
#
# It must not be mistaken for a usage limit. A usage limit is transient and gets
# backed off and retried without counting; a budget cap is a ceiling the user
# set, and retrying it just spends the next session's budget reaching the same
# wall. The counters must advance normally.
#
# And the journal must say WHY. `session.exit n=1 rc=1 dur=295s` reads as a
# crash; establishing that it was a budget cap took a jq dive over the session
# log, which is not a thing anyone should have to do to a six-hour overnight
# journal.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
mkrunmd "$STATE"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":4,"on_limit":"wait"}
EOF

export RELAY_SKIP_PROBE=1
export RELAY_BACKOFF_BASE=1
export RELAY_MOCK_SCRIPT="budgetcap,complete"

mkconsent "$STATE"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

JOURNAL="$STATE/journal.log"

assert_rc 0 "$RC" "c107_rc"
assert_no_grep "$JOURNAL" 'usage_limit' "c107_not_a_usage_limit"
assert_grep "$JOURNAL" 'session\.reason.*budget_exhausted' "c107_journal_says_why"

# No retry was inserted: two scripted behaviours, two invocations, two sessions.
ACTIONSCNT=$(wc -l < "$RELAY_MOCK_DIR/actions" | tr -d ' ')
assert_eq "2" "$ACTIONSCNT" "c107_no_extra_invocation"
assert_json "$STATE/state.json" '.session_count' "2" "c107_both_sessions_counted"

exit 0
