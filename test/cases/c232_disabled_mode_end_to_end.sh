# c232 — full-trust end to end, healthy: sandbox_mode=disabled, the payload is
# accepted (the inline hook fired: RELAY_MOCK_PROBE=open), the canary was
# readable (sandbox genuinely off), the probe passes and the run completes.
# The disabled counterpart of c221.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
mkrunmd "$STATE"
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

# The proof is NOT cached in full-trust mode, deliberately. $STATE/run/probe.ok
# is reachable from Bash once the sandbox is off, so a session could author the
# very file the next start would read as evidence. Relay drops it on entry and
# never refreshes it here: every full-trust start re-proves, and one haiku probe
# is the price of not trusting session-writable evidence.
assert_no_file "$STATE/run/probe.ok" "c232_probe_not_cached_in_trust_mode"

# The probe ran once in `open` mode and did not consume a session behaviour.
PROBECNT=$(grep -c 'probe mode=open' "$RELAY_MOCK_DIR/probe.log")
assert_eq "1" "$PROBECNT" "c232_probe_ran_once"
ACTIONSCNT=$(wc -l < "$RELAY_MOCK_DIR/actions" | tr -d ' ')
assert_eq "2" "$ACTIONSCNT" "c232_probe_did_not_consume_a_behaviour"

exit 0
