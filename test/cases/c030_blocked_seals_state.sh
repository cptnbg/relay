# test/cases/c030_blocked_seals_state.sh — work,blocked: the second session
# writes a sealed BLOCKED.md. Supervisor must exit 20 and the sentinel must
# be on disk, sealed.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
printf '# RUN\n\nMinimal run.\n' > "$STATE/RUN.md"
printf '# Plan\n\n1. step one\n2. step two\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":6}
EOF

export RELAY_SKIP_PROBE=1
export RELAY_MOCK_SCRIPT="work,blocked"

mkconsent "$STATE"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

JOURNAL="$STATE/journal.log"

assert_rc 20 "$RC" "c030_rc"
assert_file "$STATE/work/BLOCKED.md" "c030_blocked_md_exists"
assert_grep "$STATE/work/BLOCKED.md" 'relay:sealed' "c030_blocked_md_sealed"
assert_grep "$JOURNAL" 'blocked\.detected' "c030_journal_blocked_detected"

exit 0
