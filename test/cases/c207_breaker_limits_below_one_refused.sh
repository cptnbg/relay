# `stall_limit: 0` and `fastfail_limit: 0` are numeric, pass every existing
# validation, and brick the run at session 1.
#
# The reason is that both circuit breakers are tested UNCONDITIONALLY, outside
# the "was this session unproductive" branch: `[ "$STALL" -ge "$STALL_LIMIT" ]`
# with a limit of 0 is true when STALL is still 0, so a first session that did
# everything right ends the run EX_STALLED with a journal reporting a stall that
# never happened. `review_every` already refused to act below 1; these two had
# no floor at all.
#
# A limit of exactly 1 is legal — halt on the first unproductive session — but it
# silently removes the escalation that fires one session BEFORE the breaker,
# because the streak is already at the limit by the time it is tested. That is a
# choice rather than a mistake, so it is journaled, not refused.
export RELAY_SKIP_PROBE=1
export RELAY_MOCK_SCRIPT="work,complete"

# _run <name> <config-json> -> sets RC and STATE_DIR
#
# A fresh repository per sub-run, deliberately. Six supervisors run in this one
# sandbox; sharing a repo makes each run's commit count depend on the ones
# before it, and `verify_complete` then rejects a perfectly good COMPLETE for
# "no commits were made". The mock's invocation counter is a FILE that outlives
# a run and is reset for the same reason.
_run() {
  PROJ="$PWD/proj-$1"
  mkrepo "$PROJ"
  printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
  git -C "$PROJ" add -A >/dev/null 2>&1
  git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com \
    commit -q -m "chore: add plan.md" >/dev/null 2>&1

  STATE_DIR="$PWD/$1"
  mkdir -p "$STATE_DIR/work"
  mkrunmd "$STATE_DIR"
  printf '%s\n' "$2" > "$STATE_DIR/config.json"
  mkconsent "$STATE_DIR"
  rm -f "$RELAY_MOCK_DIR/invocation_count"
  bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE_DIR" \
    >"$PWD/$1.out" 2>"$PWD/$1.err"
  RC=$?
}

_run zero_stall '{"max_sessions":3,"stall_limit":0}'
assert_rc 78 "$RC" "c207_zero_stall_limit_refused"
assert_grep "$STATE_DIR/journal.log" 'config\.limit-below-one' "c207_zero_stall_journaled"
assert_grep "$PWD/zero_stall.err" 'stall_limit' "c207_zero_stall_named"
assert_no_grep "$STATE_DIR/journal.log" 'session\.start' "c207_zero_stall_no_session"

_run zero_ff '{"max_sessions":3,"fastfail_limit":0}'
assert_rc 78 "$RC" "c207_zero_fastfail_limit_refused"
assert_grep "$PWD/zero_ff.err" 'fastfail_limit' "c207_zero_fastfail_named"

# Both at once: both are named, so the operator fixes them in one pass rather
# than discovering the second on the next attempt.
_run zero_both '{"max_sessions":3,"stall_limit":0,"fastfail_limit":0}'
assert_rc 78 "$RC" "c207_both_refused"
assert_grep "$PWD/zero_both.err" 'stall_limit fastfail_limit' "c207_both_named_together"

# A negative value is refused by the existing numeric check, not this one — the
# `-` makes it non-numeric. Same exit, different journal line; asserted so the
# two guards are not conflated later.
_run negative '{"max_sessions":3,"stall_limit":-1}'
assert_rc 78 "$RC" "c207_negative_refused"
assert_grep "$STATE_DIR/journal.log" 'config\.non-numeric' "c207_negative_is_the_numeric_guard"

# 1 is allowed and runs, and says out loud that escalation cannot fire.
_run one '{"max_sessions":3,"stall_limit":1,"fastfail_limit":1}'
assert_rc 0 "$RC" "c207_limit_of_one_runs"
assert_grep "$STATE_DIR/journal.log" 'config\.no-escalation-window' "c207_limit_of_one_journaled"

# The default configuration must not trip any of this.
_run default '{"max_sessions":3}'
assert_rc 0 "$RC" "c207_defaults_run"
assert_no_grep "$STATE_DIR/journal.log" 'config\.limit-below-one' "c207_defaults_not_flagged"
assert_no_grep "$STATE_DIR/journal.log" 'config\.no-escalation-window' "c207_defaults_no_warning"

exit 0
