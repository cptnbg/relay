# c231 — an unknown sandbox_mode is refused at preflight (78), before any probe
# or session, exactly like an invalid model_tier. A valid `disabled` value is
# accepted at the same gate. Modeled on c203.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE/work"
mkrunmd "$STATE"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":3,"sandbox_mode":"yolo"}
EOF
mkconsent "$STATE"

export RELAY_SKIP_PROBE=1
export RELAY_ALLOW_DIRTY=1
export RELAY_MOCK_SCRIPT="complete"

bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

JOURNAL="$STATE/journal.log"

assert_rc 78 "$RC" "c231_preflight_exit"
assert_grep "$JOURNAL" 'config\.sandbox-mode-invalid' "c231_journal_line"
assert_grep "$PWD/err.log" 'sandbox_mode must be enforced or disabled' "c231_message"
assert_no_grep "$JOURNAL" 'session\.start' "c231_no_session_started"
# No session behaviour was ever consumed. (argv.log is not the discriminator
# here: this gate sits after doctor, which legitimately runs `claude --version`.)
assert_no_file "$RELAY_MOCK_DIR/actions" "c231_no_session_invocations"

# A valid `disabled` value is accepted at this gate and runs to completion.
STATE2="$PWD/state2"
mkdir -p "$STATE2/work"
mkrunmd "$STATE2"
printf '{"max_sessions":2,"sandbox_mode":"disabled"}\n' > "$STATE2/config.json"
mkconsent "$STATE2"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE2" >"$PWD/out2.log" 2>"$PWD/err2.log"
RC2=$?
assert_rc 0 "$RC2" "c231_valid_disabled_still_runs"
assert_json "$STATE2/state.json" '.sandbox_mode' "disabled" "c231_state_records_mode"

exit 0
