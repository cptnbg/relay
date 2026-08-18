# PKG-2 regression: a plan_path that does not resolve to an existing file must
# refuse at preflight (EX_PREFLIGHT=78) with a journal line, never start a
# session, and never let the run "succeed" while every session silently builds
# from nothing but RUN.md and the handoff.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE/work"
printf '# RUN\n\nMinimal run.\n' > "$STATE/work/RUN.md"
# Deliberately NO plan.md anywhere; config names one that does not exist.

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":3,"plan_path":"docs/does-not-exist.md"}
EOF
mkconsent "$STATE"

export RELAY_SKIP_PROBE=1
export RELAY_MOCK_SCRIPT="complete"

bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

JOURNAL="$STATE/journal.log"

assert_rc 78 "$RC" "c202_preflight_exit"
assert_grep "$JOURNAL" 'preflight\.plan-missing' "c202_journal_line"
assert_grep "$PWD/err.log" 'plan file does not exist' "c202_message"
# A relative plan_path must be resolved against the PROJECT, and the message
# must show the resolved path so the user can see what was actually checked.
assert_grep "$PWD/err.log" 'proj/docs/does-not-exist\.md' "c202_resolved_against_project"
assert_no_grep "$JOURNAL" 'session\.start' "c202_no_session_started"

# Default plan_path ($PROJECT/plan.md) missing must refuse the same way.
STATE2="$PWD/state2"
mkdir -p "$STATE2/work"
printf '{"max_sessions":3}\n' > "$STATE2/config.json"
mkconsent "$STATE2"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE2" >"$PWD/out2.log" 2>"$PWD/err2.log"
RC2=$?
assert_rc 78 "$RC2" "c202_default_plan_missing_refused"
assert_grep "$STATE2/journal.log" 'preflight\.plan-missing' "c202_default_journal_line"

exit 0
