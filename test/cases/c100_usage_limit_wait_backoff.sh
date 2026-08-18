# test/cases/c100_usage_limit_wait_backoff.sh — usagelimit,usagelimit,work,
# complete with on_limit=wait: the two usage-limit attempts must back off
# and retry rather than counting against the session budget. Final exit 0,
# journal shows usage_limit.backoff at least twice, and — crucially — the
# limit attempts must not have consumed N: relay-supervisor.sh's limit
# branch decrements N and `continue`s, so only 2 real sessions ("work" and
# "complete") should ever be counted, even though 4 mock invocations happen.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
printf '# RUN\n\nMinimal run.\n' > "$STATE/RUN.md"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":8,"on_limit":"wait","max_usage_retries":20}
EOF

export RELAY_SKIP_PROBE=1
export RELAY_BACKOFF_BASE=1
export RELAY_MOCK_SCRIPT="usagelimit,usagelimit,work,complete"

mkconsent "$STATE"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

JOURNAL="$STATE/journal.log"

assert_rc 0 "$RC" "c100_rc"

BACKOFFCNT=$(grep -Fc -- "$(printf '\tusage_limit.backoff\t')" "$JOURNAL")
assert_eq "2" "$BACKOFFCNT" "c100_two_backoffs"

# RELAY_BACKOFF_BASE=1 (set by the runner) must actually compress the waits:
# retry 1 waits base*1=1s, retry 2 waits base*2=2s. A regression back to a
# fixed 5s sleep step would journal the same wait= values but sleep ~5s per
# retry, so assert BOTH the journaled schedule and the observed gap between
# each backoff line and the session.start that follows it.
assert_grep "$JOURNAL" 'usage_limit\.backoff	wait=1s retry=1' "c100_first_wait_is_base_x1"
assert_grep "$JOURNAL" 'usage_limit\.backoff	wait=2s retry=2' "c100_second_wait_is_base_x2"

GAPS=$(awk -F'\t' '
  $2 == "usage_limit.backoff" { pending = $1; next }
  pending != "" && $2 == "session.start" { print $1 - pending; pending = "" }
' "$JOURNAL")
GAPCNT=0
for g in $GAPS; do
  GAPCNT=$((GAPCNT + 1))
  assert_between "$g" "0" "4" "c100_backoff_gap_${GAPCNT}_is_seconds_not_fixed_5s_steps"
done
assert_eq "2" "$GAPCNT" "c100_two_measured_backoff_gaps"

# 4 real mock invocations happened...
ACTIONSCNT=$(wc -l < "$RELAY_MOCK_DIR/actions" | tr -d ' ')
assert_eq "4" "$ACTIONSCNT" "c100_four_mock_invocations"

# ...but only 2 of them counted as real sessions against the budget.
assert_json "$STATE/state.json" '.session_count' "2" "c100_session_count_excludes_limit_retries"

exit 0
