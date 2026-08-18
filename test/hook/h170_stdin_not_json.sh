# test/hook/h170_stdin_not_json.sh — stdin payload is not JSON at all.
# Two scenarios: (A) the literal string "garbage" -- fails the session-id
# substring gate (G3) before JSON is ever parsed; (B) garbage text that
# happens to CONTAIN the session id as a substring -- passes G1-G3 and
# forces the code into jq's invalid-JSON handling. Both must exit 0 with
# silent stdout and no crash.
HOOK="$ROOT/plugins/relay/hooks/relay-ctx.sh"
SID="11111111-2222-3333-4444-555555555555"

RELAY_DIR="$PWD/relay-dir"
mkdir -p "$RELAY_DIR"
printf '{}' > "$RELAY_DIR/state.json"
: > "$RELAY_DIR/.relay"

# scenario A: plain garbage, no session id inside it at all
PAYLOAD_A="$PWD/payload-a.txt"
printf 'garbage\n' > "$PAYLOAD_A"
OUT_A="$PWD/out-a.json"
RELAY_SESSION_ID="$SID" RELAY_DIR="$RELAY_DIR" \
  "$HOOK" < "$PAYLOAD_A" > "$OUT_A" 2>"$PWD/err-a.log"
RC_A=$?
assert_rc 0 "$RC_A" "h170_scenarioA_rc"
assert_eq "" "$(cat "$OUT_A" 2>/dev/null)" "h170_scenarioA_stdout_empty"
assert_stdout_json_only "$OUT_A" "h170_scenarioA_json_only"

# scenario B: garbage that embeds the session id, so it clears G1-G3 and
# reaches jq trying (and failing) to parse it as JSON
PAYLOAD_B="$PWD/payload-b.txt"
printf 'garbage garbage %s garbage\n' "$SID" > "$PAYLOAD_B"
OUT_B="$PWD/out-b.json"
RELAY_SESSION_ID="$SID" RELAY_DIR="$RELAY_DIR" \
  "$HOOK" < "$PAYLOAD_B" > "$OUT_B" 2>"$PWD/err-b.log"
RC_B=$?
assert_rc 0 "$RC_B" "h170_scenarioB_rc"
assert_eq "" "$(cat "$OUT_B" 2>/dev/null)" "h170_scenarioB_stdout_empty"
assert_stdout_json_only "$OUT_B" "h170_scenarioB_json_only"

exit 0
