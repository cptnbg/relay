# test/cases/c103_acceptance_cmd_is_argv_not_shell.sh — the acceptance command
# is executed as argv. Shell metacharacters inside an ELEMENT are literal data.
#
# Regression. The elements used to be re-quoted into a single string and
# `eval`'d, so an element containing a quote or `$(...)` got a shell. That
# destroys the property approval-by-hash exists to provide: wanting a shell is
# supposed to mean writing ["bash","-lc",...] where a human sees it while
# approving, not smuggling one inside an argument.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
mkrunmd "$STATE"
# plan.md is left UNCOMMITTED on purpose, exactly as c020 does: the mock's
# "complete" behaviour only writes into $STATE, so its blind `git add -A` needs
# something in the tree to turn into the new commit verify_complete demands.
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":3}
EOF

# Two elements chosen so the two failure modes are separately observable:
# command substitution (would print ABC) and word splitting (would print
# [two] [words] rather than [two words]).
cat > "$STATE/exec.json" <<'EOF'
{"acceptance_cmd":["printf","[%s]\n","A$(echo B)C","two words"]}
EOF
mkexec_hash "$STATE"

export RELAY_SKIP_PROBE=1
export RELAY_ALLOW_DIRTY=1
export RELAY_MOCK_SCRIPT="complete"

mkconsent "$STATE"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

ALOG="$STATE/run/acceptance.log"

assert_rc 0 "$RC" "c103_rc"
assert_file "$ALOG" "c103_acceptance_ran"

# Control: the command really did run and really did receive both elements.
assert_grep "$ALOG" 'two words' "c103_no_word_splitting"
assert_grep "$ALOG" 'echo B' "c103_element_passed_literally"

# The actual claim: no shell ever saw those characters.
assert_no_grep "$ALOG" 'ABC' "c103_no_command_substitution"

exit 0
