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
cat > "$STATE/work/PLAN-INDEX.md" <<'EOF'
# PLAN INDEX
S1 | ## Phase 1 | one done
S2 | ## Phase 2 | two done
EOF

# Gates without a matching hash were never approved: refuse at preflight —
# whether the hash is missing or the gates were edited after approval.
printf '{"max_sessions":4}\n' > "$STATE/config.json"
mkconsent "$STATE"
export RELAY_MOCK_SCRIPT="work,complete"

printf '{"acceptance_cmd":null,"phase_gates":[{"id":"g1","after_step":"S1","cmd":["true"]}]}\n' > "$STATE/exec.json"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out1.log" 2>"$PWD/err1.log"
assert_rc 78 "$?" "c265_missing_hash_refused"
assert_grep "$STATE/journal.log" 'exec.gates-hash-missing' "c265_missing_journaled"

mkgates_hash "$STATE"
jq '.phase_gates[0].cmd = ["false"]' "$STATE/exec.json" > "$STATE/exec.json.tmp" \
  && mv "$STATE/exec.json.tmp" "$STATE/exec.json"
rm -f "$RELAY_MOCK_DIR/invocation_count"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out2.log" 2>"$PWD/err2.log"
assert_rc 78 "$?" "c265_edited_after_approval_refused"

printf '{"acceptance_cmd":null,"phase_gates":[{"id":"g1","after_step":"S1","cmd":["true"]},{"id":"g1","after_step":"S2","cmd":["true"]}]}\n' > "$STATE/exec.json"
mkgates_hash "$STATE"
rm -f "$RELAY_MOCK_DIR/invocation_count"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out3.log" 2>"$PWD/err3.log"
assert_rc 78 "$?" "c265_duplicate_ids_refused"
assert_grep "$STATE/journal.log" 'exec.gates-invalid' "c265_shape_journaled"
exit 0
