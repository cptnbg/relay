# test/cases/c190_window_vs_measured_baseline.sh — once a project's context
# baseline has been measured, a window too small for THAT baseline is refused.
#
# The fixed 100k floor is not enough on its own. A session's cost at rest is not
# a constant: it was 48k on a toy repository and 69k on aeia-rebuild, because
# the project's CLAUDE.md is loaded before the first tool call. On aeia-rebuild
# a 120k window put the 60% soft threshold at 72k, three thousand tokens above
# the baseline, so sessions reached "start landing" after six tool calls and two
# consecutive ones committed nothing.
#
# The rule: the soft threshold must clear the measured baseline by at least a
# fifth of the window, i.e. window >= 2.5x baseline.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
printf '# RUN\n\nMinimal run.\n' > "$STATE/RUN.md"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

export RELAY_SKIP_PROBE=1
export RELAY_MOCK_SCRIPT="work"

# 120000 clears the fixed floor, so only the measured baseline can catch it.
cat > "$STATE/config.json" <<'EOF'
{"max_sessions":2,"window_opus":120000}
EOF
cat > "$STATE/state.json" <<'EOF'
{"run_id":"c190","status":"running","session_count":"1","ctx_baseline":"69000","next_tier":"opus","next_mode":"normal","commits_at_start":"2"}
EOF

bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

assert_rc 78 "$RC" "c190_refused"
assert_grep "$STATE/journal.log" 'config\.window-too-small-for-baseline' "c190_journaled"
# The message has to say what to set, or it just tells the user they are stuck.
assert_grep "$PWD/err.log" '172500' "c190_names_the_required_window"
assert_no_file "$RELAY_MOCK_DIR/actions" "c190_no_session_launched"

# --- and a window that DOES clear the baseline still runs -----------------
PROJ2="$PWD/proj2"
STATE2="$PWD/state2"
mkrepo "$PROJ2"
mkdir -p "$STATE2"
printf '# RUN\n\nMinimal run.\n' > "$STATE2/RUN.md"
printf '# Plan\n\n1. step one\n' > "$PROJ2/plan.md"
git -C "$PROJ2" add -A >/dev/null 2>&1
git -C "$PROJ2" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

cat > "$STATE2/config.json" <<'EOF'
{"max_sessions":1,"window_opus":200000}
EOF
cat > "$STATE2/state.json" <<'EOF'
{"run_id":"c190b","status":"running","session_count":"0","ctx_baseline":"69000","next_tier":"opus","next_mode":"normal","commits_at_start":"2"}
EOF

bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ2" "$STATE2" >"$PWD/out2.log" 2>"$PWD/err2.log"

assert_no_grep "$STATE2/journal.log" 'window-too-small' "c190_adequate_window_allowed"
assert_grep "$STATE2/journal.log" 'session\.start' "c190_adequate_window_runs"

exit 0
