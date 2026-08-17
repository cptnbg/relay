# test/hook/h140_ctx_log_symlink_canary.sh — run/ctx.log pre-created as a
# symlink pointing at a canary file outside the state dir: the canary must
# be completely unmodified after the hook runs (relay_safe_target must
# refuse to follow the symlink).
HOOK="$ROOT/plugins/relay/hooks/relay-ctx.sh"
SID="11111111-2222-3333-4444-555555555555"

RELAY_DIR="$PWD/relay-dir"
mkdir -p "$RELAY_DIR/run"
printf '{}' > "$RELAY_DIR/state.json"

CANARY="$PWD/canary.txt"
printf 'canary-untouched-content\n' > "$CANARY"
ln -s "$CANARY" "$RELAY_DIR/run/ctx.log"

TRANSCRIPT="$PWD/transcript.jsonl"
mktranscript "$TRANSCRIPT" 50

PAYLOAD_FILE="$PWD/payload.json"
jq -nc --arg sid "$SID" --arg tp "$TRANSCRIPT" \
  '{session_id:$sid, transcript_path:$tp}' > "$PAYLOAD_FILE"

OUT_FILE="$PWD/out.json"
RELAY_SESSION_ID="$SID" RELAY_DIR="$RELAY_DIR" \
  "$HOOK" < "$PAYLOAD_FILE" > "$OUT_FILE" 2>"$PWD/err.log"
RC=$?

assert_rc 0 "$RC" "h140_rc"
assert_eq "canary-untouched-content" "$(cat "$CANARY" 2>/dev/null)" "h140_canary_unmodified"

if [ ! -L "$RELAY_DIR/run/ctx.log" ]; then
  _assert_fail "h140: ctx.log symlink was replaced by a non-symlink"
fi

exit 0
