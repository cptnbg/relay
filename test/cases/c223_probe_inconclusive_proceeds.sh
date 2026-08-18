# c223 — probe end-to-end: the canary read is denied but the egress evidence
# file never appears (RELAY_MOCK_PROBE=inconclusive). Fail-closed applies to
# the CANARY, not to egress: an inconclusive egress check journals its
# verdict and the run proceeds — refusing here would turn every curl-less
# environment into a hard outage.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
printf '# RUN\n\nMinimal run.\n' > "$STATE/RUN.md"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":4}
EOF

export RELAY_MOCK_PROBE=inconclusive
export RELAY_MOCK_SCRIPT="work,complete"

mkconsent "$STATE"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

JOURNAL="$STATE/journal.log"

assert_rc 0 "$RC" "c223_run_completed"
assert_grep "$JOURNAL" 'probe\.egress	inconclusive host=' "c223_inconclusive_journaled"
assert_grep "$JOURNAL" 'probe\.ok' "c223_probe_ok_journaled"
assert_grep "$JOURNAL" 'complete\.verified' "c223_completed"
assert_file "$STATE/run/probe.ok" "c223_probe_cache_written"

exit 0
