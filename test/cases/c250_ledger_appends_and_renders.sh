PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"
printf '# Plan\n\n## Phase 1\n\nstep one\n\n## Phase 2\n\nstep two\n\n## Phase 3\n\nstep three\n\n## Phase 4\n\nstep four\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com \
  commit -q -m "chore: add plan.md" >/dev/null 2>&1
mkdir -p "$STATE/work"
mkrunmd "$STATE"
export RELAY_SKIP_PROBE=1

# The run ledger: one supervisor-written line per session, rendered into every
# LATER prompt — the arc a session 30 otherwise lacks entirely.
printf '{"max_sessions":6}\n' > "$STATE/config.json"
mkconsent "$STATE"
export RELAY_MOCK_SCRIPT="work,work,complete"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
assert_rc 0 "$?" "c250_completed"
assert_file "$STATE/ledger.md" "c250_ledger_at_state_root"
# Two rows, not three: the completing session exits at the COMPLETE
# predicate, before bookkeeping — correctly, since the ledger informs FUTURE
# prompts and a completing session has none.
assert_eq "2" "$(grep -c '^| [0-9]' "$STATE/ledger.md")" "c250_one_row_per_surviving_session"
assert_grep "$STATE/ledger.md" '^| 1 | normal | opus | 1 | 1 |' "c250_row_shape"
# Session 1's prompt has no ledger (no history yet); session 2's does, and it
# carries session 1's note.
# argv.log cannot be split by line (prompts contain newlines); carve the
# per-session segments on the prompt's own opening sentence instead.
tr '\0' ' ' < "$RELAY_MOCK_DIR/argv.log" > "$PWD/argv.txt"
_p1=$(awk '/You are session 1 of/{f=1} /You are session 2 of/{f=0} f' "$PWD/argv.txt")
_p2=$(awk '/You are session 2 of/{f=1} /You are session 3 of/{f=0} f' "$PWD/argv.txt")
case "$_p1" in *run-ledger*) _assert_fail "c250_session1_has_no_ledger" ;; *) assert_eq ok ok "c250_session1_has_no_ledger" ;; esac
case "$_p2" in *run-ledger*) assert_eq ok ok "c250_session2_renders_ledger" ;; *) _assert_fail "c250_session2_renders_ledger" ;; esac
case "$_p2" in *"invocation 1"*) assert_eq ok ok "c250_note_carried" ;; *) _assert_fail "c250_note_carried" ;; esac
exit 0
