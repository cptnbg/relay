PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"
printf '# Plan\n\n## Phase 1\n\none\n\n## Phase 2\n\ntwo\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com \
  commit -q -m "chore: add plan.md" >/dev/null 2>&1
mkdir -p "$STATE/work"
mkrunmd "$STATE"
export RELAY_SKIP_PROBE=1

# A run that never reported steps still cannot COMPLETE past its gates: every
# unpassed gate runs at verification, converting refusal into verification
# with commands a human already approved — same guarantee, zero livelock.
printf '{"max_sessions":6}\n' > "$STATE/config.json"
mkconsent "$STATE"
printf '{"acceptance_cmd":null,"phase_gates":[{"id":"g1","after_step":"S9","cmd":["true"]}]}\n' > "$STATE/exec.json"
mkgates_hash "$STATE"
export RELAY_MOCK_SCRIPT="work,complete"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
assert_rc 0 "$?" "c266_completed"
assert_grep "$STATE/journal.log" 'gate.pass	id=g1' "c266_gate_ran_at_verify"
assert_grep "$STATE/journal.log" 'complete.verified' "c266_verified_after_gate"

# And a failing gate rejects COMPLETE, then blocks on its second strike.
STATE2="$PWD/state2"
mkdir -p "$STATE2/work"
mkrunmd "$STATE2"
printf '{"max_sessions":6}\n' > "$STATE2/config.json"
mkconsent "$STATE2"
printf '{"acceptance_cmd":null,"phase_gates":[{"id":"g1","after_step":"S9","cmd":["false"]}]}\n' > "$STATE2/exec.json"
mkgates_hash "$STATE2"
PROJ2="$PWD/proj2"; mkrepo "$PROJ2"
printf '# Plan\n\n1. s\n' > "$PROJ2/plan.md"
git -C "$PROJ2" add -A >/dev/null 2>&1
git -C "$PROJ2" -c user.name=mock -c user.email=mock@example.com commit -q -m p >/dev/null 2>&1
rm -f "$RELAY_MOCK_DIR/invocation_count"
export RELAY_MOCK_SCRIPT="work,complete,complete"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ2" "$STATE2" >"$PWD/out2.log" 2>"$PWD/err2.log"
assert_rc 20 "$?" "c266_failing_gate_blocks"
assert_grep "$STATE2/journal.log" 'complete.rejected	phase gate g1 failed' "c266_rejection_reason"
assert_json "$STATE2/state.json" '.reason' "gate-failed" "c266_two_strike_reason"
exit 0
