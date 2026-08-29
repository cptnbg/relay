# c112 — the CLI's transport envelope carries is_error:true +
# api_error_status:429 and NOTHING matching LIMIT_RE anywhere (subtype,
# result, stop_reason, terminal_reason, stderr). The supervisor's
# "unambiguous 429" rung must detect it, back off, and resume — proving the
# envelope rung itself, not the text heuristics, drives the decision.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
mkrunmd "$STATE"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":8,"on_limit":"wait","max_usage_retries":20}
EOF

export RELAY_SKIP_PROBE=1
export RELAY_BACKOFF_BASE=1
export RELAY_MOCK_SCRIPT="limit429,work,complete"

mkconsent "$STATE"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

JOURNAL="$STATE/journal.log"

assert_rc 0 "$RC" "c112_rc"

BACKOFFCNT=$(grep -Fc -- "$(printf '\tusage_limit.backoff\t')" "$JOURNAL")
assert_eq "1" "$BACKOFFCNT" "c112_envelope_429_triggered_backoff"

ACTIONSCNT=$(wc -l < "$RELAY_MOCK_DIR/actions" | tr -d ' ')
assert_eq "3" "$ACTIONSCNT" "c112_three_mock_invocations"

assert_json "$STATE/state.json" '.session_count' "2" "c112_retry_not_counted_as_session"

# Rung isolation: the stderr rung must have had nothing to bite on. The
# limit429 behaviour writes nothing to stderr, so no session .err file may
# contain a LIMIT_RE-shaped token.
for _e in "$STATE"/sessions/*.log.err; do
  [ -f "$_e" ] || continue
  if grep -qiE 'limit|429|quota|overloaded' "$_e"; then
    _assert_fail "c112_stderr_rung_isolated: $_e contains limit-shaped text"
  fi
done

# And the envelope really was the ambiguity-free shape: exactly one session
# log carries api_error_status 429 (the retried slot re-uses the 001- prefix
# with a fresh session id, so select by content, not by name), and that log's
# result text contains no LIMIT_RE-shaped phrase.
LIMIT_LOGS=0
for _l in "$STATE"/sessions/*.log; do
  [ -f "$_l" ] || continue
  if [ "$(jq -r '.api_error_status // empty' "$_l" 2>/dev/null)" = "429" ]; then
    LIMIT_LOGS=$((LIMIT_LOGS + 1))
    assert_no_grep "$_l" 'usage limit' "c112_result_text_has_no_limit_phrase"
  fi
done
assert_eq "1" "$LIMIT_LOGS" "c112_exactly_one_429_envelope"

exit 0
