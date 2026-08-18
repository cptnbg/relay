# c147 — the RECOVERY and AUDIT preambles appear in the rendered prompt in
# exactly the right sessions, asserted off the mock's argv log.
#
# Run 1: crash,work,complete — session 2 must carry the RECOVERY preamble
#        (invalid handoff after the crash), sessions 1 and 3 must not.
# Run 2: review_every=2 with work,work,complete — session 2 must carry the
#        AUDIT preamble, and only session 2.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
printf '# RUN\n\nMinimal run.\n' > "$STATE/RUN.md"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

printf '{"max_sessions":6}\n' > "$STATE/config.json"

export RELAY_SKIP_PROBE=1

mkconsent "$STATE"
RELAY_MOCK_SCRIPT="crash,work,complete" \
  bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

RECOVERY_LINE='RECOVERY: the previous session ended without completing a valid handoff'
AUDIT_LINE='This is an AUDIT session, not a build session'

assert_rc 0 "$RC" "c147_recovery_run_rc"
assert_grep "$STATE/journal.log" 'handoff\.invalid' "c147_crash_left_invalid_handoff"
RCV_COUNT=$(grep -c -- "$RECOVERY_LINE" "$RELAY_MOCK_DIR/argv.log")
assert_eq "1" "$RCV_COUNT" "c147_recovery_preamble_exactly_once"
assert_no_grep "$RELAY_MOCK_DIR/argv.log" "$AUDIT_LINE" "c147_no_audit_preamble_in_recovery_run"

# Run 2 — fresh project/state/mock dir, review cadence of 2.
PROJ2="$PWD/proj2"
STATE2="$PWD/state2"
MOCK2="$PWD/mock2"
mkrepo "$PROJ2"
mkdir -p "$STATE2" "$MOCK2"
printf '# RUN\n\nMinimal run.\n' > "$STATE2/RUN.md"
printf '# Plan\n\n1. step one\n' > "$PROJ2/plan.md"
git -C "$PROJ2" add -A >/dev/null 2>&1
git -C "$PROJ2" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1
printf '{"max_sessions":6,"review_every":2}\n' > "$STATE2/config.json"

mkconsent "$STATE2"
RELAY_MOCK_DIR="$MOCK2" RELAY_MOCK_SCRIPT="work,work,complete" \
  bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ2" "$STATE2" >"$PWD/out2.log" 2>"$PWD/err2.log"
RC2=$?

assert_rc 0 "$RC2" "c147_review_run_rc"
assert_grep "$STATE2/journal.log" 'mode=review' "c147_review_mode_journaled"
AUD_COUNT=$(grep -c -- "$AUDIT_LINE" "$MOCK2/argv.log")
assert_eq "1" "$AUD_COUNT" "c147_audit_preamble_exactly_once"
assert_grep "$MOCK2/argv.log" 'BUILD NOTHING NEW' "c147_audit_preamble_complete"
assert_no_grep "$MOCK2/argv.log" "$RECOVERY_LINE" "c147_no_recovery_preamble_in_review_run"

exit 0
