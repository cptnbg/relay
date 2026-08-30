PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"
printf '# Plan\n\n## Phase 1\n\nstep one\n\n## Phase 2\n\nstep two\n\n## Phase 3\n\nstep three\n\n## Phase 4\n\nstep four\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com \
  commit -q -m "chore: add plan.md" >/dev/null 2>&1
mkdir -p "$STATE/work"
mkrunmd "$STATE"
export RELAY_SKIP_PROBE=1
cat > "$STATE/work/PLAN-INDEX.md" <<'EOF'
# PLAN INDEX — generated at init
S1 | ## Phase 1 | step one done
S2 | ## Phase 2 | step two done
S3 | ## Phase 3 | step three done
S4 | ## Phase 4 | step four done
EOF

# A step id the index cannot order opts out of drift detection, loudly.
printf '{"max_sessions":5,"review_every":50}\n' > "$STATE/config.json"
mkconsent "$STATE"
export RELAY_MOCK_PLAN_STEP="polish-docs,S1"
export RELAY_MOCK_SCRIPT="work,work,complete"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
assert_rc 0 "$?" "c260_completed"
assert_grep "$STATE/journal.log" 'drift.step-unknown	step=polish-docs' "c260_unknown_journaled"
assert_no_grep "$STATE/journal.log" 'drift.suspected' "c260_no_false_drift"
assert_no_grep "$STATE/journal.log" 'mode=review' "c260_no_review_forced"
exit 0
