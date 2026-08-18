# test/cases/c122_escalation_exhausted_fallback.sh — with max_fable_sessions
# 0, escalation must fall back to the default tier rather than halting the
# run. complete_false,work,complete drives this: session 1's rejected false
# COMPLETE claim unconditionally requests tier=fable for session 2
# (relay-supervisor.sh's "it thinks it is done and it is not" branch, which
# is NOT gated by the fable budget). Session 2 then hits the top-of-loop
# budget check with FABLE_USED(0) >= max_fable_sessions(0), journals
# escalation.exhausted, and falls back to the default tier instead of
# halting — the run continues and finishes normally (exit 0).
#
# (Note: the stall-based auto-escalation path in relay-supervisor.sh
# self-gates on `FABLE_USED < MAX_FABLE` before ever setting NEXT_TIER=fable,
# so with max_fable_sessions 0 it can never actually request fable in the
# first place, and "escalation.exhausted" could never fire via that path.
# The complete_false-rejection path is the one unconditional NEXT_TIER=fable
# assignment in the script, so it is the only way to exercise this branch.)
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
printf '# RUN\n\nMinimal run.\n' > "$STATE/RUN.md"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":6,"max_fable_sessions":0}
EOF

export RELAY_SKIP_PROBE=1
export RELAY_MOCK_SCRIPT="complete_false,work,complete"

mkconsent "$STATE"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

JOURNAL="$STATE/journal.log"

assert_grep "$JOURNAL" 'escalation\.exhausted' "c122_escalation_exhausted_journaled"
assert_grep "$JOURNAL" 'complete\.verified' "c122_run_continued_to_completion"
assert_rc 0 "$RC" "c122_rc_success_not_halted_by_escalation"

EXH_LN=$(grep -n 'escalation\.exhausted' "$JOURNAL" | head -1 | cut -d: -f1)
DONE_LN=$(grep -n 'complete\.verified' "$JOURNAL" | head -1 | cut -d: -f1)
assert_between "$EXH_LN" "1" "$((DONE_LN - 1))" "c122_exhausted_before_completion"

exit 0
