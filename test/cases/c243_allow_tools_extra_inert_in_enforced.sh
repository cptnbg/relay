PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com \
  commit -q -m "chore: add plan.md" >/dev/null 2>&1
mkdir -p "$STATE/work"
mkrunmd "$STATE"

# In enforced mode the key is configured-not-applied: journaled with the mode
# so the journal reads honestly, absent from the payload so the enforced
# bytes stay the release-asserted constant.
cat > "$STATE/config.json" <<'EOF'
{"max_sessions":4,"sandbox_mode":"enforced","allow_tools_extra":"Monitor"}
EOF
mkconsent "$STATE"
export RELAY_SKIP_PROBE=1
export RELAY_MOCK_SCRIPT="work,complete"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
assert_rc 0 "$?" "c243_run_completed"
assert_grep "$STATE/journal.log" 'permissions.extra-tools' "c243_journaled"
assert_grep "$STATE/journal.log" 'mode=enforced' "c243_journal_names_mode"
assert_json "$RELAY_MOCK_DIR/flags-last.json" \
  '(.settings | fromjson | .permissions.allow | index("Monitor"))' "null" "c243_extra_absent"
assert_json "$RELAY_MOCK_DIR/flags-last.json" \
  '(.settings | fromjson | .permissions.allow | index("WebFetch"))' "null" "c243_webfetch_absent"
exit 0
