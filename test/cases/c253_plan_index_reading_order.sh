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

# With an index, sessions are told to read it plus ONLY their current step's
# plan section; without one, the reading order is the 1.0.x text byte for byte.
printf '{"max_sessions":4}\n' > "$STATE/config.json"
mkconsent "$STATE"
export RELAY_MOCK_SCRIPT="work,complete"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
assert_rc 0 "$?" "c253_indexed_run"
tr '\0' '\n' < "$RELAY_MOCK_DIR/argv.log" > "$PWD/p1.txt"
assert_grep "$PWD/p1.txt" 'PLAN-INDEX.md — the ordered step list' "c253_index_protocol"
assert_grep "$PWD/p1.txt" 'prefer the plan' "c253_plan_stays_canonical"
assert_no_grep "$PWD/p1.txt" 'including every amendment' "c253_full_read_replaced"

STATE2="$PWD/state2"
mkdir -p "$STATE2/work"
mkrunmd "$STATE2"
printf '{"max_sessions":4}\n' > "$STATE2/config.json"
mkconsent "$STATE2"
rm -f "$RELAY_MOCK_DIR/invocation_count" "$RELAY_MOCK_DIR/argv.log"
PROJ2="$PWD/proj2"; mkrepo "$PROJ2"
printf '# Plan\n\n1. step\n' > "$PROJ2/plan.md"
git -C "$PROJ2" add -A >/dev/null 2>&1
git -C "$PROJ2" -c user.name=mock -c user.email=mock@example.com commit -q -m p >/dev/null 2>&1
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ2" "$STATE2" >"$PWD/out2.log" 2>"$PWD/err2.log"
assert_rc 0 "$?" "c253_plain_run"
tr '\0' '\n' < "$RELAY_MOCK_DIR/argv.log" > "$PWD/q1.txt"
assert_grep "$PWD/q1.txt" 'including every amendment' "c253_no_index_keeps_old_text"
# The schema line mentions PLAN-INDEX in every prompt; what must be absent
# without an index is the reading-order PROTOCOL.
assert_no_grep "$PWD/q1.txt" 'PLAN-INDEX.md — the ordered step list' "c253_no_index_no_protocol"
exit 0
