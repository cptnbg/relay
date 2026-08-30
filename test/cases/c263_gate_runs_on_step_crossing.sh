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

# A gate guards the EXIT of its after_step: it fires the first time a session
# reports a step ordered PAST it, exactly once, through the same dual-anchor
# discipline as the acceptance command.
printf '{"max_sessions":6}\n' > "$STATE/config.json"
mkconsent "$STATE"
printf '{"acceptance_cmd":null,"phase_gates":[{"id":"g1","after_step":"S1","cmd":["true"]}]}\n' > "$STATE/exec.json"
mkgates_hash "$STATE"
export RELAY_MOCK_PLAN_STEP="S1,S2,S2"
export RELAY_MOCK_SCRIPT="work,work,complete"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
assert_rc 0 "$?" "c263_completed"
assert_no_grep "$STATE/journal.log" 'gate.run	id=g1.*n=1' "c263_not_fired_at_own_step"
assert_grep "$STATE/journal.log" 'gate.pass	id=g1' "c263_passed"
assert_eq "1" "$(grep -c 'gate.run' "$STATE/journal.log")" "c263_fired_exactly_once"
assert_json "$STATE/state.json" '.gates_passed' "g1" "c263_recorded_passed"
exit 0
