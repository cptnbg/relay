# PKG-3 regression: a junk model_tier used to fall through window_for_tier's
# `*)` arm to window_opus silently and then be passed verbatim to `--model`.
# It must refuse at preflight (78) instead, before any session or probe.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE/work"
mkrunmd "$STATE"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":3,"model_tier":"gpt-5-ultra"}
EOF
mkconsent "$STATE"

export RELAY_SKIP_PROBE=1
export RELAY_ALLOW_DIRTY=1
export RELAY_MOCK_SCRIPT="complete"

bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

JOURNAL="$STATE/journal.log"

assert_rc 78 "$RC" "c203_preflight_exit"
assert_grep "$JOURNAL" 'config\.model-tier-invalid' "c203_journal_line"
assert_grep "$PWD/err.log" 'model_tier must be one of opus\|sonnet\|fable' "c203_message"
assert_no_grep "$JOURNAL" 'session\.start' "c203_no_session_started"
# The junk value must never have reached a claude invocation.
assert_no_file "$RELAY_MOCK_DIR/argv.log" "c203_claude_never_invoked"

# The three valid tiers must still be accepted (sonnet spot-check).
STATE2="$PWD/state2"
mkdir -p "$STATE2/work"
mkrunmd "$STATE2"
printf '{"max_sessions":2,"model_tier":"sonnet"}\n' > "$STATE2/config.json"
mkconsent "$STATE2"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE2" >"$PWD/out2.log" 2>"$PWD/err2.log"
RC2=$?
assert_rc 0 "$RC2" "c203_valid_tier_still_runs"

exit 0
