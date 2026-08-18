# c149 — plan.changed. A session amends the canonical plan file (the planedit
# mock behaviour appends a step and commits); the supervisor must notice the
# hash change, journal plan.changed with both hashes, and record the new hash
# in state.json.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
printf '# RUN\n\nMinimal run.\n' > "$STATE/RUN.md"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

OLD_HASH=$(git hash-object "$PROJ/plan.md")

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":4}
EOF

export RELAY_SKIP_PROBE=1
export RELAY_MOCK_SCRIPT="planedit,complete"

mkconsent "$STATE"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

JOURNAL="$STATE/journal.log"
NEW_HASH=$(git hash-object "$PROJ/plan.md")

assert_rc 0 "$RC" "c149_rc"
assert_ne "$OLD_HASH" "$NEW_HASH" "c149_plan_actually_changed"
assert_grep "$JOURNAL" "plan\.changed	old=$OLD_HASH new=$NEW_HASH" "c149_plan_changed_journaled_with_hashes"
assert_json "$STATE/state.json" '.plan_hash' "$NEW_HASH" "c149_state_tracks_new_hash"

exit 0
