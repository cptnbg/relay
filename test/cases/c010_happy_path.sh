# test/cases/c010_happy_path.sh — work,work,complete: three sessions, the
# last one legitimately COMPLETE. Exit 0, three session.start journal lines,
# a complete.verified line, real commits landed in the toy repo, and each
# of the two productive ("work") sessions' handoffs got archived under
# $STATE/handoffs/.
#
# NOTE: only 2 handoffs archive, not 3. relay-supervisor.sh's post-session
# "if sealed COMPLETE.md; then if verify_complete; then ...; exit 0; fi"
# check runs BEFORE the handoff-archival code later in the same loop body,
# so the winning "complete" session's own handoff is never copied into
# handoffs/ — the run exits as soon as completion is verified.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
printf '# RUN\n\nBuild out src/ incrementally until COMPLETE.md is sealed.\n' > "$STATE/RUN.md"
printf '# Plan\n\n1. step one\n2. step two\n3. step three\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":6,"stall_limit":3,"fastfail_limit":3}
EOF

export RELAY_SKIP_PROBE=1
export RELAY_MOCK_SCRIPT="work,work,complete"

BEFORE_COMMITS=$(git -C "$PROJ" rev-list --count HEAD)

mkconsent "$STATE"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

JOURNAL="$STATE/journal.log"
AFTER_COMMITS=$(git -C "$PROJ" rev-list --count HEAD)

assert_rc 0 "$RC" "c010_rc"
assert_between "$AFTER_COMMITS" "$((BEFORE_COMMITS + 2))" "$((BEFORE_COMMITS + 2))" "c010_two_new_commits"

STARTCNT=$(grep -Fc -- "$(printf '\tsession.start\t')" "$JOURNAL")
assert_eq "3" "$STARTCNT" "c010_three_session_starts"

assert_grep "$JOURNAL" 'complete\.verified' "c010_complete_verified"

assert_dir "$STATE/handoffs" "c010_handoffs_dir_exists"
HCOUNT=$(ls "$STATE/handoffs" | wc -l | tr -d ' ')
assert_eq "2" "$HCOUNT" "c010_two_archived_handoffs"

exit 0
