# test/hook/h090_transcript_missing_file.sh — transcript_path points at a
# file that does not exist: exit 0, silent, but run/hook.alive IS created,
# proving the hook ran (it just had nothing to read).
HOOK="$ROOT/plugins/relay/hooks/relay-ctx.sh"
SID="11111111-2222-3333-4444-555555555555"

RELAY_DIR="$PWD/relay-dir"
mkdir -p "$RELAY_DIR"
printf '{}' > "$RELAY_DIR/state.json"
: > "$RELAY_DIR/.relay"

MISSING_TRANSCRIPT="$PWD/does-not-exist.jsonl"

PAYLOAD_FILE="$PWD/payload.json"
jq -nc --arg sid "$SID" --arg tp "$MISSING_TRANSCRIPT" \
  '{session_id:$sid, transcript_path:$tp}' > "$PAYLOAD_FILE"

OUT_FILE="$PWD/out.json"
RELAY_SESSION_ID="$SID" RELAY_DIR="$RELAY_DIR" \
  "$HOOK" < "$PAYLOAD_FILE" > "$OUT_FILE" 2>"$PWD/err.log"
RC=$?

assert_rc 0 "$RC" "h090_rc"
assert_eq "" "$(cat "$OUT_FILE" 2>/dev/null)" "h090_stdout_empty"
assert_stdout_json_only "$OUT_FILE" "h090_stdout_json_only"
assert_file "$RELAY_DIR/run/hook.alive" "h090_hook_alive_created"

exit 0
