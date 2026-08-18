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

# 4 real mock invocations happened...
ACTIONSCNT=$(wc -l < "$RELAY_MOCK_DIR/actions" | tr -d ' ')
assert_eq "4" "$ACTIONSCNT" "c100_four_mock_invocations"

# ...but only 2 of them counted as real sessions against the budget.
assert_json "$STATE/state.json" '.session_count' "2" "c100_session_count_excludes_limit_retries"

exit 0
