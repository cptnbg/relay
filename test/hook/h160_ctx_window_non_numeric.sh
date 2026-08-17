# test/hook/h160_ctx_window_non_numeric.sh — RELAY_CTX_WINDOW set to a
# non-numeric value: falls back to the 200000 default, no crash.
HOOK="$ROOT/plugins/relay/hooks/relay-ctx.sh"
SID="11111111-2222-3333-4444-555555555555"

RELAY_DIR="$PWD/relay-dir"
mkdir -p "$RELAY_DIR"
printf '{}' > "$RELAY_DIR/state.json"

TRANSCRIPT="$PWD/transcript.jsonl"
mktranscript "$TRANSCRIPT" 65 200000

PAYLOAD_FILE="$PWD/payload.json"
jq -nc --arg sid "$SID" --arg tp "$TRANSCRIPT" \
  '{session_id:$sid, transcript_path:$tp}' > "$PAYLOAD_FILE"

OUT_FILE="$PWD/out.json"
RELAY_SESSION_ID="$SID" RELAY_DIR="$RELAY_DIR" RELAY_CTX_WINDOW="abc" \
  "$HOOK" < "$PAYLOAD_FILE" > "$OUT_FILE" 2>"$PWD/err.log"
RC=$?

assert_rc 0 "$RC" "h160_rc"
assert_stdout_json_only "$OUT_FILE" "h160_stdout_json_only"
assert_contains "$(cat "$OUT_FILE")" "65%" "h160_pct_matches_200000_fallback"

STATE_FILE="$RELAY_DIR/run/hook-$SID.state"
assert_file "$STATE_FILE" "h160_state_file"
IFS='|' read -r HS_EPOCH HS_PCT HS_LEVEL HS_CALLS < "$STATE_FILE"
IFS=$' \t\n'
assert_eq "65" "$HS_PCT" "h160_state_pct"

exit 0
