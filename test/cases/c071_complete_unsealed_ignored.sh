# test/cases/c071_complete_unsealed_ignored.sh — an UNSEALED COMPLETE.md
# (no <!-- relay:sealed --> marker) sitting in $STATE before the supervisor
# ever runs must never be accepted as a finished build.
#
# NOTE on actual behaviour vs. the naive expectation: relay-supervisor.sh's
# verify_complete() itself contains a guard
#   sealed "$STATE/work/COMPLETE.md" || { relay_journal "sentinel.unsealed" ...; return 1; }
# but BOTH call sites already gate on `sealed "$STATE/work/COMPLETE.md" && verify_complete`
# (top of the loop) or `if sealed "$STATE/work/COMPLETE.md"; then if verify_complete; then ...`
# (after a session). verify_complete() is therefore only ever invoked once
# sealed() has already returned true, which makes its own internal sealed()
# check unreachable dead code in the current source — an unsealed
# COMPLETE.md is silently ignored by both call sites rather than being
# explicitly rejected and journaled. See the final report for the precise
# file/line citation. This test asserts the REACHABLE behaviour: the run
# never completes and the file is left exactly as written (never deleted,
# never sealed) — not the "sentinel.unsealed" journal line, which cannot
# fire given the current call sites.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE" "$STATE/work"
printf '# RUN\n\nMinimal run.\n' > "$STATE/RUN.md"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":6,"stall_limit":2}
EOF

# Unsealed on purpose: no "<!-- relay:sealed -->" line anywhere in this file.
printf '# Relay build complete\n\nAll done (allegedly, and not sealed).\n' > "$STATE/work/COMPLETE.md"

export RELAY_SKIP_PROBE=1
export RELAY_MOCK_SCRIPT="noop"

mkconsent "$STATE"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

assert_ne "0" "$RC" "c071_did_not_report_success"
assert_rc 21 "$RC" "c071_rc_is_stalled"
assert_file "$STATE/work/COMPLETE.md" "c071_complete_md_still_present"
assert_no_grep "$STATE/work/COMPLETE.md" 'relay:sealed' "c071_still_unsealed_untouched"

exit 0
