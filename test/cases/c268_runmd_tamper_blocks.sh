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

# The intent anchor is not a session's to edit: a change to RUN.md's
# protected region halts the run BLOCKED before anything else is even
# considered — including a COMPLETE sealed in the same session.
printf '{"max_sessions":4}\n' > "$STATE/config.json"
mkconsent "$STATE"
export RELAY_MOCK_SCRIPT="runmdedit,complete"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
assert_rc 20 "$?" "c268_blocked"
assert_grep "$STATE/journal.log" 'runmd.tampered	n=1' "c268_journaled"
assert_json "$STATE/state.json" '.reason' "run-md-tampered" "c268_reason"
assert_json "$STATE/state.json" '.tokens_total' "63675" "c268_tokens_persisted_at_halt"
assert_grep "$STATE/work/BLOCKED.md" 'protected region changed' "c268_blocked_says_what"
assert_grep "$STATE/work/BLOCKED.md" 'TAMPERED-MISSION-MARKER' "c268_diff_shows_edit"
assert_grep "$STATE/work/BLOCKED.md" 'relay:sealed' "c268_sealed"
exit 0
