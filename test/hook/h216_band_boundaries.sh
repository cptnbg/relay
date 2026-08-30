# The retuned throttle bands: <30 -> 30s, 30-49 -> 15s, >=50 -> 0s. Probed at
# AGE=16s: 29 skips (16<30), 30 scans (16>=15), 49 scans, 50 scans (interval
# 0 ignores AGE entirely).
HOOK="$ROOT/plugins/relay/hooks/relay-ctx.sh"
SID="11111111-2222-3333-4444-555555555555"
RELAY_DIR="$PWD/relay-dir"
mkdir -p "$RELAY_DIR/run"
: > "$RELAY_DIR/.relay"
TRANSCRIPT="$PWD/transcript.jsonl"
mktranscript "$TRANSCRIPT" 40
PAYLOAD_FILE="$PWD/payload.json"
jq -nc --arg sid "$SID" --arg tp "$TRANSCRIPT" \
  '{session_id:$sid, transcript_path:$tp}' > "$PAYLOAD_FILE"
STATE_FILE="$RELAY_DIR/run/hook-$SID.state"

_probe() { # last_pct -> prints "scan" or "skip"
  rm -f "$RELAY_DIR/run/ctx.log"
  # CALLS=1 so the modulo escape (call 2) stays out of the way.
  printf '%s|%s|1|1\n' "$(( $(date +%s) - 16 ))" "$1" > "$STATE_FILE"
  RELAY_SESSION_ID="$SID" RELAY_DIR="$RELAY_DIR" \
    "$HOOK" < "$PAYLOAD_FILE" > /dev/null 2>&1
  if [ -f "$RELAY_DIR/run/ctx.log" ]; then printf 'scan'; else printf 'skip'; fi
}

assert_eq "skip" "$(_probe 29)" "h216_29_skips_at_16s"
assert_eq "scan" "$(_probe 30)" "h216_30_scans_at_16s"
assert_eq "scan" "$(_probe 49)" "h216_49_scans_at_16s"
assert_eq "scan" "$(_probe 50)" "h216_50_always_scans"
exit 0
