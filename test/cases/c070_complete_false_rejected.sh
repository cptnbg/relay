# test/cases/c070_complete_false_rejected.sh — "complete_false" repeated:
# the mock seals COMPLETE.md but never touches the project tree, so
# verify_complete's "no commits were made" check must reject it every time.
# After 3 rejections relay-supervisor.sh gives up and exits 27
# (completion-rejected) rather than looping forever. Give it enough sessions
# of headroom (max_sessions 6) that it never simply hits the cap first.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
mkrunmd "$STATE"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":6}
EOF

export RELAY_SKIP_PROBE=1
export RELAY_MOCK_SCRIPT="complete_false"

mkconsent "$STATE"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

JOURNAL="$STATE/journal.log"

assert_ne "0" "$RC" "c070_did_not_report_success"
assert_rc 27 "$RC" "c070_rc_is_completion_rejected"
assert_no_file "$STATE/work/COMPLETE.md" "c070_complete_md_deleted"

# Each rejection cycle logs "complete.rejected" TWICE: once inside
# verify_complete() with the specific reason ("no commits were made"), and
# once more by its caller with "n=$N" as the detail. Match the caller's
# distinct "n=" line to count rejection cycles precisely (3), not raw event
# occurrences (6).
REJCNT=$(grep -Fc -- "$(printf '\tcomplete.rejected\tn=')" "$JOURNAL")
assert_eq "3" "$REJCNT" "c070_three_rejection_cycles"

exit 0
