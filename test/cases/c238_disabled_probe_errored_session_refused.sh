# c238 — the full-trust probe must refuse when the probe session itself failed.
#
# Coverage hole, not a regression: `relay_settings_probe_disabled` has three
# assertions, and until now only (b) hook-fired and (c) canary-readable were
# exercised. Assertion (a) — the session completed cleanly — had no test at all,
# because every mock probe arm emitted `is_error:false`. Deleting that check
# left the whole suite green.
#
# It matters because a session that died (budget exhausted, model refusal, a
# crash) writes no evidence files, and absent evidence must never be read as a
# verdict about the payload. Failing here keeps the two apart.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
mkrunmd "$STATE"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":4,"sandbox_mode":"disabled"}
EOF

export RELAY_MOCK_PROBE=errored
export RELAY_MOCK_SCRIPT="work,complete"

mkconsent "$STATE"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

JOURNAL="$STATE/journal.log"

assert_rc 78 "$RC" "c238_refused"
assert_grep "$JOURNAL" 'probe\.start' "c238_probe_ran"
assert_grep "$JOURNAL" 'probe\.failed' "c238_probe_failed_journaled"
assert_no_grep "$JOURNAL" 'probe\.ok' "c238_no_probe_ok"
assert_no_grep "$JOURNAL" 'session\.start' "c238_no_session_launched"
assert_json "$STATE/state.json" '.reason' "settings-not-accepted" "c238_reason"
assert_grep "$PWD/err.log" 'did not complete cleanly' "c238_stderr_names_the_cause"

# Assertion (a) must fire FIRST: with no evidence written, relay must not go on
# to report anything about the hook or the canary, either way.
assert_no_grep "$JOURNAL" 'probe\.hook' "c238_no_hook_verdict_claimed"
assert_no_grep "$JOURNAL" 'probe\.trust-canary' "c238_no_canary_verdict_claimed"

exit 0
