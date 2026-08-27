# c233 — full-trust, payload silently DROPPED: reads and egress are open (there
# is no sandbox) but the inline hook never fired, which is the signature of a
# --settings payload that failed validation and was ignored. Reads and egress
# alone cannot tell that apart from a healthy switched-off sandbox, so the hook
# marker is the whole proof. relay must refuse: EX_PREFLIGHT, no session.
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

export RELAY_MOCK_PROBE=dropped
export RELAY_MOCK_SCRIPT="work,complete"

mkconsent "$STATE"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

JOURNAL="$STATE/journal.log"

assert_rc 78 "$RC" "c233_refused"
assert_grep "$JOURNAL" 'probe\.start' "c233_probe_ran"
assert_grep "$JOURNAL" 'probe\.hook.missing' "c233_hook_missing_journaled"
assert_grep "$JOURNAL" 'probe\.failed' "c233_probe_failed_journaled"
assert_no_grep "$JOURNAL" 'probe\.ok' "c233_no_probe_ok"
assert_no_grep "$JOURNAL" 'session\.start' "c233_no_session_launched"
assert_json "$STATE/state.json" '.status' "preflight-failed" "c233_status"
assert_json "$STATE/state.json" '.reason' "settings-not-accepted" "c233_reason"
assert_grep "$PWD/err.log" 'NOT PROVABLY ACCEPTED' "c233_stderr_names_the_problem"

assert_grep "$RELAY_MOCK_DIR/probe.log" 'probe mode=dropped' "c233_mock_probe_dropped_mode"
assert_no_file "$RELAY_MOCK_DIR/actions" "c233_no_work_invocations"
assert_no_file "$STATE/run/probe.ok" "c233_no_probe_cache_written"

exit 0
