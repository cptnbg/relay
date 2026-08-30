PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com \
  commit -q -m "chore: add plan.md" >/dev/null 2>&1
mkdir -p "$STATE/work"
mkrunmd "$STATE"

# permission_denials from the envelope becomes journal + state telemetry.
# CLI-authored data (probe0-permission-mode case E pins the shape); zero
# control-flow effect — the run completes exactly as it would have.
printf '{"max_sessions":4}\n' > "$STATE/config.json"
mkconsent "$STATE"
export RELAY_SKIP_PROBE=1
export RELAY_MOCK_DENIALS="Monitor,WebFetch"
export RELAY_MOCK_SCRIPT="work,complete"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
assert_rc 0 "$?" "c244_denials_never_gate"
assert_grep "$STATE/journal.log" 'session.denials	n=1 count=2' "c244_journal_count"
assert_grep "$STATE/journal.log" 'Monitor' "c244_journal_tool_a"
assert_grep "$STATE/journal.log" 'WebFetch' "c244_journal_tool_b"
assert_json "$STATE/state.json" '.denials_total' "4" "c244_totals_accumulate"
assert_json "$STATE/state.json" '.last_denial_tools | contains("Monitor")' "true" "c244_last_tools"

# No denials -> no telemetry noise.
STATE2="$PWD/state2"
mkdir -p "$STATE2/work"
mkrunmd "$STATE2"
printf '{"max_sessions":4}\n' > "$STATE2/config.json"
mkconsent "$STATE2"
unset RELAY_MOCK_DENIALS
rm -f "$RELAY_MOCK_DIR/invocation_count"
# Fresh project too: the mock's work step writes deterministic content, so a
# reused repo yields no new commit and verify_complete rightly rejects.
PROJ2="$PWD/proj2"
mkrepo "$PROJ2"
printf '# Plan\n\n1. step one\n' > "$PROJ2/plan.md"
git -C "$PROJ2" add -A >/dev/null 2>&1
git -C "$PROJ2" -c user.name=mock -c user.email=mock@example.com \
  commit -q -m "chore: add plan.md" >/dev/null 2>&1
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ2" "$STATE2" >"$PWD/out2.log" 2>"$PWD/err2.log"
assert_rc 0 "$?" "c244_clean_run"
assert_no_grep "$STATE2/journal.log" 'session.denials' "c244_silent_when_zero"
exit 0
