# c232 — full-trust end to end, healthy: sandbox_mode=disabled, the payload is
# accepted (the inline hook fired: RELAY_MOCK_PROBE=open), the canary was
# readable (sandbox genuinely off), the probe passes and the run completes.
# The disabled counterpart of c221.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
printf '# RUN\n\nMinimal run.\n' > "$STATE/RUN.md"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":4,"sandbox_mode":"disabled"}
EOF

export RELAY_MOCK_PROBE=open
export RELAY_MOCK_SCRIPT="work,complete"

mkconsent "$STATE"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

JOURNAL="$STATE/journal.log"

assert_rc 0 "$RC" "c232_run_completed"
assert_grep "$JOURNAL" 'sandbox\.mode.disabled' "c232_mode_journaled"
assert_grep "$JOURNAL" 'probe\.start' "c232_probe_ran"
assert_grep "$JOURNAL" 'probe\.hook.fired' "c232_hook_fired"
assert_grep "$JOURNAL" 'probe\.trust-canary.readable' "c232_canary_readable"
assert_grep "$JOURNAL" 'probe\.ok' "c232_probe_ok_journaled"
assert_grep "$JOURNAL" 'complete\.verified' "c232_completed"

# The mode is on the status surface, and the payload sent really had the sandbox
# switched off.
assert_json "$STATE/state.json" '.sandbox_mode' "disabled" "c232_state_records_mode"
assert_json "$RELAY_MOCK_DIR/flags-last.json" \
  '(.settings | fromjson | .sandbox.enabled) == false' "true" "c232_payload_sandbox_off"

# The passing fingerprint is cached (40-hex).
assert_file "$STATE/run/probe.ok" "c232_probe_cache_written"
FP=$(tr -d '\n' < "$STATE/run/probe.ok")
case "$FP" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) : ;;
  *) _assert_fail "c232_probe_cache_is_40_hex: got [$FP]" ;;
esac

# The probe ran once in `open` mode and did not consume a session behaviour.
PROBECNT=$(grep -c 'probe mode=open' "$RELAY_MOCK_DIR/probe.log")
assert_eq "1" "$PROBECNT" "c232_probe_ran_once"
ACTIONSCNT=$(wc -l < "$RELAY_MOCK_DIR/actions" | tr -d ' ')
assert_eq "2" "$ACTIONSCNT" "c232_probe_did_not_consume_a_behaviour"

exit 0
