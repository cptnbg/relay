# test/cases/c110_timeout_trips.sh — a session that just hangs, with
# max_timeouts 1: the very first timeout must trip the breaker. Exit 22,
# elapsed time close to the (short, test-compressed) session timeout, NOT
# anywhere near the mock's full hang duration, and journal has
# session.timeout.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
printf '# RUN\n\nMinimal run.\n' > "$STATE/RUN.md"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":6,"max_timeouts":1}
EOF

export RELAY_SKIP_PROBE=1
export RELAY_SESSION_TIMEOUT=3
export RELAY_MOCK_HANG_SECS=30
export RELAY_MOCK_SCRIPT="hang"

T0=$(date +%s)
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?
T1=$(date +%s)
ELAPSED=$((T1 - T0))

JOURNAL="$STATE/journal.log"

assert_rc 22 "$RC" "c110_rc"
assert_between "$ELAPSED" "0" "19" "c110_elapsed_near_timeout_not_full_hang"
assert_grep "$JOURNAL" 'session\.timeout' "c110_session_timeout_journaled"

exit 0
