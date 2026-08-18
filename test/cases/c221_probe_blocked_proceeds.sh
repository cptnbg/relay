# c221 — probe end-to-end, healthy sandbox: the canary read is denied and the
# egress curl fails (RELAY_MOCK_PROBE=blocked). The probe passes, its
# fingerprint is cached, and the run proceeds to completion.
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

export RELAY_MOCK_PROBE=blocked
export RELAY_MOCK_SCRIPT="work,complete"

mkconsent "$STATE"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

JOURNAL="$STATE/journal.log"

assert_rc 0 "$RC" "c221_run_completed"
assert_grep "$JOURNAL" 'probe\.start' "c221_probe_ran"
assert_grep "$JOURNAL" 'probe\.egress	blocked host=' "c221_egress_verdict_blocked"
assert_grep "$JOURNAL" 'probe\.ok' "c221_probe_ok_journaled"
assert_grep "$JOURNAL" 'complete\.verified' "c221_completed"

# The passing fingerprint is cached (40-hex) so the next run can skip the
# probe for identical settings.
assert_file "$STATE/run/probe.ok" "c221_probe_cache_written"
FP=$(tr -d '\n' < "$STATE/run/probe.ok")
case "$FP" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) : ;;
  *) _assert_fail "c221_probe_cache_is_40_hex: got [$FP]" ;;
esac

# Exactly one probe invocation, and it did not consume a session behaviour:
# the two scripted behaviours ran as sessions 1 and 2.
PROBECNT=$(grep -c 'probe mode=blocked' "$RELAY_MOCK_DIR/probe.log")
assert_eq "1" "$PROBECNT" "c221_probe_ran_once"
ACTIONSCNT=$(wc -l < "$RELAY_MOCK_DIR/actions" | tr -d ' ')
assert_eq "2" "$ACTIONSCNT" "c221_probe_did_not_consume_a_behaviour"

exit 0
