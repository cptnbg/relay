# c220 — probe end-to-end: the denyRead canary was READABLE inside the probe
# session (RELAY_MOCK_PROBE=leak). Sandbox enforcement is unproven, so the
# supervisor must refuse to start: EX_PREFLIGHT, probe.failed journaled,
# status preflight-failed / sandbox-not-enforced, and no work session ever
# launched.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
mkrunmd "$STATE"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":4}
EOF

export RELAY_MOCK_PROBE=leak
export RELAY_MOCK_SCRIPT="work,complete"

mkconsent "$STATE"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

JOURNAL="$STATE/journal.log"

assert_rc 78 "$RC" "c220_refused"
assert_grep "$JOURNAL" 'probe\.start' "c220_probe_ran"
assert_grep "$JOURNAL" 'probe\.failed' "c220_probe_failed_journaled"
assert_no_grep "$JOURNAL" 'probe\.ok' "c220_no_probe_ok"
assert_no_grep "$JOURNAL" 'session\.start' "c220_no_session_launched"
assert_json "$STATE/state.json" '.status' "preflight-failed" "c220_status"
assert_json "$STATE/state.json" '.reason' "sandbox-not-enforced" "c220_reason"
assert_grep "$PWD/err.log" 'SANDBOX NOT ENFORCED' "c220_stderr_names_the_problem"

# The mock really served the probe (leak mode), and no work session consumed
# a behaviour.
assert_grep "$RELAY_MOCK_DIR/probe.log" 'probe mode=leak' "c220_mock_probe_leak_mode"
assert_no_file "$RELAY_MOCK_DIR/actions" "c220_no_work_invocations"
assert_no_file "$STATE/run/probe.ok" "c220_no_probe_cache_written"

exit 0
