# test/cases/c109_review_cadence_measures_from_last_review.sh — review cadence
# is measured from the last review, not from the session number modulo the
# interval.
#
# Regression from a long client run. The schedule was `N % review_every`, which is
# stateless: session 8 ran a review under review_every=4, the interval was then
# lowered to 3 between runs, and session 9 (9 % 3 == 0) was scheduled to review
# again — against a handoff whose first line said not to re-audit. A second
# consecutive audit costs a session and learns nothing.
#
# Here: an interval of 3 with a review already recorded at session 2 must NOT
# review at session 3, and must review once the gap actually reaches 3.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
mkrunmd "$STATE"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":5,"review_every":3}
EOF

# Resume-shaped state: two sessions already run, the second of which reviewed.
cat > "$STATE/state.json" <<'EOF'
{"run_id":"c109","status":"running","session_count":"2","last_review_n":"2","next_mode":"normal","next_tier":"opus","commits_at_start":"2"}
EOF

export RELAY_SKIP_PROBE=1
export RELAY_MOCK_SCRIPT="work"

mkconsent "$STATE"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"

JOURNAL="$STATE/journal.log"

# Session 3 is one after the review: too soon, whatever 3 % 3 says.
assert_grep "$JOURNAL" 'session\.start.*n=3 .*mode=normal' "c109_session3_not_a_review"
assert_no_grep "$JOURNAL" 'session\.start.*n=3 .*mode=review' "c109_session3_really_not_a_review"

# Session 5 is three after the last review: due.
assert_grep "$JOURNAL" 'session\.start.*n=5 .*mode=review' "c109_session5_reviews"

# And the run recorded it, so the next interval is measured from there.
assert_json "$STATE/state.json" '.last_review_n' "5" "c109_last_review_recorded"

exit 0
