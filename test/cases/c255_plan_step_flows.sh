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
cat > "$STATE/work/PLAN-INDEX.md" <<'EOF'
# PLAN INDEX — generated at init
S1 | ## Phase 1 | step one done
S2 | ## Phase 2 | step two done
S3 | ## Phase 3 | step three done
S4 | ## Phase 4 | step four done
EOF

# plan_step: journaled, rendered under PLAN STEP:, preserved by normalization,
# truncated when overlong.
printf '{"max_sessions":4}\n' > "$STATE/config.json"
mkconsent "$STATE"
export RELAY_MOCK_PLAN_STEP="S2,S2"
export RELAY_MOCK_SCRIPT="work,complete"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
assert_rc 0 "$?" "c255_completed"
assert_grep "$STATE/journal.log" 'handoff.step	n=1 step=S2' "c255_journaled"
tr '\0' '\n' < "$RELAY_MOCK_DIR/argv.log" > "$PWD/p2.txt"
assert_grep "$PWD/p2.txt" 'PLAN STEP:' "c255_rendered_label"
assert_grep "$STATE/ledger.md" '| S2 |' "c255_ledger_column"

# Normalization preserves the field and truncates an overlong one.
STATE2="$PWD/state2"
mkdir -p "$STATE2/work"
mkrunmd "$STATE2"
# ONE session only: a later mock 'complete' would rewrite the handoff
# without the field and hide what normalization kept.
printf '{"max_sessions":1}\n' > "$STATE2/config.json"
mkconsent "$STATE2"
_long=$(printf 'S%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35)
jq -nc --arg s "${_long}${_long}" \
  '{done:["a","b","c","d","e","f","g","h","i","j","k","l","m"],
    next:["x"], files_touched:[], open_questions:[], plan_step:$s}' \
  > "$STATE2/work/continue.json"
unset RELAY_MOCK_PLAN_STEP
rm -f "$RELAY_MOCK_DIR/invocation_count"
PROJ2="$PWD/proj2"; mkrepo "$PROJ2"
printf '# Plan\n\n1. s\n' > "$PROJ2/plan.md"
git -C "$PROJ2" add -A >/dev/null 2>&1
git -C "$PROJ2" -c user.name=mock -c user.email=mock@example.com commit -q -m p >/dev/null 2>&1
export RELAY_MOCK_SCRIPT="noop"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ2" "$STATE2" >"$PWD/out2.log" 2>"$PWD/err2.log"
assert_grep "$STATE2/journal.log" 'handoff.normalized' "c255_normalize_fired"
assert_json "$STATE2/work/continue.json" '.plan_step | length' "64" "c255_step_truncated_kept"
assert_json "$STATE2/work/continue.json" '.done | length' "12" "c255_arrays_still_capped"
exit 0
