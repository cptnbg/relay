PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com \
  commit -q -m "chore: add plan.md" >/dev/null 2>&1
mkdir -p "$STATE/work"
mkrunmd "$STATE"
export RELAY_SKIP_PROBE=1

# The per-session tripwire is post-hoc BY NECESSITY (the CLI has no token
# budget flag), so what it bounds is the NEXT sessions: one breach forces a
# review, a non-breach resets the streak, and two CONSECUTIVE breaches end
# the run. RELAY_MOCK_USAGE_IN shapes per-session usage: the envelope adds
# 2048+8192+1024 = 11264 to each override.
printf '{"max_sessions":9,"review_every":50,"budget_tokens_per_session":70000}\n' > "$STATE/config.json"
mkconsent "$STATE"
# s1: 100000+11264 breach (streak 1 -> review). s2 (review): 1000+11264 ok
# (streak resets). s3: 100000+11264 breach (streak 1 again -> review).
# s4 (review): 100000+11264 breach (streak 2 -> halt).
export RELAY_MOCK_USAGE_IN="100000,1000,100000,100000"
export RELAY_MOCK_SCRIPT="work"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
assert_rc 29 "$?" "c273_halted"
assert_json "$STATE/state.json" '.status' "budget" "c273_status"
assert_json "$STATE/state.json" '.reason' "session-tokens" "c273_reason"
assert_eq "3" "$(grep -c 'session.tokens-over' "$STATE/journal.log")" "c273_three_breaches_journaled"
assert_grep "$STATE/journal.log" 'session.start	n=2 .* mode=review' "c273_first_breach_forces_review"
assert_grep "$STATE/journal.log" 'streak=2' "c273_streak_reached_two"
assert_no_grep "$STATE/journal.log" 'streak=3' "c273_halted_at_two"
# The digest carries the token line in the review session's prompt.
tr '\0' '\n' < "$RELAY_MOCK_DIR/argv.log" > "$PWD/argv.txt"
assert_grep "$PWD/argv.txt" 'tokens: ' "c273_digest_token_line"
exit 0
