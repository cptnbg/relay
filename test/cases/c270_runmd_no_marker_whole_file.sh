PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"
printf '# Plan\n\n## Phase 1\n\none\n\n## Phase 2\n\ntwo\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com \
  commit -q -m "chore: add plan.md" >/dev/null 2>&1
mkdir -p "$STATE/work"
mkrunmd "$STATE"
export RELAY_SKIP_PROBE=1

# No "## Course corrections" marker => the WHOLE file is protected (fail
# closed) — even an append halts. The sharp edge is deliberate and announced
# at startup, which is what this case pins.
printf '# RUN\n\nno marker in this file\n' > "$STATE/work/RUN.md"
printf '{"max_sessions":4}\n' > "$STATE/config.json"
mkconsent "$STATE"
export RELAY_MOCK_SCRIPT="runmdappend,complete"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
assert_rc 20 "$?" "c270_append_halts_without_marker"
assert_grep "$STATE/journal.log" 'runmd.no-marker' "c270_warned_at_start"
assert_grep "$STATE/journal.log" 'runmd.tampered' "c270_tamper_detected"
exit 0
