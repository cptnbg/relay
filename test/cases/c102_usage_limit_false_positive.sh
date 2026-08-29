# test/cases/c102_usage_limit_false_positive.sh — a SUCCESSFUL session whose
# own result text says "429", "rate limit", "quota" and "resets at" must not be
# mistaken for a usage limit.
#
# Regression. Detection used to grep the whole session log, so any session log
# containing the digits 429 anywhere — including inside the randomly generated
# session uuid, which is how this was found — was discarded and re-run. Two
# consequences, both bad: an overnight run could spin forever without ever
# counting a session, and repository content that reaches the model's final
# message became a lever on the supervisor's control flow.
#
# The envelope now decides: is_error false is never a usage limit.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
mkrunmd "$STATE"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":4,"on_limit":"wait"}
EOF

export RELAY_SKIP_PROBE=1
export RELAY_BACKOFF_BASE=1
export RELAY_MOCK_SCRIPT="noisy,complete"

mkconsent "$STATE"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

JOURNAL="$STATE/journal.log"

assert_rc 0 "$RC" "c102_rc"
assert_no_grep "$JOURNAL" 'usage_limit' "c102_no_usage_limit_detected"

# Two behaviours scripted, two invocations: no retry was inserted.
ACTIONSCNT=$(wc -l < "$RELAY_MOCK_DIR/actions" | tr -d ' ')
assert_eq "2" "$ACTIONSCNT" "c102_no_extra_invocation"
assert_json "$STATE/state.json" '.session_count' "2" "c102_both_sessions_counted"

# Control: the noisy text really did reach the log the old code was grepping.
# Without this the test would still pass if the mock had quietly stopped
# emitting it, proving nothing.
SLOG1=$(ls "$STATE"/sessions/001-*.log 2>/dev/null | head -1)
assert_grep "$SLOG1" '429' "c102_control_noisy_text_present"
assert_grep "$SLOG1" 'rate limit' "c102_control_noisy_prose_present"

exit 0
