# test/cases/c050_cap_reached.sh — "work" repeated forever with
# max_sessions 3: must exit 23 (cap.reached) after exactly 3 sessions, never
# launching a 4th.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
printf '# RUN\n\nMinimal run.\n' > "$STATE/RUN.md"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":3}
EOF

export RELAY_SKIP_PROBE=1
export RELAY_MOCK_SCRIPT="work"

mkconsent "$STATE"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

JOURNAL="$STATE/journal.log"

assert_rc 23 "$RC" "c050_rc"
assert_grep "$JOURNAL" 'cap\.reached' "c050_cap_reached_journaled"

ACTIONSCNT=$(wc -l < "$RELAY_MOCK_DIR/actions" | tr -d ' ')
assert_eq "3" "$ACTIONSCNT" "c050_exactly_three_invocations"

exit 0
