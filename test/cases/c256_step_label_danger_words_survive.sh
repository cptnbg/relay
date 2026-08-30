PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"
printf '# Plan\n\n## Phase 1\n\nstep one\n\n## Phase 2\n\nstep two\n\n## Phase 3\n\nstep three\n\n## Phase 4\n\nstep four\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com \
  commit -q -m "chore: add plan.md" >/dev/null 2>&1
mkdir -p "$STATE/work"
mkrunmd "$STATE"
export RELAY_SKIP_PROBE=1

# The false-halt regression test this feature owes: a step LABEL carrying
# permission and danger vocabulary must never trip the guardrail-drift halt —
# unlike prose, a label repeats every session, so a match would halt
# deterministically, phase after phase.
printf '{"max_sessions":4}\n' > "$STATE/config.json"
mkconsent "$STATE"
jq -nc '{done:["built the auth module"], next:["wire it up"],
         files_touched:[], open_questions:[], plan_step:"enable token auth"}' \
  > "$STATE/work/continue.json"
export RELAY_MOCK_SCRIPT="noop,work,complete"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
assert_rc 0 "$?" "c256_no_halt"
assert_no_grep "$STATE/journal.log" 'handoff.guardrail-drift' "c256_no_drift_event"
assert_grep "$STATE/journal.log" 'handoff.step' "c256_step_still_journaled"
exit 0
