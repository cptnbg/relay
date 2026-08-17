# test/hook/h091_transcript_path_absent.sh — transcript_path field absent
# from the payload entirely: exit 0, silent.
HOOK="$ROOT/plugins/relay/hooks/relay-ctx.sh"
SID="11111111-2222-3333-4444-555555555555"

RELAY_DIR="$PWD/relay-dir"
mkdir -p "$RELAY_DIR"
printf '{}' > "$RELAY_DIR/state.json"

PAYLOAD_FILE="$PWD/payload.json"
jq -nc --arg sid "$SID" '{session_id:$sid}' > "$PAYLOAD_FILE"

OUT_FILE="$PWD/out.json"
RELAY_SESSION_ID="$SID" RELAY_DIR="$RELAY_DIR" \
  "$HOOK" < "$PAYLOAD_FILE" > "$OUT_FILE" 2>"$PWD/err.log"
RC=$?

assert_rc 0 "$RC" "h091_rc"
assert_eq "" "$(cat "$OUT_FILE" 2>/dev/null)" "h091_stdout_empty"
assert_stdout_json_only "$OUT_FILE" "h091_stdout_json_only"

exit 0
