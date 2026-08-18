# test/cases/c020_complete_first_session.sh — a lone "complete" session, no
# prior work, must still exit 0. NOTE: verify_complete requires a NEW commit
# beyond baseline (relay-supervisor.sh's "no commits were made" check), and
# the mock's "complete" behaviour never itself touches the project tree —
# only $STATE/work/COMPLETE.md and $STATE/work/continue.json. To make a single
# "complete" session genuinely satisfy that check we leave plan.md
# UNCOMMITTED: the mock's own `git_commit` helper does a blind `git add -A`,
# so that scaffold file becomes the first real commit. This is deliberate,
# not a workaround for a bug — see the final report for the full note.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
printf '# RUN\n\nMinimal run: one session should finish the job.\n' > "$STATE/RUN.md"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":4}
EOF

export RELAY_SKIP_PROBE=1
export RELAY_ALLOW_DIRTY=1
export RELAY_MOCK_SCRIPT="complete"

BEFORE_COMMITS=$(git -C "$PROJ" rev-list --count HEAD)

mkconsent "$STATE"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

JOURNAL="$STATE/journal.log"
AFTER_COMMITS=$(git -C "$PROJ" rev-list --count HEAD)

assert_rc 0 "$RC" "c020_rc"
assert_grep "$JOURNAL" 'complete\.verified' "c020_complete_verified"

STARTCNT=$(grep -Fc -- "$(printf '\tsession.start\t')" "$JOURNAL")
assert_eq "1" "$STARTCNT" "c020_exactly_one_session"

assert_between "$AFTER_COMMITS" "$((BEFORE_COMMITS + 1))" "$((BEFORE_COMMITS + 1))" "c020_one_new_commit"

exit 0
