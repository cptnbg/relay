# c222 — probe end-to-end: the canary read was denied but a host NOT on the
# network allowlist answered with a real HTTP status from inside the sandbox
# (RELAY_MOCK_PROBE=egress-open). Network confinement is not enforced, so the
# supervisor must refuse to start.
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

export RELAY_MOCK_PROBE=egress-open
export RELAY_MOCK_SCRIPT="work,complete"

mkconsent "$STATE"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

JOURNAL="$STATE/journal.log"

assert_rc 78 "$RC" "c222_refused"
assert_grep "$JOURNAL" 'probe\.egress	reachable host=' "c222_egress_verdict_reachable"
assert_grep "$JOURNAL" 'probe\.failed' "c222_probe_failed_journaled"
assert_no_grep "$JOURNAL" 'session\.start' "c222_no_session_launched"
assert_json "$STATE/state.json" '.status' "preflight-failed" "c222_status"
assert_json "$STATE/state.json" '.reason' "sandbox-not-enforced" "c222_reason"
assert_grep "$PWD/err.log" 'answered from inside the sandbox' "c222_stderr_names_the_problem"
assert_no_file "$RELAY_MOCK_DIR/actions" "c222_no_work_invocations"
assert_no_file "$STATE/run/probe.ok" "c222_no_probe_cache_written"

exit 0
