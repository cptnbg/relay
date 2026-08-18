# test/cases/c200_config_non_numeric_refused.sh — a non-numeric numeric config
# value is a preflight refusal, not a silently disabled cap.
#
# config.json is written by an LLM and edited by hand. A value like
# max_sessions:"twelve" used to be catastrophic-quiet: `[ "$N" -ge "twelve" ]`
# errors "integer expression expected" and evaluates false, so the session cap
# never trips — an unbounded, uncapped overnight run. A non-numeric value that
# reaches a `$(( ))` is worse: under `set -u` it is a fatal unbound-variable
# exit 127 mid-loop, breaking the exit-code contract. Relay now refuses at
# preflight for either.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
printf '# RUN\n\nMinimal run.\n' > "$STATE/RUN.md"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

# The dangerous case: an integer cap given a word. Fails open in the old code.
cat > "$STATE/config.json" <<'EOF'
{"max_sessions":"twelve"}
EOF

export RELAY_SKIP_PROBE=1
export RELAY_MOCK_SCRIPT="work,work,work,work,work,work,work,work"

bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

assert_rc 78 "$RC" "c200_rc_preflight"
assert_grep "$STATE/journal.log" 'config\.non-numeric' "c200_journaled"
assert_grep "$PWD/err.log" 'must be numbers' "c200_explains_why"
# Refused before launching any session — the cap did not silently disable.
assert_no_file "$RELAY_MOCK_DIR/actions" "c200_no_session_launched"

# A non-numeric FLOAT budget is caught the same way.
rm -rf "$STATE" && mkdir -p "$STATE"
printf '# RUN\n\nMinimal run.\n' > "$STATE/RUN.md"
cat > "$STATE/config.json" <<'EOF'
{"budget_usd_total":"twenty"}
EOF
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out2.log" 2>"$PWD/err2.log"
assert_rc 78 "$?" "c200_float_rc_preflight"
assert_grep "$PWD/err2.log" 'budget_usd_total' "c200_float_named"

exit 0
