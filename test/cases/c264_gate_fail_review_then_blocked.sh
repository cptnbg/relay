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
cat > "$STATE/work/PLAN-INDEX.md" <<'EOF'
# PLAN INDEX
S1 | ## Phase 1 | one done
S2 | ## Phase 2 | two done
EOF

# First failure of a gate: forced review + the gate output injected as DATA.
# Second failure of the SAME gate: sealed BLOCKED — the owner-chosen boundary
# where autonomy ends because correctness can no longer be assumed.
printf '{"max_sessions":8,"review_every":50}\n' > "$STATE/config.json"
mkconsent "$STATE"
printf '{"acceptance_cmd":null,"phase_gates":[{"id":"g1","after_step":"S1","cmd":["sh","-c","echo GATE-MARKER-OUT; exit 1"]}]}\n' > "$STATE/exec.json"
mkgates_hash "$STATE"
export RELAY_MOCK_PLAN_STEP="S2,S2,S2"
export RELAY_MOCK_SCRIPT="work,work,work"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
assert_rc 20 "$?" "c264_blocked"
assert_eq "2" "$(grep -c 'gate.fail' "$STATE/journal.log")" "c264_two_failures"
assert_grep "$STATE/journal.log" 'session.start	n=2 .* mode=review' "c264_review_between_failures"
tr '\0' '\n' < "$RELAY_MOCK_DIR/argv.log" > "$PWD/argv.txt"
assert_grep "$PWD/argv.txt" '<gate-output id="g1"' "c264_feedback_injected"
assert_grep "$PWD/argv.txt" 'GATE-MARKER-OUT' "c264_output_carried"
assert_grep "$STATE/work/BLOCKED.md" 'failed twice' "c264_blocked_says_why"
assert_json "$STATE/state.json" '.reason' "gate-failed" "c264_reason"
exit 0
