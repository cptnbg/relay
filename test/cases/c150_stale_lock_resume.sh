# test/cases/c150_stale_lock_resume.sh — simulate a supervisor crash
# (kill -9, so it never gets a chance to release its lock) then start a
# second supervisor against the same state dir. Since the owning pid is
# dead on this host, the second run must detect the stale lock, break it,
# and proceed — not exit 25.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
printf '# RUN\n\nMinimal run.\n' > "$STATE/RUN.md"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":6}
EOF

export RELAY_SKIP_PROBE=1

PID1=""

cleanup() {
  # supervisor1 was already kill -9'd below; this only mops up any hung
  # descendant left behind by that crash (relay_timeout's own internal
  # deadline will have killed it independently, this just confirms it).
  i=0
  while pgrep -f "$STATE" >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -gt 30 ]; then
      pkill -9 -f "$STATE" 2>/dev/null
      break
    fi
    sleep 1
  done
  return 0
}
trap cleanup EXIT

# A single simple command with prefix var-assignments (NOT a
# "( export ...; bash ... ) &" multi-statement subshell): the latter forks
# an extra wrapper process, and "$!" would then be that wrapper's pid, not
# the actual relay-supervisor.sh process that records itself as the lock
# owner — kill -9 on the wrapper would leave the real supervisor (and the
# lock) alive, which is exactly what happened the first time this test was
# written. This form backgrounds relay-supervisor.sh itself.
mkconsent "$STATE"
RELAY_SESSION_TIMEOUT=5 RELAY_MOCK_HANG_SECS=20 RELAY_MOCK_SCRIPT="hang" \
  bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" \
  >"$PWD/out1.log" 2>"$PWD/err1.log" &
PID1=$!

i=0
while [ ! -f "$STATE/locks/run.d/owner" ] && [ "$i" -le 30 ]; do
  i=$((i + 1))
  sleep 0.3
done
assert_file "$STATE/locks/run.d/owner" "c150_setup_supervisor1_acquired_lock"

kill -9 "$PID1" 2>/dev/null
i=0
while kill -0 "$PID1" 2>/dev/null && [ "$i" -le 20 ]; do
  i=$((i + 1))
  sleep 0.3
done
wait "$PID1" 2>/dev/null

mkconsent "$STATE"
RELAY_MOCK_SCRIPT="work,complete" bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out2.log" 2>"$PWD/err2.log"
RC2=$?

assert_ne "25" "$RC2" "c150_second_run_not_locked_out"
assert_rc 0 "$RC2" "c150_second_run_completed"
assert_grep "$STATE/journal.log" 'lock_break' "c150_stale_lock_was_broken"

exit 0
