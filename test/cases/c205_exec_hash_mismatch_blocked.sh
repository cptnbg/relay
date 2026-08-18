# PKG-5 regression: exec.json's acceptance_cmd carries exec_hash, recorded at
# /relay-approve time. Before running the acceptance command the supervisor
# recomputes the hash from the file on disk and halts BLOCKED on mismatch —
# an out-of-band edit between approval and execution must never reach exec.
# An acceptance_cmd with NO exec_hash at all was never approved: preflight 78.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE/work"
printf '# RUN\n\nMinimal run.\n' > "$STATE/work/RUN.md"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":3}
EOF
mkconsent "$STATE"

# A well-formed argv whose exec_hash is a VALID 40-hex blob id — just not the
# hash of this argv. This is exactly what an edit-after-approval looks like.
cat > "$STATE/exec.json" <<'EOF'
{"acceptance_cmd":["true"],
 "exec_hash":"0000000000000000000000000000000000000000"}
EOF

export RELAY_SKIP_PROBE=1
export RELAY_ALLOW_DIRTY=1
export RELAY_MOCK_SCRIPT="complete"

bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

JOURNAL="$STATE/journal.log"

assert_rc 20 "$RC" "c205_blocked_exit"
assert_grep "$JOURNAL" 'exec\.hash-mismatch' "c205_journal_line"
assert_file "$STATE/work/BLOCKED.md" "c205_blocked_md_written"
assert_grep "$STATE/work/BLOCKED.md" 'approval verification' "c205_blocked_md_says_why"
assert_grep "$STATE/work/BLOCKED.md" 'relay:sealed' "c205_blocked_md_sealed"
# The unapproved command must never have run.
assert_no_grep "$JOURNAL" 'acceptance\.run' "c205_acceptance_never_ran"
assert_no_file "$STATE/run/acceptance.log" "c205_no_acceptance_log"

# Missing exec_hash entirely = never approved = preflight refusal.
STATE2="$PWD/state2"
mkdir -p "$STATE2/work"
printf '{"max_sessions":3}\n' > "$STATE2/config.json"
mkconsent "$STATE2"
printf '{"acceptance_cmd":["true"]}\n' > "$STATE2/exec.json"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE2" >"$PWD/out2.log" 2>"$PWD/err2.log"
RC2=$?
assert_rc 78 "$RC2" "c205_missing_hash_preflight"
assert_grep "$STATE2/journal.log" 'exec\.hash-missing' "c205_missing_hash_journal"
assert_grep "$PWD/err2.log" '/relay-approve' "c205_missing_hash_remedy"

# A correctly approved command (hash recorded over the same canonical bytes)
# must still run and complete: enforcement must not break the honest path.
# Fresh mock dir: the mock's invocation counter is global per RELAY_MOCK_DIR,
# and a work step must land a real commit for verify_complete's commit check.
STATE3="$PWD/state3"
mkdir -p "$STATE3/work" "$PWD/mock3"
printf '{"max_sessions":3}\n' > "$STATE3/config.json"
mkconsent "$STATE3"
printf '{"acceptance_cmd":["true"]}\n' > "$STATE3/exec.json"
mkexec_hash "$STATE3"
RELAY_MOCK_DIR="$PWD/mock3" RELAY_MOCK_SCRIPT="work,complete" \
  bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE3" >"$PWD/out3.log" 2>"$PWD/err3.log"
RC3=$?
assert_rc 0 "$RC3" "c205_approved_cmd_still_runs"
assert_grep "$STATE3/journal.log" 'acceptance\.run' "c205_approved_acceptance_ran"

exit 0
