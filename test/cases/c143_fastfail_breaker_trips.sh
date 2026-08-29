# c143 — positive EX_FASTFAIL (26). The runner pins RELAY_MIN_SESSION_SECS=0
# globally, which makes the duration rung unreachable everywhere else; this
# case raises the floor so an unproductive AND short streak actually trips
# the circuit breaker. stall_limit is set above fastfail_limit so the stall
# rail cannot fire first.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
mkrunmd "$STATE"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":6,"fastfail_limit":3,"stall_limit":4}
EOF

export RELAY_SKIP_PROBE=1
export RELAY_MOCK_SCRIPT="noop"
export RELAY_MIN_SESSION_SECS=3600

mkconsent "$STATE"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

JOURNAL="$STATE/journal.log"

assert_rc 26 "$RC" "c143_exits_EX_FASTFAIL"
assert_grep "$JOURNAL" 'fastfail\.streak	1/3' "c143_streak_1_journaled"
assert_grep "$JOURNAL" 'fastfail\.streak	3/3' "c143_streak_3_journaled"
assert_grep "$JOURNAL" 'fastfail\.tripped' "c143_breaker_tripped"
assert_json "$STATE/state.json" '.status' "blocked" "c143_status_blocked"
assert_json "$STATE/state.json" '.reason' "fastfail" "c143_reason_fastfail"
# Three sessions ran (the breaker needs a streak of 3). Counted from the
# journal: the EX_FASTFAIL exit path does not persist session_count, so
# state.json still holds the previous loop tail's value.
STARTCNT=$(grep -Fc -- "$(printf '\tsession.start\t')" "$JOURNAL")
assert_eq "3" "$STARTCNT" "c143_three_sessions"

exit 0
