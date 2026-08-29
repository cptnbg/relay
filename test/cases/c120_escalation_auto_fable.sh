# test/cases/c120_escalation_auto_fable.sh — repeated no-progress with
# stall_limit 3 and max_fable_sessions 2 must auto-escalate to the fable
# tier ONE session before the stall halt would otherwise fire (relay gives
# it a last, smarter shot). Assert escalation.auto with tier=fable appears
# in the journal, that the very next session.start line shows tier=fable,
# and that this happens strictly before the eventual stall.detected halt.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
mkrunmd "$STATE"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":6,"stall_limit":3,"max_fable_sessions":2,"model_tier":"opus"}
EOF

export RELAY_SKIP_PROBE=1
export RELAY_MOCK_SCRIPT="noop,noop,noop"

mkconsent "$STATE"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

JOURNAL="$STATE/journal.log"

assert_rc 21 "$RC" "c120_rc_stalled"
assert_grep "$JOURNAL" 'escalation\.auto.*tier=fable' "c120_escalation_auto_journaled"

SESSION3_LINE=$(grep -F -- "$(printf '\tsession.start\t')" "$JOURNAL" | sed -n '3p')
assert_contains "$SESSION3_LINE" "tier=fable" "c120_third_session_used_fable"

ESC_LN=$(grep -n 'escalation\.auto' "$JOURNAL" | head -1 | cut -d: -f1)
STALL_LN=$(grep -n 'stall\.detected' "$JOURNAL" | head -1 | cut -d: -f1)
assert_between "$ESC_LN" "1" "$((STALL_LN - 1))" "c120_escalation_before_halt"

exit 0
