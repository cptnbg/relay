# test/hook/h180_kill_switch_beats_critical.sh — hook.off kill switch
# present, even at critical (92%): stdout stays completely empty. The kill
# switch wins outright.
HOOK="$ROOT/plugins/relay/hooks/relay-ctx.sh"
SID="11111111-2222-3333-4444-555555555555"

RELAY_DIR="$PWD/relay-dir"
mkdir -p "$RELAY_DIR"
printf '{}' > "$RELAY_DIR/state.json"
: > "$RELAY_DIR/hook.off"

TRANSCRIPT="$PWD/transcript.jsonl"
mktranscript "$TRANSCRIPT" 92

PAYLOAD_FILE="$PWD/payload.json"
jq -nc --arg sid "$SID" --arg tp "$TRANSCRIPT" \
  '{session_id:$sid, transcript_path:$tp}' > "$PAYLOAD_FILE"

OUT_FILE="$PWD/out.json"
RELAY_SESSION_ID="$SID" RELAY_DIR="$RELAY_DIR" \
  "$HOOK" < "$PAYLOAD_FILE" > "$OUT_FILE" 2>"$PWD/err.log"
RC=$?

assert_rc 0 "$RC" "h180_rc"
assert_eq "" "$(cat "$OUT_FILE" 2>/dev/null)" "h180_stdout_empty"
assert_stdout_json_only "$OUT_FILE" "h180_stdout_json_only"
assert_no_file "$RELAY_DIR/run/hook.alive" "h180_no_hook_alive"
assert_no_file "$RELAY_DIR/run/ctx.log" "h180_no_ctx_log"

exit 0
