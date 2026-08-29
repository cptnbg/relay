# c145 — ctx.baseline recording. The supervisor scans $WORK/run/ctx.log after
# each session and must record the MINIMUM used= value among entries stamped
# at/after the session's start. Entries from before the session (a previous
# run's tail) must be ignored. The in-window values are ordered
# 52000, 48000, 50000 so that "first match" (52000), "last match" (50000) and
# "minimum" (48000) are all distinguishable.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE" "$STATE/work/run"
mkrunmd "$STATE"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":4}
EOF

NOW=$(date +%s)
FUTURE=$((NOW + 100))
{
  # Stale entry from "before the session": must be ignored, or the recorded
  # baseline would be 5.
  printf '1000 pct=1 used=5 level=0 calls=1\n'
  printf '%s pct=30 used=52000 level=1 calls=2\n' "$FUTURE"
  printf '%s pct=25 used=48000 level=1 calls=3\n' "$FUTURE"
  printf '%s pct=26 used=50000 level=1 calls=4\n' "$FUTURE"
} > "$STATE/work/run/ctx.log"

export RELAY_SKIP_PROBE=1
export RELAY_MOCK_SCRIPT="work,complete"

mkconsent "$STATE"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

JOURNAL="$STATE/journal.log"

assert_rc 0 "$RC" "c145_rc"
assert_grep "$JOURNAL" 'ctx\.baseline	n=1 used=48000 window=' "c145_journal_records_minimum"
assert_no_grep "$JOURNAL" 'used=5 window=' "c145_pre_session_entry_ignored"
assert_json "$STATE/state.json" '.ctx_baseline' "48000" "c145_state_records_minimum"

exit 0
