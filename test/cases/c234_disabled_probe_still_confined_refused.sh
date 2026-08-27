# c234 — full-trust, but reads are STILL CONFINED: the payload was accepted
# (the hook fired) yet the canary could not be read, so `sandbox.enabled:false`
# did not take effect as configured. The operator asked for full trust and would
# otherwise get a run confined in a way neither mode describes — refuse rather
# than mislead them about which mode they are in.
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

export RELAY_MOCK_PROBE=confined
export RELAY_MOCK_SCRIPT="work,complete"

mkconsent "$STATE"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

JOURNAL="$STATE/journal.log"

assert_rc 78 "$RC" "c234_refused"
# The payload WAS accepted — this is not the dropped-payload failure.
assert_grep "$JOURNAL" 'probe\.hook.fired' "c234_hook_fired"
assert_grep "$JOURNAL" 'probe\.trust-canary.unreadable' "c234_canary_unreadable_journaled"
assert_grep "$JOURNAL" 'probe\.failed' "c234_probe_failed_journaled"
assert_no_grep "$JOURNAL" 'probe\.ok' "c234_no_probe_ok"
assert_no_grep "$JOURNAL" 'session\.start' "c234_no_session_launched"
assert_json "$STATE/state.json" '.status' "preflight-failed" "c234_status"
assert_json "$STATE/state.json" '.reason' "settings-not-accepted" "c234_reason"
assert_grep "$PWD/err.log" 'reads are still confined' "c234_stderr_names_the_problem"

assert_grep "$RELAY_MOCK_DIR/probe.log" 'probe mode=confined' "c234_mock_probe_confined_mode"
assert_no_file "$RELAY_MOCK_DIR/actions" "c234_no_work_invocations"
assert_no_file "$STATE/run/probe.ok" "c234_no_probe_cache_written"

exit 0
