# test/hook/h020_soft_checkpoint.sh — at soft (62%): emits CONTEXT
# CHECKPOINT, level transitions 0 -> 1.
HOOK="$ROOT/plugins/relay/hooks/relay-ctx.sh"
SID="11111111-2222-3333-4444-555555555555"

RELAY_DIR="$PWD/relay-dir"
mkdir -p "$RELAY_DIR"
printf '{}' > "$RELAY_DIR/state.json"

TRANSCRIPT="$PWD/transcript.jsonl"
mktranscript "$TRANSCRIPT" 62

PAYLOAD_FILE="$PWD/payload.json"
jq -nc --arg sid "$SID" --arg tp "$TRANSCRIPT" \
  '{session_id:$sid, transcript_path:$tp}' > "$PAYLOAD_FILE"

OUT_FILE="$PWD/out.json"
RELAY_SESSION_ID="$SID" RELAY_DIR="$RELAY_DIR" \
  "$HOOK" < "$PAYLOAD_FILE" > "$OUT_FILE" 2>"$PWD/err.log"
RC=$?

assert_rc 0 "$RC" "h020_rc"
assert_stdout_json_only "$OUT_FILE" "h020_stdout_json_only"
assert_json "$OUT_FILE" '.hookSpecificOutput.hookEventName' "PostToolUse" "h020_event_name"
assert_contains "$(cat "$OUT_FILE")" "CONTEXT CHECKPOINT" "h020_text_checkpoint"
assert_contains "$(cat "$OUT_FILE")" "62%" "h020_text_pct"

STATE_FILE="$RELAY_DIR/run/hook-$SID.state"
assert_file "$STATE_FILE" "h020_state_file"
IFS='|' read -r HS_EPOCH HS_PCT HS_LEVEL HS_CALLS < "$STATE_FILE"
IFS=$' \t\n'
assert_eq "62" "$HS_PCT" "h020_state_pct"
assert_eq "1" "$HS_LEVEL" "h020_state_level"

exit 0
