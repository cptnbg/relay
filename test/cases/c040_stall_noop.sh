# test/cases/c040_stall_noop.sh — noop,noop,noop with stall_limit 3: no
# commit, no valid handoff, ever. Must exit 21 (stalled), with stall.count
# visibly incrementing 1/3, 2/3, 3/3 in the journal.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
printf '# RUN\n\nMinimal run.\n' > "$STATE/RUN.md"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":6,"stall_limit":3}
EOF

export RELAY_SKIP_PROBE=1
export RELAY_MOCK_SCRIPT="noop,noop,noop"

mkconsent "$STATE"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

JOURNAL="$STATE/journal.log"

assert_rc 21 "$RC" "c040_rc"
assert_grep "$JOURNAL" 'stall\.count.*1/3' "c040_stall_1_of_3"
assert_grep "$JOURNAL" 'stall\.count.*2/3' "c040_stall_2_of_3"
assert_grep "$JOURNAL" 'stall\.count.*3/3' "c040_stall_3_of_3"
assert_grep "$JOURNAL" 'stall\.detected' "c040_stall_detected"

exit 0
