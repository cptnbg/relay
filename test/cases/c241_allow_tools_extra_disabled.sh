PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com \
  commit -q -m "chore: add plan.md" >/dev/null 2>&1
mkdir -p "$STATE/work"
mkrunmd "$STATE"

# allow_tools_extra reaches the disabled payload, deduped, journaled — the
# escape hatch for tool names relay has never heard of (a real Monitor call
# was observed DENIED mid-run; this key is how an operator fixes that without
# waiting for a relay release).
cat > "$STATE/config.json" <<'EOF'
{"max_sessions":4,"sandbox_mode":"disabled","allow_tools_extra":"Monitor,SendMessage,Bash"}
EOF
mkconsent "$STATE"
export RELAY_MOCK_PROBE=open
export RELAY_MOCK_SCRIPT="work,complete"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
assert_rc 0 "$?" "c241_run_completed"
assert_grep "$STATE/journal.log" 'permissions.extra-tools' "c241_journaled"
assert_grep "$STATE/journal.log" 'mode=disabled' "c241_journal_names_mode"
assert_json "$RELAY_MOCK_DIR/flags-last.json" \
  '(.settings | fromjson | .permissions.allow | index("Monitor")) != null' "true" "c241_extra_tool_in_allow"
assert_json "$RELAY_MOCK_DIR/flags-last.json" \
  '(.settings | fromjson | .permissions.allow | index("WebFetch")) != null' "true" "c241_webfetch_in_allow"
assert_json "$RELAY_MOCK_DIR/flags-last.json" \
  '(.settings | fromjson | .permissions.allow | map(select(. == "Bash")) | length)' "1" "c241_deduped"
exit 0
