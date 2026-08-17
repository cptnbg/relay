# test/hook/h041_soft_debounce.sh — soft twice in a row: the second call at
# an UNCHANGED level emits nothing. The transcript/payload/RELAY_DIR are
# identical across both calls; LAST_PCT after call 1 (62, >=55) forces the
# throttle interval to 0, so call 2 does reach the active scan path -- this
# proves the silence is level-debounce, not a throttle skip.
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

OUT1="$PWD/out1.json"
RELAY_SESSION_ID="$SID" RELAY_DIR="$RELAY_DIR" \
  "$HOOK" < "$PAYLOAD_FILE" > "$OUT1" 2>"$PWD/err1.log"
RC1=$?
assert_rc 0 "$RC1" "h041_call1_rc"
assert_contains "$(cat "$OUT1")" "CONTEXT CHECKPOINT" "h041_call1_emits"

STATE_FILE="$RELAY_DIR/run/hook-$SID.state"
IFS='|' read -r E1 P1 L1 C1 < "$STATE_FILE"; IFS=$' \t\n'
assert_eq "1" "$L1" "h041_call1_level"

OUT2="$PWD/out2.json"
RELAY_SESSION_ID="$SID" RELAY_DIR="$RELAY_DIR" \
  "$HOOK" < "$PAYLOAD_FILE" > "$OUT2" 2>"$PWD/err2.log"
RC2=$?
assert_rc 0 "$RC2" "h041_call2_rc"
assert_eq "" "$(cat "$OUT2" 2>/dev/null)" "h041_call2_silent"
assert_stdout_json_only "$OUT2" "h041_call2_json_only"

IFS='|' read -r E2 P2 L2 C2 < "$STATE_FILE"; IFS=$' \t\n'
assert_eq "1" "$L2" "h041_call2_level_unchanged"
assert_eq "2" "$C2" "h041_call2_count"

exit 0
