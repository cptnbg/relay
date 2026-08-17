# test/hook/h050_sidechain_only_unknown.sh — transcript with ONLY a
# sidechain assistant entry: usage is unknown, so the hook must fail safe
# (no emission, no guess) rather than measuring the subagent's usage.
HOOK="$ROOT/plugins/relay/hooks/relay-ctx.sh"
SID="11111111-2222-3333-4444-555555555555"

RELAY_DIR="$PWD/relay-dir"
mkdir -p "$RELAY_DIR"
printf '{}' > "$RELAY_DIR/state.json"

TRANSCRIPT="$PWD/transcript.jsonl"
mktranscript "$TRANSCRIPT" 50 200000 "sidechain_only"

PAYLOAD_FILE="$PWD/payload.json"
jq -nc --arg sid "$SID" --arg tp "$TRANSCRIPT" \
  '{session_id:$sid, transcript_path:$tp}' > "$PAYLOAD_FILE"

OUT_FILE="$PWD/out.json"
RELAY_SESSION_ID="$SID" RELAY_DIR="$RELAY_DIR" \
  "$HOOK" < "$PAYLOAD_FILE" > "$OUT_FILE" 2>"$PWD/err.log"
RC=$?

assert_rc 0 "$RC" "h050_rc"
assert_eq "" "$(cat "$OUT_FILE" 2>/dev/null)" "h050_stdout_empty"
assert_stdout_json_only "$OUT_FILE" "h050_stdout_json_only"

# It ran (proof of life) but found nothing usable, so it never got as far
# as writing a pct/level line to ctx.log.
assert_file "$RELAY_DIR/run/hook.alive" "h050_hook_alive"
assert_no_file "$RELAY_DIR/run/ctx.log" "h050_no_ctx_log"

exit 0
