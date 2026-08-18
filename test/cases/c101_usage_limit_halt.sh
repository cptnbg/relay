# test/cases/c101_usage_limit_halt.sh — on_limit=halt with a usage-limit
# response: must not wait/retry at all, exits 29 immediately.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
printf '# RUN\n\nMinimal run.\n' > "$STATE/RUN.md"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":6,"on_limit":"halt"}
EOF

export RELAY_SKIP_PROBE=1
export RELAY_MOCK_SCRIPT="usagelimit"

mkconsent "$STATE"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

JOURNAL="$STATE/journal.log"

assert_rc 29 "$RC" "c101_rc"
assert_grep "$JOURNAL" 'usage_limit\.halt' "c101_usage_limit_halt_journaled"

ACTIONSCNT=$(wc -l < "$RELAY_MOCK_DIR/actions" | tr -d ' ')
assert_eq "1" "$ACTIONSCNT" "c101_halted_after_first_attempt"

exit 0
