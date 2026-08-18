# test/hook/h070_truncated_final_line.sh — valid entries followed by a
# deliberately truncated, invalid-JSON final line (simulating a transcript
# write cut off mid-flush): the hook must still report the pct from the
# last COMPLETE entry, ignoring the garbage tail.
HOOK="$ROOT/plugins/relay/hooks/relay-ctx.sh"
SID="11111111-2222-3333-4444-555555555555"

RELAY_DIR="$PWD/relay-dir"
mkdir -p "$RELAY_DIR"
printf '{}' > "$RELAY_DIR/state.json"
: > "$RELAY_DIR/.relay"

TRANSCRIPT="$PWD/transcript.jsonl"
mktranscript "$TRANSCRIPT" 65 200000 "truncated"

PAYLOAD_FILE="$PWD/payload.json"
jq -nc --arg sid "$SID" --arg tp "$TRANSCRIPT" \
  '{session_id:$sid, transcript_path:$tp}' > "$PAYLOAD_FILE"

OUT_FILE="$PWD/out.json"
RELAY_SESSION_ID="$SID" RELAY_DIR="$RELAY_DIR" \
  "$HOOK" < "$PAYLOAD_FILE" > "$OUT_FILE" 2>"$PWD/err.log"
RC=$?

assert_rc 0 "$RC" "h070_rc"
assert_stdout_json_only "$OUT_FILE" "h070_stdout_json_only"
assert_contains "$(cat "$OUT_FILE")" "CONTEXT CHECKPOINT" "h070_emits"
assert_contains "$(cat "$OUT_FILE")" "65%" "h070_reports_correct_pct"

STATE_FILE="$RELAY_DIR/run/hook-$SID.state"
IFS='|' read -r HS_EPOCH HS_PCT HS_LEVEL HS_CALLS < "$STATE_FILE"
IFS=$' \t\n'
assert_eq "65" "$HS_PCT" "h070_state_pct"
assert_eq "1" "$HS_LEVEL" "h070_state_level"

exit 0
