# test/hook/h040_critical_every_call.sh — at critical (92%), 3 calls in a
# row: level 3 re-emits on EVERY call (escalation bypasses the debounce that
# would otherwise suppress a repeat at an unchanged level).
HOOK="$ROOT/plugins/relay/hooks/relay-ctx.sh"
SID="11111111-2222-3333-4444-555555555555"

RELAY_DIR="$PWD/relay-dir"
mkdir -p "$RELAY_DIR"
printf '{}' > "$RELAY_DIR/state.json"

TRANSCRIPT="$PWD/transcript.jsonl"
mktranscript "$TRANSCRIPT" 92

PAYLOAD_FILE="$PWD/payload.json"
jq -nc --arg sid "$SID" --arg tp "$TRANSCRIPT" \
  '{session_id:$sid, transcript_path:$tp}' > "$PAYLOAD_FILE"

i=1
while [ "$i" -le 3 ]; do
  OUT="$PWD/out$i.json"
  RELAY_SESSION_ID="$SID" RELAY_DIR="$RELAY_DIR" \
    "$HOOK" < "$PAYLOAD_FILE" > "$OUT" 2>"$PWD/err$i.log"
  RC=$?
  assert_rc 0 "$RC" "h040_call${i}_rc"
  assert_stdout_json_only "$OUT" "h040_call${i}_json_only"
  assert_contains "$(cat "$OUT")" "CRITICAL" "h040_call${i}_text"
  assert_contains "$(cat "$OUT")" "92%" "h040_call${i}_pct"
  i=$((i + 1))
done

STATE_FILE="$RELAY_DIR/run/hook-$SID.state"
IFS='|' read -r HS_EPOCH HS_PCT HS_LEVEL HS_CALLS < "$STATE_FILE"
IFS=$' \t\n'
assert_eq "92" "$HS_PCT" "h040_final_pct"
assert_eq "3" "$HS_LEVEL" "h040_final_level"
assert_eq "3" "$HS_CALLS" "h040_final_calls"

exit 0
