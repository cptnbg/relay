# test/cases/c131_forbidden_flags_never_present.sh — the mock exits 99 on
# any of --dangerously-skip-permissions, --bare, --no-session-persistence,
# --safe-mode. A normal run passing at all is already evidence, but this
# also inspects the recorded argv directly for those literal strings.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
mkrunmd "$STATE"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":4}
EOF

export RELAY_SKIP_PROBE=1
export RELAY_MOCK_SCRIPT="work,complete"

mkconsent "$STATE"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

assert_rc 0 "$RC" "c131_rc"

ARGV="$RELAY_MOCK_DIR/argv.log"
assert_file "$ARGV" "c131_argv_recorded"
assert_grep "$ARGV" '--setting-sources' "c131_sanity_argv_has_real_content"

assert_no_grep "$ARGV" '\-\-dangerously\-skip\-permissions' "c131_no_dangerously_skip_permissions"
assert_no_grep "$ARGV" '\-\-bare' "c131_no_bare"
assert_no_grep "$ARGV" '\-\-no\-session\-persistence' "c131_no_no_session_persistence"
assert_no_grep "$ARGV" '\-\-safe\-mode' "c131_no_safe_mode"

exit 0
