# test/hook/h030_hard_mandatory.sh — at hard (78%): emits MANDATORY
# HANDOFF, level 2.
HOOK="$ROOT/plugins/relay/hooks/relay-ctx.sh"
SID="11111111-2222-3333-4444-555555555555"

RELAY_DIR="$PWD/relay-dir"
mkdir -p "$RELAY_DIR"
printf '{}' > "$RELAY_DIR/state.json"

TRANSCRIPT="$PWD/transcript.jsonl"
mktranscript "$TRANSCRIPT" 78

PAYLOAD_FILE="$PWD/payload.json"
jq -nc --arg sid "$SID" --arg tp "$TRANSCRIPT" \
  '{session_id:$sid, transcript_path:$tp}' > "$PAYLOAD_FILE"

OUT_FILE="$PWD/out.json"
RELAY_SESSION_ID="$SID" RELAY_DIR="$RELAY_DIR" \
  "$HOOK" < "$PAYLOAD_FILE" > "$OUT_FILE" 2>"$PWD/err.log"
RC=$?

assert_rc 0 "$RC" "h030_rc"
assert_stdout_json_only "$OUT_FILE" "h030_stdout_json_only"
assert_contains "$(cat "$OUT_FILE")" "MANDATORY HANDOFF" "h030_text_mandatory"
assert_contains "$(cat "$OUT_FILE")" "78%" "h030_text_pct"

STATE_FILE="$RELAY_DIR/run/hook-$SID.state"
assert_file "$STATE_FILE" "h030_state_file"
IFS='|' read -r HS_EPOCH HS_PCT HS_LEVEL HS_CALLS < "$STATE_FILE"
IFS=$' \t\n'
assert_eq "78" "$HS_PCT" "h030_state_pct"
assert_eq "2" "$HS_LEVEL" "h030_state_level"

exit 0
