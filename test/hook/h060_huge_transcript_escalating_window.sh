# test/hook/h060_huge_transcript_escalating_window.sh — a >1.3MB single
# transcript line (mkhuge_transcript), reproducing a real measured 1.36MB
# transcript line, at 70% usage. A fixed 64KB tail window would contain
# zero complete JSON lines and silently report nothing; the hook must
# escalate its tail window (64K -> 256K -> 1M -> 4M) until it finds a
# complete, parseable line. Also proves this completes quickly despite the
# multiple re-scans of a multi-megabyte file.
HOOK="$ROOT/plugins/relay/hooks/relay-ctx.sh"
SID="11111111-2222-3333-4444-555555555555"

RELAY_DIR="$PWD/relay-dir"
mkdir -p "$RELAY_DIR"
printf '{}' > "$RELAY_DIR/state.json"
: > "$RELAY_DIR/.relay"

TRANSCRIPT="$PWD/huge-transcript.jsonl"
mkhuge_transcript "$TRANSCRIPT" 70 200000

FSIZE="$(wc -c < "$TRANSCRIPT" | tr -d ' ')"
assert_between "$FSIZE" 1300000 999999999 "h060_fixture_really_is_huge"

PAYLOAD_FILE="$PWD/payload.json"
jq -nc --arg sid "$SID" --arg tp "$TRANSCRIPT" \
  '{session_id:$sid, transcript_path:$tp}' > "$PAYLOAD_FILE"

OUT_FILE="$PWD/out.json"
START="$(date +%s)"
RELAY_SESSION_ID="$SID" RELAY_DIR="$RELAY_DIR" \
  "$HOOK" < "$PAYLOAD_FILE" > "$OUT_FILE" 2>"$PWD/err.log"
RC=$?
END="$(date +%s)"
ELAPSED=$((END - START))

assert_rc 0 "$RC" "h060_rc"
assert_between "$ELAPSED" 0 20 "h060_completes_quickly"
assert_stdout_json_only "$OUT_FILE" "h060_stdout_json_only"
assert_contains "$(cat "$OUT_FILE")" "70%" "h060_reports_70pct"

STATE_FILE="$RELAY_DIR/run/hook-$SID.state"
IFS='|' read -r HS_EPOCH HS_PCT HS_LEVEL HS_CALLS < "$STATE_FILE"
IFS=$' \t\n'
assert_eq "70" "$HS_PCT" "h060_state_pct"

exit 0
