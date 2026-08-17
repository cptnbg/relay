# test/cases/c130_required_flags_always_present.sh — every single mock
# invocation across a normal run must carry both --setting-sources and
# --strict-mcp-config (the mock itself would exit 98 if either were
# missing, so a passing run is already partial proof; this checks the
# recorded flags directly too).
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
printf '# RUN\n\nMinimal run.\n' > "$STATE/RUN.md"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":4}
EOF

export RELAY_SKIP_PROBE=1
export RELAY_MOCK_SCRIPT="work,complete"

bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

assert_rc 0 "$RC" "c130_rc"
assert_file "$RELAY_MOCK_DIR/flags.jsonl" "c130_flags_recorded"

ALLOK=$(jq -s 'all(.[]; .setting_sources_present == true and .strict_mcp_config == true)' "$RELAY_MOCK_DIR/flags.jsonl")
assert_eq "true" "$ALLOK" "c130_every_invocation_had_both_required_flags"

ARGV="$RELAY_MOCK_DIR/argv.log"
assert_grep "$ARGV" '--setting-sources' "c130_argv_has_setting_sources"
assert_grep "$ARGV" '--strict-mcp-config' "c130_argv_has_strict_mcp_config"

exit 0
