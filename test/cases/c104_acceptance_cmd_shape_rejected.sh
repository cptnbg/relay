# test/cases/c104_acceptance_cmd_shape_rejected.sh — an acceptance_cmd that is
# not a usable argv array is a preflight failure, not something to interpret
# helpfully. A shell string ("npm test") is the shape a user reaches for by
# habit; accepting it would mean guessing where the argument boundaries are.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
mkrunmd "$STATE"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":3}
EOF

cat > "$STATE/exec.json" <<'EOF'
{"acceptance_cmd":"npm test"}
EOF

export RELAY_SKIP_PROBE=1
export RELAY_MOCK_SCRIPT="complete"

mkconsent "$STATE"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

assert_rc 78 "$RC" "c104_rc_preflight"

# It refused before spending anything: no session was ever launched.
assert_no_file "$RELAY_MOCK_DIR/actions" "c104_no_session_launched"

exit 0
