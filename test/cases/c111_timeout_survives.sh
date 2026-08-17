# test/cases/c111_timeout_survives.sh — hang,work,complete with
# max_timeouts 3: a single timeout must not trip the breaker; the run
# recovers and finishes. Exit 0.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
printf '# RUN\n\nMinimal run.\n' > "$STATE/RUN.md"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":6,"max_timeouts":3}
EOF

export RELAY_SKIP_PROBE=1
export RELAY_SESSION_TIMEOUT=2
export RELAY_MOCK_HANG_SECS=10
export RELAY_MOCK_SCRIPT="hang,work,complete"

bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

JOURNAL="$STATE/journal.log"

assert_rc 0 "$RC" "c111_rc"
assert_grep "$JOURNAL" 'session\.timeout' "c111_timeout_happened"
assert_grep "$JOURNAL" 'complete\.verified' "c111_recovered_and_completed"

exit 0
