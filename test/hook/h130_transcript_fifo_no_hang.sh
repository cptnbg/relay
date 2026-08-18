# test/hook/h130_transcript_fifo_no_hang.sh — transcript_path points at a
# FIFO: the hook must RETURN rather than block forever trying to open it
# for reading (a FIFO with no writer connected blocks on open). Guarded
# with a background watchdog that force-kills the hook after ~10s; if that
# watchdog ever has to fire, the test fails loudly instead of hanging the
# whole suite.
HOOK="$ROOT/plugins/relay/hooks/relay-ctx.sh"
SID="11111111-2222-3333-4444-555555555555"

RELAY_DIR="$PWD/relay-dir"
mkdir -p "$RELAY_DIR"
printf '{}' > "$RELAY_DIR/state.json"
: > "$RELAY_DIR/.relay"

FIFO="$PWD/transcript.fifo"
mkfifo "$FIFO"

PAYLOAD_FILE="$PWD/payload.json"
jq -nc --arg sid "$SID" --arg tp "$FIFO" \
  '{session_id:$sid, transcript_path:$tp}' > "$PAYLOAD_FILE"

OUT_FILE="$PWD/out.json"
ERR_FILE="$PWD/err.log"

RELAY_SESSION_ID="$SID" RELAY_DIR="$RELAY_DIR" \
  "$HOOK" < "$PAYLOAD_FILE" > "$OUT_FILE" 2>"$ERR_FILE" &
HOOK_PID=$!

( sleep 10; kill -9 "$HOOK_PID" 2>/dev/null ) &
WATCHDOG_PID=$!

wait "$HOOK_PID"
HOOK_RC=$?

kill "$WATCHDOG_PID" 2>/dev/null
wait "$WATCHDOG_PID" 2>/dev/null

rm -f "$FIFO"

if [ "$HOOK_RC" -eq 137 ]; then
  _assert_fail "h130: the hook had to be force-killed by the watchdog after 10s -- transcript_path being a FIFO hung it"
fi

assert_rc 0 "$HOOK_RC" "h130_hook_exit_code"
assert_eq "" "$(cat "$OUT_FILE" 2>/dev/null)" "h130_stdout_empty"
assert_stdout_json_only "$OUT_FILE" "h130_stdout_json_only"

exit 0
