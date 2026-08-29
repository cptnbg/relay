# test/cases/c060_stop_sentinel.sh — a STOP file dropped before the
# supervisor ever starts must short-circuit before the first session is
# ever launched. Exit 24, and the mock must never have been invoked.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
mkrunmd "$STATE"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":6}
EOF

: > "$STATE/STOP"

export RELAY_SKIP_PROBE=1
export RELAY_MOCK_SCRIPT="work"

mkconsent "$STATE"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

JOURNAL="$STATE/journal.log"

assert_rc 24 "$RC" "c060_rc"
assert_grep "$JOURNAL" 'stop\.requested' "c060_stop_requested_journaled"
assert_no_file "$RELAY_MOCK_DIR/actions" "c060_mock_never_invoked"

exit 0
