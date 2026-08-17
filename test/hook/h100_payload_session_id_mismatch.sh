# test/hook/h100_payload_session_id_mismatch.sh — the payload's session_id
# differs from RELAY_SESSION_ID: the hook must be completely inert. Proven
# by snapshotting every file under the sandbox before and after the call
# and asserting the listing is byte-for-byte identical.
HOOK="$ROOT/plugins/relay/hooks/relay-ctx.sh"
SID_ENV="11111111-2222-3333-4444-555555555555"
SID_PAYLOAD="99999999-8888-7777-6666-cccccccccccc"

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

assert_rc 0 "$RC" "h100_rc"
assert_eq "" "$(cat "$OUT_FILE" 2>/dev/null)" "h100_stdout_empty"
assert_eq "$BEFORE" "$AFTER" "h100_no_files_created"

exit 0
