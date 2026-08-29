# test/cases/c140_lock_contention.sh — two supervisors on the same project:
# the first (hanging in a session, so it never releases the lock on its
# own) acquires the lock; a second one started right after must exit 25
# with lock contention noted in stderr and the journal. The background
# supervisor is reliably cleaned up on every exit path so the test never
# leaks a process.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
mkrunmd "$STATE"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":6,"max_timeouts":999}
EOF

export RELAY_SKIP_PROBE=1

PID1=""

cleanup() {
  if [ -n "$PID1" ]; then
    kill -TERM "$PID1" 2>/dev/null
    i=0
    while pgrep -f "$STATE" >/dev/null 2>&1; do
      i=$((i + 1))
      if [ "$i" -gt 30 ]; then
        pkill -9 -f "$STATE" 2>/dev/null
        break
      fi
      sleep 1
    done
    wait "$PID1" 2>/dev/null
  fi
  return 0
}
trap cleanup EXIT

# A single simple command with prefix var-assignments (NOT a
# "( export ...; bash ... ) &" multi-statement subshell): the latter forks
# an extra wrapper process, and "$!" would then be that wrapper's pid, not
# the actual relay-supervisor.sh process — killing the wrapper would leave
# the real supervisor running, orphaned. This form backgrounds
# relay-supervisor.sh itself, so PID1 is the pid that actually holds the
# lock.
mkconsent "$STATE"
RELAY_SESSION_TIMEOUT=3 RELAY_MOCK_HANG_SECS=30 RELAY_MOCK_SCRIPT="hang" \
  bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" \
  >"$PWD/out1.log" 2>"$PWD/err1.log" &
PID1=$!

i=0
while [ ! -f "$STATE/locks/run.d/owner" ] && [ "$i" -le 30 ]; do
  i=$((i + 1))
  sleep 0.3
done
assert_file "$STATE/locks/run.d/owner" "c140_setup_supervisor1_acquired_lock"

mkconsent "$STATE"
RELAY_MOCK_SCRIPT="work" bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out2.log" 2>"$PWD/err2.log"
RC2=$?

assert_rc 25 "$RC2" "c140_second_supervisor_locked_out"
assert_grep "$PWD/err2.log" 'another supervisor holds this project' "c140_stderr_mentions_contention"
assert_grep "$STATE/journal.log" 'lock\.contended' "c140_journal_mentions_contention"

exit 0
