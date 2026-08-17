# test/cases/c105_window_floor_refused.sh — a context window below the floor is
# a preflight refusal, not a runtime discovery.
#
# Regression from relay's first real run. `window_opus` was set to 40000 on the
# theory that a small window makes handoffs fire quickly. A session already
# holds roughly 48k tokens of system prompt, tool definitions and CLAUDE.md
# before its first tool call, so the guard reported level 3 — "hand off even if
# incomplete" — on every call of every session. The run could only ever produce
# handoffs, never work, while spending a full session budget each time.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
printf '# RUN\n\nMinimal run.\n' > "$STATE/RUN.md"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":3,"window_opus":40000}
EOF

export RELAY_SKIP_PROBE=1
export RELAY_MOCK_SCRIPT="work"

bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

assert_rc 78 "$RC" "c105_rc_preflight"
assert_grep "$STATE/journal.log" 'config\.window-too-small' "c105_journaled"
assert_grep "$PWD/err.log" 'below the' "c105_explains_why"

# Refused before spending anything.
assert_no_file "$RELAY_MOCK_DIR/actions" "c105_no_session_launched"

exit 0
