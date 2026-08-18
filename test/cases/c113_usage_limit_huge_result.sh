# c113 — usage-limit detection with a >16KB result string, both ways:
#   session 1 (limit429big):  api_error_status 429 + huge result — the
#                             envelope rung must still fire.
#   session 2 (limittextbig): NO api_error_status; the LIMIT_RE match sits in
#                             the first 8KB of a >16KB result — the text rung
#                             must fire. This is the exact fixture shape that
#                             hid the pipefail/SIGPIPE bug in usage_limited.
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
export RELAY_MOCK_SCRIPT="limit429big,limittextbig,work,complete"

mkconsent "$STATE"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

JOURNAL="$STATE/journal.log"

assert_rc 0 "$RC" "c113_rc"

BACKOFFCNT=$(grep -Fc -- "$(printf '\tusage_limit.backoff\t')" "$JOURNAL")
assert_eq "2" "$BACKOFFCNT" "c113_both_huge_results_detected"

ACTIONSCNT=$(wc -l < "$RELAY_MOCK_DIR/actions" | tr -d ' ')
assert_eq "4" "$ACTIONSCNT" "c113_four_mock_invocations"

assert_json "$STATE/state.json" '.session_count' "2" "c113_retries_not_counted_as_sessions"
assert_grep "$JOURNAL" 'complete\.verified' "c113_run_recovered_and_completed"

# Prove the fixtures really were huge: at least one session log must exceed
# 16KB of result text.
HUGE=0
for _l in "$STATE"/sessions/*.log; do
  [ -f "$_l" ] || continue
  _rlen=$(jq -r '(.result // "") | length' "$_l" 2>/dev/null)
  case "$_rlen" in ''|*[!0-9]*) _rlen=0 ;; esac
  [ "$_rlen" -gt 16384 ] && HUGE=$((HUGE + 1))
done
assert_between "$HUGE" "1" "4" "c113_at_least_one_result_over_16kb"

exit 0
