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

# A plan change with an index in play forces ONE review (which regenerates the
# index) — and the forced review counts as the last review, so the cadence
# does not land a second audit on the very next session.
printf '{"max_sessions":8,"review_every":2}\n' > "$STATE/config.json"
mkconsent "$STATE"
export RELAY_MOCK_SCRIPT="planedit,work,work,complete"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
assert_rc 0 "$?" "c254_completed"
assert_grep "$STATE/journal.log" 'index.stale' "c254_stale_journaled"
assert_grep "$STATE/journal.log" 'session.start	n=2 .* mode=review' "c254_forced_review_next"
assert_no_grep "$STATE/journal.log" 'session.start	n=3 .* mode=review' "c254_no_double_review"
exit 0
