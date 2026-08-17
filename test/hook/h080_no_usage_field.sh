# test/hook/h080_no_usage_field.sh — real (non-sidechain) assistant entry
# present but with no message.usage field at all: usage is unknown, fail
# safe silently.
HOOK="$ROOT/plugins/relay/hooks/relay-ctx.sh"
SID="11111111-2222-3333-4444-555555555555"

RELAY_DIR="$PWD/relay-dir"
mkdir -p "$RELAY_DIR"
printf '{}' > "$RELAY_DIR/state.json"

TRANSCRIPT="$PWD/transcript.jsonl"
mktranscript "$TRANSCRIPT" 40 200000 "no_usage"

PAYLOAD_FILE="$PWD/payload.json"
jq -nc --arg sid "$SID" --arg tp "$TRANSCRIPT" \
  '{session_id:$sid, transcript_path:$tp}' > "$PAYLOAD_FILE"

OUT_FILE="$PWD/out.json"
RELAY_SESSION_ID="$SID" RELAY_DIR="$RELAY_DIR" \
  "$HOOK" < "$PAYLOAD_FILE" > "$OUT_FILE" 2>"$PWD/err.log"
RC=$?

assert_rc 0 "$RC" "h080_rc"
assert_eq "" "$(cat "$OUT_FILE" 2>/dev/null)" "h080_stdout_empty"
assert_stdout_json_only "$OUT_FILE" "h080_stdout_json_only"
assert_file "$RELAY_DIR/run/hook.alive" "h080_hook_alive"
assert_no_file "$RELAY_DIR/run/ctx.log" "h080_no_ctx_log"

exit 0
