# test/hook/h110_no_session_id_env.sh — RELAY_SESSION_ID not set at all:
# exit 0, silent, and NO files created anywhere. This is the load-bearing
# test: it proves the hook is inert in any session relay did not start
# (including a session where relay's own plugin files are simply present
# on disk but RELAY_SESSION_ID was never exported).
HOOK="$ROOT/plugins/relay/hooks/relay-ctx.sh"
SID_PAYLOAD="11111111-2222-3333-4444-555555555555"

RELAY_DIR="$PWD/relay-dir"
mkdir -p "$RELAY_DIR"
printf '{}' > "$RELAY_DIR/state.json"
: > "$RELAY_DIR/.relay"

TRANSCRIPT="$PWD/transcript.jsonl"
mktranscript "$TRANSCRIPT" 92

PAYLOAD_FILE="$PWD/payload.json"
jq -nc --arg sid "$SID_PAYLOAD" --arg tp "$TRANSCRIPT" \
  '{session_id:$sid, transcript_path:$tp}' > "$PAYLOAD_FILE"

OUT_FILE="$PWD/out.json"
ERR_FILE="$PWD/err.log"
: > "$OUT_FILE"
: > "$ERR_FILE"

unset RELAY_SESSION_ID

BEFORE="$(find . -type f 2>/dev/null | sort)"

RELAY_DIR="$RELAY_DIR" "$HOOK" < "$PAYLOAD_FILE" > "$OUT_FILE" 2>"$ERR_FILE"
RC=$?

AFTER="$(find . -type f 2>/dev/null | sort)"

assert_rc 0 "$RC" "h110_rc"
assert_eq "" "$(cat "$OUT_FILE" 2>/dev/null)" "h110_stdout_empty"
assert_eq "$BEFORE" "$AFTER" "h110_no_files_created"

exit 0
