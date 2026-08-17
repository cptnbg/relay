# test/hook/h042_soft_then_hard_escalation.sh — soft, then hard: the hard
# call DOES emit even though it happens right after another emission,
# because an escalating level bypasses the debounce.
HOOK="$ROOT/plugins/relay/hooks/relay-ctx.sh"
SID="11111111-2222-3333-4444-555555555555"

RELAY_DIR="$PWD/relay-dir"
mkdir -p "$RELAY_DIR"
printf '{}' > "$RELAY_DIR/state.json"

TRANSCRIPT="$PWD/transcript.jsonl"
PAYLOAD_FILE="$PWD/payload.json"
jq -nc --arg sid "$SID" --arg tp "$TRANSCRIPT" \
  '{session_id:$sid, transcript_path:$tp}' > "$PAYLOAD_FILE"

mktranscript "$TRANSCRIPT" 62
OUT1="$PWD/out1.json"
RELAY_SESSION_ID="$SID" RELAY_DIR="$RELAY_DIR" \
  "$HOOK" < "$PAYLOAD_FILE" > "$OUT1" 2>"$PWD/err1.log"
RC1=$?
assert_rc 0 "$RC1" "h042_call1_rc"
assert_contains "$(cat "$OUT1")" "CONTEXT CHECKPOINT" "h042_call1_soft_emits"

mktranscript "$TRANSCRIPT" 78
OUT2="$PWD/out2.json"
RELAY_SESSION_ID="$SID" RELAY_DIR="$RELAY_DIR" \
  "$HOOK" < "$PAYLOAD_FILE" > "$OUT2" 2>"$PWD/err2.log"
RC2=$?
assert_rc 0 "$RC2" "h042_call2_rc"
assert_contains "$(cat "$OUT2")" "MANDATORY HANDOFF" "h042_call2_hard_emits"

STATE_FILE="$RELAY_DIR/run/hook-$SID.state"
IFS='|' read -r E2 P2 L2 C2 < "$STATE_FILE"; IFS=$' \t\n'
assert_eq "78" "$P2" "h042_call2_pct"
assert_eq "2" "$L2" "h042_call2_level"

exit 0
