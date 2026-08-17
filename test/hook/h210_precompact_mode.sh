# test/hook/h210_precompact_mode.sh — PreCompact mode (--precompact):
# appends to run/compaction.events and exits 0, regardless of the
# posttooluse level machine's state (proven by hand-writing a hook-state
# file at level 2 before the second call and confirming it is untouched).
HOOK="$ROOT/plugins/relay/hooks/relay-ctx.sh"
SID="11111111-2222-3333-4444-555555555555"

RELAY_DIR="$PWD/relay-dir"
mkdir -p "$RELAY_DIR"
printf '{}' > "$RELAY_DIR/state.json"

PAYLOAD_FILE="$PWD/payload.json"
jq -nc --arg sid "$SID" '{session_id:$sid}' > "$PAYLOAD_FILE"

OUT1="$PWD/out1.json"
RELAY_SESSION_ID="$SID" RELAY_DIR="$RELAY_DIR" \
  "$HOOK" --precompact < "$PAYLOAD_FILE" > "$OUT1" 2>"$PWD/err1.log"
RC1=$?

assert_rc 0 "$RC1" "h210_call1_rc"
assert_stdout_json_only "$OUT1" "h210_call1_stdout_json_only"
assert_json "$OUT1" '.hookSpecificOutput.hookEventName' "PreCompact" "h210_call1_event_name"
assert_contains "$(cat "$OUT1")" "Compaction is starting" "h210_call1_text"

EVENTS_FILE="$RELAY_DIR/run/compaction.events"
assert_file "$EVENTS_FILE" "h210_events_file_created"
assert_grep "$EVENTS_FILE" "$SID" "h210_events_has_session_id"

LINES1="$(wc -l < "$EVENTS_FILE" | tr -d ' ')"
assert_eq "1" "$LINES1" "h210_events_one_line_after_call1"

# Hand-write a posttooluse hook-state at a different level to prove
# precompact is independent of (and does not touch) that level machine.
STATE_FILE="$RELAY_DIR/run/hook-$SID.state"
printf '%s|%s|%s|%s\n' "$(date +%s)" 92 2 5 > "$STATE_FILE"

OUT2="$PWD/out2.json"
RELAY_SESSION_ID="$SID" RELAY_DIR="$RELAY_DIR" \
  "$HOOK" --precompact < "$PAYLOAD_FILE" > "$OUT2" 2>"$PWD/err2.log"
RC2=$?

assert_rc 0 "$RC2" "h210_call2_rc"
assert_stdout_json_only "$OUT2" "h210_call2_stdout_json_only"
assert_json "$OUT2" '.hookSpecificOutput.hookEventName' "PreCompact" "h210_call2_event_name"

LINES2="$(wc -l < "$EVENTS_FILE" | tr -d ' ')"
assert_eq "2" "$LINES2" "h210_events_two_lines_after_call2"

IFS='|' read -r SE SP SL SC < "$STATE_FILE"; IFS=$' \t\n'
assert_eq "2" "$SL" "h210_precompact_does_not_touch_level_machine"

exit 0
