# RUN.md missing at preflight must refuse (EX_PREFLIGHT=78) with a journal line
# and no session started — the symmetric case to c202's plan guard, and for the
# same reason. RUN.md carries the mission, the acceptance criteria, the
# guardrails and the "decisions already made" every session is told to read
# FIRST. Without it the run does not fail visibly: it works all night against no
# acceptance criteria while the journal looks healthy.
#
# The path is half the point. RUN.md is canonically $STATE/work/RUN.md — under
# work/ because sessions must read it and review sessions append to it. A file
# at $STATE/RUN.md is not read by anything, and before this guard existed most
# of the test suite seeded it there and passed.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE/work"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com \
  commit -q -m "chore: add plan.md" >/dev/null 2>&1

printf '{"max_sessions":3}\n' > "$STATE/config.json"
mkconsent "$STATE"

export RELAY_SKIP_PROBE=1
export RELAY_MOCK_SCRIPT="work,complete"

# No RUN.md anywhere.
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

assert_rc 78 "$RC" "c206_preflight_exit"
assert_grep "$STATE/journal.log" 'preflight\.run-md-missing' "c206_journal_line"
assert_grep "$PWD/err.log" 'RUN\.md does not exist' "c206_message"
assert_grep "$PWD/err.log" 'relay-init' "c206_remedy_names_init"
assert_no_grep "$STATE/journal.log" 'session\.start' "c206_no_session_started"

# The wrong-but-plausible location must NOT satisfy the guard: $STATE/RUN.md is
# outside the sandbox's writable set and outside everything that reads it.
STATE2="$PWD/state2"
mkdir -p "$STATE2/work"
printf '# RUN\n\nSeeded in the wrong place on purpose.\n' > "$STATE2/RUN.md"
printf '{"max_sessions":3}\n' > "$STATE2/config.json"
mkconsent "$STATE2"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE2" >"$PWD/out2.log" 2>"$PWD/err2.log"
assert_rc 78 "$?" "c206_state_root_runmd_does_not_count"
assert_grep "$STATE2/journal.log" 'preflight\.run-md-missing' "c206_wrong_path_journaled"

# And the canonical location satisfies it: same config, RUN.md under work/.
STATE3="$PWD/state3"
mkdir -p "$STATE3/work"
mkrunmd "$STATE3"
printf '{"max_sessions":3}\n' > "$STATE3/config.json"
mkconsent "$STATE3"
# The mock's invocation counter is a FILE that outlives a run; two supervisors
# already ran in this sandbox, so reset it before the one that must succeed.
rm -f "$RELAY_MOCK_DIR/invocation_count"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE3" >"$PWD/out3.log" 2>"$PWD/err3.log"
assert_rc 0 "$?" "c206_canonical_path_runs"
assert_no_grep "$STATE3/journal.log" 'preflight\.run-md-missing' "c206_canonical_not_journaled"

exit 0
