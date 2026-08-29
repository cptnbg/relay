# test/cases/c141_productive_short_sessions_survive.sh — the fast-fail breaker
# must never trip on sessions that did work.
#
# The breaker exists to catch sessions that die on startup: a rejected session
# id, a broken settings payload, an auth failure. Those produce nothing. It
# used to count any session shorter than min_session_secs, productive or not,
# so three quick correct steps in a row halted a healthy run with exit 26 — a
# circuit breaker tripping on success.
#
# Every session here commits and writes a valid handoff, and min_session_secs
# is set far above the mock's runtime so all three count as "short". The run
# must therefore reach its session cap (23), never the breaker (26).
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
mkrunmd "$STATE"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":3,"fastfail_limit":3,"stall_limit":3,"max_fable_sessions":2}
EOF

export RELAY_SKIP_PROBE=1
export RELAY_MOCK_SCRIPT="work,work,work"
# Every session the mock runs finishes in well under a second, so this makes
# all of them "short" without making the test slow.
export RELAY_MIN_SESSION_SECS=3600

mkconsent "$STATE"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

JOURNAL="$STATE/journal.log"

assert_rc 23 "$RC" "c141_reaches_cap_not_breaker"
assert_grep "$JOURNAL" 'cap\.reached' "c141_cap_reached"
assert_no_grep "$JOURNAL" 'fastfail\.streak' "c141_no_fastfail_streak_on_productive_work"
assert_no_grep "$JOURNAL" 'fastfail\.tripped' "c141_breaker_never_trips"
assert_no_grep "$JOURNAL" 'stall\.count' "c141_no_stall_on_productive_work"
# The same counters drive the automatic escalation, so a false fast-fail also
# used to spend the fable budget on a run that was working fine.
assert_no_grep "$JOURNAL" 'escalation\.auto' "c141_no_escalation_on_productive_work"

exit 0
