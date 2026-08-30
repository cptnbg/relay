# Every 8th call rescans regardless of the throttle clock: a single-call
# context jump is seen within at most seven further calls, whatever LAST_PCT
# claimed. Bounded staleness in CALLS, not seconds.
HOOK="$ROOT/plugins/relay/hooks/relay-ctx.sh"
SID="11111111-2222-3333-4444-555555555555"
RELAY_DIR="$PWD/relay-dir"
mkdir -p "$RELAY_DIR/run"
: > "$RELAY_DIR/.relay"
TRANSCRIPT="$PWD/transcript.jsonl"
mktranscript "$TRANSCRIPT" 90
PAYLOAD_FILE="$PWD/payload.json"
jq -nc --arg sid "$SID" --arg tp "$TRANSCRIPT" \
  '{session_id:$sid, transcript_path:$tp}' > "$PAYLOAD_FILE"
STATE_FILE="$RELAY_DIR/run/hook-$SID.state"
NOW=$(date +%s)

# CALLS=6 -> this invocation is call 7: 7 % 8 != 0, fresh epoch, LAST_PCT 10
# (<30 => 30s band) => throttled skip, no scan, no emit.
printf '%s|10|0|6\n' "$NOW" > "$STATE_FILE"
OUT1="$PWD/out1.json"
RELAY_SESSION_ID="$SID" RELAY_DIR="$RELAY_DIR" \
  "$HOOK" < "$PAYLOAD_FILE" > "$OUT1" 2>"$PWD/err1.log"
assert_rc 0 "$?" "h215_call7_rc"
assert_eq "" "$(cat "$OUT1" 2>/dev/null)" "h215_call7_skipped"
assert_no_file "$RELAY_DIR/run/ctx.log" "h215_call7_no_scan"

# CALLS=7 -> this invocation is call 8: 8 % 8 == 0 => the modulo escape scans
# despite the identical clock and LAST_PCT, sees 90%, emits CRITICAL.
printf '%s|10|0|7\n' "$NOW" > "$STATE_FILE"
OUT2="$PWD/out2.json"
RELAY_SESSION_ID="$SID" RELAY_DIR="$RELAY_DIR" \
  "$HOOK" < "$PAYLOAD_FILE" > "$OUT2" 2>"$PWD/err2.log"
assert_rc 0 "$?" "h215_call8_rc"
assert_contains "$(cat "$OUT2")" "CRITICAL" "h215_call8_scanned_and_emitted"
assert_file "$RELAY_DIR/run/ctx.log" "h215_call8_logged"
assert_stdout_json_only "$OUT2" "h215_json_contract"
exit 0
