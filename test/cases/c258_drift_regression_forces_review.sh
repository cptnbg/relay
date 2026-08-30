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

# A step going BACKWARD in index order forces one review — never a halt — and
# the forced review suppresses re-triggering through the cooldown.
printf '{"max_sessions":9,"review_every":50}\n' > "$STATE/config.json"
mkconsent "$STATE"
export RELAY_MOCK_PLAN_STEP="S3,S2,S2,S1,S4,S4"
export RELAY_MOCK_SCRIPT="work,work,work,work,work,complete"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
assert_rc 0 "$?" "c258_completed"
assert_grep "$STATE/journal.log" 'drift.suspected	last=S3 cur=S2 kind=regression' "c258_regression_detected"
assert_grep "$STATE/journal.log" 'session.start	n=3 .* mode=review' "c258_review_forced"
assert_eq "1" "$(grep -c 'drift.suspected' "$STATE/journal.log")" "c258_cooldown_suppresses_second"
exit 0
