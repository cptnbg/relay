# test/hook/h120_session_id_path_traversal.sh — RELAY_SESSION_ID set to a
# path-traversal value: the UUID-shape guard must reject it before it is
# ever used to build a path, so no file appears anywhere in the sandbox
# (in particular, nothing escapes RELAY_DIR).
HOOK="$ROOT/plugins/relay/hooks/relay-ctx.sh"
SID_ENV="../../etc/passwd"
SID_PAYLOAD="11111111-2222-3333-4444-555555555555"

RELAY_DIR="$PWD/relay-dir"
mkdir -p "$RELAY_DIR"
printf '{}' > "$RELAY_DIR/state.json"

TRANSCRIPT="$PWD/transcript.jsonl"
mktranscript "$TRANSCRIPT" 92

PAYLOAD_FILE="$PWD/payload.json"
jq -nc --arg sid "$SID_PAYLOAD" --arg tp "$TRANSCRIPT" \
  '{session_id:$sid, transcript_path:$tp}' > "$PAYLOAD_FILE"

OUT_FILE="$PWD/out.json"
ERR_FILE="$PWD/err.log"
: > "$OUT_FILE"
: > "$ERR_FILE"

BEFORE="$(find . -type f 2>/dev/null | sort)"

RELAY_SESSION_ID="$SID_ENV" RELAY_DIR="$RELAY_DIR" \
  "$HOOK" < "$PAYLOAD_FILE" > "$OUT_FILE" 2>"$ERR_FILE"
RC=$?

AFTER="$(find . -type f 2>/dev/null | sort)"

assert_rc 0 "$RC" "h120_rc"
assert_eq "" "$(cat "$OUT_FILE" 2>/dev/null)" "h120_stdout_empty"
assert_eq "$BEFORE" "$AFTER" "h120_no_files_created"

exit 0
