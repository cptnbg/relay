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

# The legitimate-edit path: stop, edit, resume. A fresh supervisor baselines
# whatever RUN.md says at launch, so the operator's own edit never re-halts.
printf '{"max_sessions":4}\n' > "$STATE/config.json"
mkconsent "$STATE"
export RELAY_MOCK_SCRIPT="runmdedit"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
assert_rc 20 "$?" "c271_first_run_blocked"

rm -f "$STATE/work/BLOCKED.md"
printf '# RUN (operator edited)\n\nNew mission text.\n\n## Course corrections\n' > "$STATE/work/RUN.md"
rm -f "$RELAY_MOCK_DIR/invocation_count"
PROJ2="$PWD/proj2"; mkrepo "$PROJ2"
printf '# Plan\n\n1. s\n' > "$PROJ2/plan.md"
git -C "$PROJ2" add -A >/dev/null 2>&1
git -C "$PROJ2" -c user.name=mock -c user.email=mock@example.com commit -q -m p >/dev/null 2>&1
export RELAY_MOCK_SCRIPT="work,complete"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ2" "$STATE" >"$PWD/out2.log" 2>"$PWD/err2.log"
assert_rc 0 "$?" "c271_resume_accepts_edit"
assert_eq "1" "$(grep -c 'runmd.tampered' "$STATE/journal.log")" "c271_no_second_halt"
exit 0
