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

# A non-string plan_step invalidates the handoff — strict, like every other
# field — and the next session runs in recovery.
printf '{"max_sessions":4}\n' > "$STATE/config.json"
mkconsent "$STATE"
jq -nc '{done:["x"], next:["y"], files_touched:[], open_questions:[], plan_step:7}' \
  > "$STATE/work/continue.json"
export RELAY_MOCK_SCRIPT="noop,work,complete"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
assert_rc 0 "$?" "c257_recovered_and_completed"
assert_grep "$STATE/journal.log" 'handoff.invalid	n=1' "c257_invalid_journaled"
tr '\0' '\n' < "$RELAY_MOCK_DIR/argv.log" > "$PWD/p2.txt"
assert_grep "$PWD/p2.txt" 'RECOVERY:' "c257_next_session_recovery"
exit 0
