# test/hook/h190_compaction_detected_reset.sh — first call at 80% (hard
# level), then a second call whose transcript reports 20%: the >=15-point
# drop means autocompact must have fired despite the thresholds, so the
# level machine resets to 0 and run/compacted.flag is created.
HOOK="$ROOT/plugins/relay/hooks/relay-ctx.sh"
SID="11111111-2222-3333-4444-555555555555"

RELAY_DIR="$PWD/relay-dir"
mkdir -p "$RELAY_DIR"
printf '{}' > "$RELAY_DIR/state.json"
: > "$RELAY_DIR/.relay"

TRANSCRIPT="$PWD/transcript.jsonl"
PAYLOAD_FILE="$PWD/payload.json"
jq -nc --arg sid "$SID" --arg tp "$TRANSCRIPT" \
  '{session_id:$sid, transcript_path:$tp}' > "$PAYLOAD_FILE"

mktranscript "$TRANSCRIPT" 80
OUT1="$PWD/out1.json"
RELAY_SESSION_ID="$SID" RELAY_DIR="$RELAY_DIR" \
  "$HOOK" < "$PAYLOAD_FILE" > "$OUT1" 2>"$PWD/err1.log"
RC1=$?
assert_rc 0 "$RC1" "h190_call1_rc"
assert_contains "$(cat "$OUT1")" "MANDATORY HANDOFF" "h190_call1_hard_emits"
assert_no_file "$RELAY_DIR/run/compacted.flag" "h190_no_flag_before_drop"

STATE_FILE="$RELAY_DIR/run/hook-$SID.state"
IFS='|' read -r E1 P1 L1 C1 < "$STATE_FILE"; IFS=$' \t\n'
assert_eq "80" "$P1" "h190_call1_pct"
assert_eq "2" "$L1" "h190_call1_level"

mktranscript "$TRANSCRIPT" 20
OUT2="$PWD/out2.json"
RELAY_SESSION_ID="$SID" RELAY_DIR="$RELAY_DIR" \
  "$HOOK" < "$PAYLOAD_FILE" > "$OUT2" 2>"$PWD/err2.log"
RC2=$?
assert_rc 0 "$RC2" "h190_call2_rc"
assert_eq "" "$(cat "$OUT2" 2>/dev/null)" "h190_call2_stdout_empty"
assert_file "$RELAY_DIR/run/compacted.flag" "h190_compacted_flag_created"

IFS='|' read -r E2 P2 L2 C2 < "$STATE_FILE"; IFS=$' \t\n'
assert_eq "20" "$P2" "h190_call2_pct"
assert_eq "0" "$L2" "h190_call2_level_reset"

exit 0
