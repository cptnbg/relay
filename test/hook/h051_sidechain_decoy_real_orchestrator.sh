# test/hook/h051_sidechain_decoy_real_orchestrator.sh — a decoy sidechain
# entry with a huge (9,999,999-token) usage count, plus a real 30%
# non-sidechain entry. If the hook mismeasured by picking up the sidechain
# entry it would report something absurd (or clamp to 100%); it must instead
# report 30%, proving it measures the ORCHESTRATOR's context, not a
# subagent's. This is the single most important measurement test.
HOOK="$ROOT/plugins/relay/hooks/relay-ctx.sh"
SID="11111111-2222-3333-4444-555555555555"

RELAY_DIR="$PWD/relay-dir"
mkdir -p "$RELAY_DIR"
printf '{}' > "$RELAY_DIR/state.json"
: > "$RELAY_DIR/.relay"

TRANSCRIPT="$PWD/transcript.jsonl"
mktranscript "$TRANSCRIPT" 30

PAYLOAD_FILE="$PWD/payload.json"
jq -nc --arg sid "$SID" --arg tp "$TRANSCRIPT" \
  '{session_id:$sid, transcript_path:$tp}' > "$PAYLOAD_FILE"

OUT_FILE="$PWD/out.json"
RELAY_SESSION_ID="$SID" RELAY_DIR="$RELAY_DIR" \
  "$HOOK" < "$PAYLOAD_FILE" > "$OUT_FILE" 2>"$PWD/err.log"
RC=$?

assert_rc 0 "$RC" "h051_rc"
assert_eq "" "$(cat "$OUT_FILE" 2>/dev/null)" "h051_stdout_empty"
assert_stdout_json_only "$OUT_FILE" "h051_stdout_json_only"

assert_grep "$RELAY_DIR/run/ctx.log" "pct=30 " "h051_ctx_log_pct_30"
assert_no_grep "$RELAY_DIR/run/ctx.log" "pct=100" "h051_did_not_clamp_high"

STATE_FILE="$RELAY_DIR/run/hook-$SID.state"
IFS='|' read -r HS_EPOCH HS_PCT HS_LEVEL HS_CALLS < "$STATE_FILE"
IFS=$' \t\n'
assert_eq "30" "$HS_PCT" "h051_state_pct"

exit 0
