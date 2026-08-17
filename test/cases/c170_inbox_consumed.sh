# test/cases/c170_inbox_consumed.sh — an operator note dropped in
# $STATE/INBOX.md before the run must be consumed on the first loop
# iteration: journal records inbox.consumed, INBOX.md is emptied (not
# deleted), and the note's content reaches $STATE/run/inbox-current.md.
#
# NOTE: relay-supervisor.sh's inbox handling runs at the TOP of every loop
# iteration, not just the first: once INBOX.md is empty, later iterations
# take the "else" branch and unconditionally truncate
# $STATE/run/inbox-current.md back to empty. So a multi-session run (e.g.
# work,complete) would wipe inbox-current.md again on iteration 2, well
# before we ever get to check it. To observe the note where it actually
# lands, this test runs exactly ONE session — using the same
# uncommitted-plan.md + RELAY_ALLOW_DIRTY trick as c020 so that single
# "complete" session still satisfies verify_complete's "a new commit must
# exist" check.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
printf '# RUN\n\nMinimal run.\n' > "$STATE/RUN.md"
printf '# Plan\n\n1. step one\n2. step two\n' > "$PROJ/plan.md"

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":4}
EOF

printf 'Please prioritize the auth module next.\n' > "$STATE/INBOX.md"

export RELAY_SKIP_PROBE=1
export RELAY_ALLOW_DIRTY=1
export RELAY_MOCK_SCRIPT="complete"

bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

JOURNAL="$STATE/journal.log"

assert_rc 0 "$RC" "c170_rc"
assert_grep "$JOURNAL" 'inbox\.consumed' "c170_inbox_consumed_journaled"

STARTCNT=$(grep -Fc -- "$(printf '\tsession.start\t')" "$JOURNAL")
assert_eq "1" "$STARTCNT" "c170_exactly_one_session"

assert_file "$STATE/INBOX.md" "c170_inbox_file_still_exists"
INBOX_SZ=$(wc -c < "$STATE/INBOX.md" | tr -d ' ')
assert_eq "0" "$INBOX_SZ" "c170_inbox_emptied"

assert_grep "$STATE/run/inbox-current.md" 'auth module' "c170_note_reached_inbox_current"

exit 0
