# test/hook/h010_below_soft.sh — below soft (30%): completely silent, level
# stays 0.
HOOK="$ROOT/plugins/relay/hooks/relay-ctx.sh"
SID="11111111-2222-3333-4444-555555555555"

RELAY_DIR="$PWD/relay-dir"
mkdir -p "$RELAY_DIR"
printf '{}' > "$RELAY_DIR/state.json"
: > "$RELAY_DIR/.relay"

TRANSCRIPT="$PWD/transcript.jsonl"
mktranscript "$TRANSCRIPT" 30

PAYLOAD_FILE="$PWD/payload.json"
jq -nc --arg sid "$SID" --arg tp "$TRANSCRIPT" \
  '{session_id:$sid, transcript_path:$tp}' > "$PAYLOAD_FILE"

OUT_FILE="$PWD/out.json"
RELAY_SESSION_ID="$SID" RELAY_DIR="$RELAY_DIR" \
  "$HOOK" < "$PAYLOAD_FILE" > "$OUT_FILE" 2>"$PWD/err.log"
RC=$?

assert_rc 0 "$RC" "h010_rc"
assert_eq "" "$(cat "$OUT_FILE" 2>/dev/null)" "h010_stdout_empty"
assert_stdout_json_only "$OUT_FILE" "h010_stdout_json_only"

STATE_FILE="$RELAY_DIR/run/hook-$SID.state"
assert_file "$STATE_FILE" "h010_state_file"
IFS='|' read -r HS_EPOCH HS_PCT HS_LEVEL HS_CALLS < "$STATE_FILE"
IFS=$' \t\n'
assert_eq "30" "$HS_PCT" "h010_state_pct"
assert_eq "0" "$HS_LEVEL" "h010_state_level"

exit 0
