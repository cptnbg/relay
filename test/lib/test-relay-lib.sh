#!/usr/bin/env bash
# test-relay-lib.sh — standalone unit tests for relay-lib.sh.
# Usage: bash test/lib/test-relay-lib.sh
# Exit 0 = all pass. Non-zero = at least one failure (named in output).
#
# No bats, no external test framework. Targets bash 3.2.57 same as the
# library under test.
set -u
set -o pipefail
umask 077
LC_ALL=C
export LC_ALL
IFS=$' \t\n'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$SCRIPT_DIR/../../plugins/relay/scripts/lib/relay-lib.sh"

if [ ! -f "$LIB" ]; then
  printf 'test-relay-lib.sh: cannot find library at %s\n' "$LIB" >&2
  exit 1
fi

# shellcheck source=/dev/null
. "$LIB"

# --- test bookkeeping -------------------------------------------------
# Deliberately avoid bash arrays for the failure list: bash 3.2's `set -u`
# throws "unbound variable" on `"${arr[@]}"` for an array that has never
# held an element (confirmed empirically), so a plain newline-accumulated
# string is more robust across bash 3.2 quirks than an array workaround.
PASS_COUNT=0
FAIL_COUNT=0
FAILED_LIST=""

ok() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'ok %s\n' "$1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_LIST="${FAILED_LIST}${1}
"
  printf 'FAIL %s: %s\n' "$1" "${2:-}"
}

assert_eq() { # name expected actual
  if [ "$2" = "$3" ]; then
    ok "$1"
  else
    fail "$1" "expected [$2] got [$3]"
  fi
}

assert_status() { # name expected_status actual_status
  assert_eq "$1" "$2" "$3"
}

is_numeric() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

looks_like_uuid() {
  case "${1:-}" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
      return 0 ;;
    *) return 1 ;;
  esac
}

looks_like_hash40() {
  case "${1:-}" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
      return 0 ;;
    cksum:*)
      return 0 ;;
    *) return 1 ;;
  esac
}

# ===========================================================================
# relay_timeout
# ===========================================================================
test_timeout() {
  local grp
  grp="$(mktemp -d "${TMPDIR:-/tmp}/relaytest.timeout.XXXXXX")"

  relay_timeout 5 true
  assert_status "timeout_fast_exit0" 0 "$?"

  relay_timeout 5 bash -c 'exit 3'
  assert_status "timeout_fast_exit3" 3 "$?"

  # no leaked background jobs after normal (non-deadline) runs
  local leaked
  leaked="$(jobs -p)"
  if [ -z "$leaked" ]; then
    ok "timeout_no_leak_fastpath"
  else
    fail "timeout_no_leak_fastpath" "leaked jobs: $leaked"
  fi

  local start end elapsed rc
  start="$(date +%s)"
  relay_timeout 2 sleep 10
  rc="$?"
  end="$(date +%s)"
  elapsed=$((end - start))

  assert_status "timeout_deadline_rc124" 124 "$rc"
  if [ "$elapsed" -le 6 ]; then
    ok "timeout_deadline_fast_return"
  else
    fail "timeout_deadline_fast_return" "took ${elapsed}s, expected <=6s (not ~10s)"
  fi

  leaked="$(jobs -p)"
  if [ -z "$leaked" ]; then
    ok "timeout_no_leak_after_deadline"
  else
    fail "timeout_no_leak_after_deadline" "leaked jobs: $leaked"
  fi

  # grandchild reaping: child backgrounds a sleep 30, writes its pid, then
  # waits on it; the whole group must die when the 2s deadline fires.
  local marker gpid
  marker="$grp/grandchild.pid"
  # shellcheck disable=SC2016 # single-quoted intentionally: $! and $1 must
  # expand inside the spawned bash -c, not in this outer shell.
  relay_timeout 2 bash -c 'sleep 30 & echo $! > "$1"; wait' _ "$marker"

  if [ -s "$marker" ]; then
    gpid="$(cat "$marker")"
    if is_numeric "$gpid" && kill -0 "$gpid" 2>/dev/null; then
      fail "timeout_grandchild_killed" "grandchild pid $gpid still alive after deadline"
    else
      ok "timeout_grandchild_killed"
    fi
  else
    fail "timeout_grandchild_killed" "marker file $marker missing or empty"
  fi

  leaked="$(jobs -p)"
  if [ -z "$leaked" ]; then
    ok "timeout_no_leak_after_grandchild"
  else
    fail "timeout_no_leak_after_grandchild" "leaked jobs: $leaked"
  fi

  rm -rf "$grp"
}

# ===========================================================================
# relay_lock / relay_unlock
# ===========================================================================
test_lock() {
  local grp
  grp="$(mktemp -d "${TMPDIR:-/tmp}/relaytest.lock.XXXXXX")"

  local d1="$grp/lock1"
  RELAY_LOCK_HELD=""
  if relay_lock "$d1" 0; then
    ok "lock_acquire"
  else
    fail "lock_acquire" "relay_lock did not acquire a free lock"
  fi

  if relay_lock "$d1" 0; then
    fail "lock_second_fails" "second acquire on a live lock unexpectedly succeeded"
  else
    ok "lock_second_fails"
  fi

  if relay_unlock "$d1"; then
    ok "lock_unlock"
  else
    fail "lock_unlock" "relay_unlock refused to release our own lock"
  fi
  if [ ! -d "$d1" ]; then
    ok "lock_unlock_removed_dir"
  else
    fail "lock_unlock_removed_dir" "lock dir still present after unlock"
  fi

  if relay_lock "$d1" 0; then
    ok "lock_reacquire_after_unlock"
  else
    fail "lock_reacquire_after_unlock" "could not reacquire after clean unlock"
  fi
  relay_unlock "$d1" >/dev/null 2>&1

  # Stale lock on THIS host, owned by a pid we know is dead: spawn a
  # trivial child, wait on it (fully reaped), then use its now-dead pid.
  local d2="$grp/lock2" deadpid
  ( exit 0 ) &
  deadpid="$!"
  wait "$deadpid" 2>/dev/null
  mkdir "$d2"
  printf '%s|100000|%s|\n' "$deadpid" "$(uname -n)" > "$d2/owner"

  if relay_lock "$d2" 0; then
    ok "lock_stale_dead_pid_broken_and_reacquired"
  else
    fail "lock_stale_dead_pid_broken_and_reacquired" "did not break a stale same-host lock owned by dead pid $deadpid"
  fi
  relay_unlock "$d2" >/dev/null 2>&1

  # relay_unlock must never remove a lock owned by a different pid.
  local d3="$grp/lock3"
  mkdir "$d3"
  printf '1|100000|%s|\n' "$(uname -n)" > "$d3/owner"
  RELAY_LOCK_HELD="$d3"
  if relay_unlock; then
    fail "lock_unlock_refuses_other_pid" "unlock succeeded against an owner file for a different pid"
  else
    if [ -d "$d3" ]; then
      ok "lock_unlock_refuses_other_pid"
    else
      fail "lock_unlock_refuses_other_pid" "lock dir was removed despite pid mismatch"
    fi
  fi
  # shellcheck disable=SC2034 # RELAY_LOCK_HELD is a global from the sourced
  # library (relay_unlock's default arg); shellcheck can't see that use
  # because the source is dev/null-stubbed above. This reset prevents state
  # leaking into later test functions.
  RELAY_LOCK_HELD=""

  rm -rf "$grp"
}

# ===========================================================================
# relay_uuid
# ===========================================================================
test_uuid() {
  local u1 u2
  u1="$(relay_uuid)"
  u2="$(relay_uuid)"

  if looks_like_uuid "$u1"; then
    ok "uuid_shape"
  else
    fail "uuid_shape" "got: [$u1]"
  fi

  if [ -n "$u1" ] && [ "$u1" != "$u2" ]; then
    ok "uuid_unique_across_calls"
  else
    fail "uuid_unique_across_calls" "u1=[$u1] u2=[$u2]"
  fi
}

# ===========================================================================
# relay_hash
# ===========================================================================
test_hash() {
  local grp
  grp="$(mktemp -d "${TMPDIR:-/tmp}/relaytest.hash.XXXXXX")"

  local f1="$grp/a.txt" f2="$grp/b.txt" f3="$grp/c.txt"
  printf 'hello relay\n' > "$f1"
  printf 'hello relay\n' > "$f2"
  printf 'goodbye relay\n' > "$f3"

  local h1 h2 h3
  h1="$(relay_hash "$f1")"
  h2="$(relay_hash "$f2")"
  h3="$(relay_hash "$f3")"

  assert_eq "hash_stable_same_content" "$h1" "$h2"

  if [ "$h1" != "$h3" ]; then
    ok "hash_differs_for_different_content"
  else
    fail "hash_differs_for_different_content" "h1=[$h1] h3=[$h3]"
  fi

  if looks_like_hash40 "$h1"; then
    ok "hash_output_shape"
  else
    fail "hash_output_shape" "got: [$h1]"
  fi

  local missing rc
  missing="$(relay_hash "$grp/does-not-exist.txt")"
  rc="$?"
  assert_eq "hash_missing_output" "MISSING" "$missing"
  assert_status "hash_missing_rc" 1 "$rc"

  # Outside any git repo: mktemp's default TMPDIR is not inside relay's
  # working tree, so this exercises the git-hash-object rung without a
  # repository underneath it (git hash-object works standalone).
  if git -C "$grp" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    fail "hash_outside_git_repo_setup" "scratch dir $grp is unexpectedly inside a git work tree"
  else
    local h4
    h4="$(relay_hash "$f1")"
    if looks_like_hash40 "$h4"; then
      ok "hash_outside_git_repo"
    else
      fail "hash_outside_git_repo" "got: [$h4]"
    fi
  fi

  rm -rf "$grp"
}

# ===========================================================================
# relay_atomic_write
# ===========================================================================
test_atomic_write() {
  local grp
  grp="$(mktemp -d "${TMPDIR:-/tmp}/relaytest.atomic.XXXXXX")"

  local dest="$grp/out.txt"
  printf 'first-content' | relay_atomic_write "$dest"
  assert_status "atomic_write_rc" 0 "$?"
  assert_eq "atomic_write_content" "first-content" "$(cat "$dest" 2>/dev/null)"

  # overwrite works too
  printf 'second-content' | relay_atomic_write "$dest"
  assert_status "atomic_write_overwrite_rc" 0 "$?"
  assert_eq "atomic_write_overwrite_content" "second-content" "$(cat "$dest" 2>/dev/null)"

  # parent dirs get created
  local nested="$grp/a/b/c/nested.txt"
  printf 'nested-content' | relay_atomic_write "$nested"
  assert_status "atomic_write_creates_parents_rc" 0 "$?"
  assert_eq "atomic_write_creates_parents_content" "nested-content" "$(cat "$nested" 2>/dev/null)"

  if [ "$(id -u)" = "0" ]; then
    printf 'atomic_write_preserved_on_failure: SKIP (running as root, permissions do not block writes)\n'
  else
    local rodir="$grp/rodir" existing
    mkdir "$rodir"
    existing="$rodir/keep.txt"
    printf 'original' > "$existing"
    chmod 555 "$rodir"

    printf 'attempted-overwrite' | relay_atomic_write "$existing"
    local rc2="$?"

    chmod 755 "$rodir"

    if [ "$rc2" -ne 0 ]; then
      ok "atomic_write_fails_on_readonly_dir"
    else
      fail "atomic_write_fails_on_readonly_dir" "expected non-zero status, got 0"
    fi
    assert_eq "atomic_write_preserved_on_failure" "original" "$(cat "$existing" 2>/dev/null)"
  fi

  rm -rf "$grp"
}

# ===========================================================================
# relay_notify
# ===========================================================================
test_notify() {
  local grp
  grp="$(mktemp -d "${TMPDIR:-/tmp}/relaytest.notify.XXXXXX")"

  RELAY_NOTIFY=0 relay_notify "Title" "Message"
  assert_status "notify_disabled_returns_0" 0 "$?"

  local recorder="$grp/notify-recorder.sh"
  cat > "$recorder" <<'RECORDER_EOF'
#!/usr/bin/env bash
printf '%s\n' "$#" > "$RELAY_TEST_RECORDER_OUT/argc"
i=0
for a in "$@"; do
  i=$((i + 1))
  printf '%s' "$a" > "$RELAY_TEST_RECORDER_OUT/arg$i"
done
exit 0
RECORDER_EOF
  chmod +x "$recorder"

  RELAY_TEST_RECORDER_OUT="$grp"
  export RELAY_TEST_RECORDER_OUT

  RELAY_NOTIFY_CMD="$recorder" relay_notify "Hi" 'bad "; rm -rf / ` x'
  assert_status "notify_custom_cmd_returns_0" 0 "$?"

  local argc
  argc="$(cat "$grp/argc" 2>/dev/null)"
  assert_eq "notify_custom_cmd_argc" "2" "$argc"

  local arg2
  arg2="$(cat "$grp/arg2" 2>/dev/null)"
  if printf '%s' "$arg2" | grep -qF '"' \
     || printf '%s' "$arg2" | grep -qF ';' \
     || printf '%s' "$arg2" | grep -qF '`'; then
    fail "notify_message_sanitized" "dangerous char survived sanitation: [$arg2]"
  else
    ok "notify_message_sanitized"
  fi

  unset RELAY_TEST_RECORDER_OUT
  rm -rf "$grp"
}

# ===========================================================================
# relay_journal
# ===========================================================================
test_journal() {
  local grp
  grp="$(mktemp -d "${TMPDIR:-/tmp}/relaytest.journal.XXXXXX")"

  RELAY_JOURNAL="$grp/journal.log"
  export RELAY_JOURNAL

  relay_journal "test_event" "some detail"
  assert_status "journal_returns_0" 0 "$?"

  if [ -f "$RELAY_JOURNAL" ]; then
    ok "journal_file_created"
  else
    fail "journal_file_created" "no journal file at $RELAY_JOURNAL"
  fi

  local line epoch event detail
  line="$(tail -n 1 "$RELAY_JOURNAL" 2>/dev/null)"
  epoch="$(printf '%s' "$line" | cut -f1)"
  event="$(printf '%s' "$line" | cut -f2)"
  detail="$(printf '%s' "$line" | cut -f3)"

  if is_numeric "$epoch"; then
    ok "journal_epoch_field_numeric"
  else
    fail "journal_epoch_field_numeric" "epoch=[$epoch] line=[$line]"
  fi
  assert_eq "journal_event_field" "test_event" "$event"
  assert_eq "journal_detail_field" "some detail" "$detail"

  unset RELAY_JOURNAL
  rm -rf "$grp"
}

# ===========================================================================
# relay_prune_sessions
# ===========================================================================
test_prune_sessions() {
  local grp keep_old
  grp="$(mktemp -d "${TMPDIR:-/tmp}/relaytest.prune.XXXXXX")"
  mkdir -p "$grp/sessions" "$grp/handoffs"

  # Eight sessions, oldest first so `ls -t` order is unambiguous. Touch with a
  # one-second gap rather than trusting creation order: same-second mtimes make
  # the newest-five assertion a coin flip.
  i=1
  while [ "$i" -le 8 ]; do
    printf 'session %s\n' "$i" > "$grp/sessions/00$i-sid.log"
    printf '' > "$grp/sessions/00$i-sid.log.err"
    sleep 1
    i=$((i + 1))
  done

  # Things pruning must never touch.
  printf 'journal\n'  > "$grp/journal.log"
  printf 'run\n'      > "$grp/RUN.md"
  printf 'state\n'    > "$grp/state.json"
  printf 'handoff\n'  > "$grp/handoffs/001-abc.json"

  relay_prune_sessions "$grp" 5 7
  assert_eq "prune_keeps_five_logs" "5" "$(ls "$grp"/sessions/*.log 2>/dev/null | grep -vc '\.err$')"
  assert_eq "prune_drops_sibling_err" "5" "$(ls "$grp"/sessions/*.log.err 2>/dev/null | wc -l | tr -d ' ')"

  # The five kept are the NEWEST five, not an arbitrary five.
  assert_eq "prune_keeps_newest" "yes" "$([ -f "$grp/sessions/008-sid.log" ] && echo yes || echo no)"
  assert_eq "prune_drops_oldest" "yes" "$([ ! -f "$grp/sessions/001-sid.log" ] && echo yes || echo no)"

  # Everything outside sessions/ survives: journal is the audit trail, handoffs
  # are the hash chain, and RUN.md is re-read by every session.
  assert_eq "prune_spares_journal"  "yes" "$([ -f "$grp/journal.log" ] && echo yes || echo no)"
  assert_eq "prune_spares_runmd"    "yes" "$([ -f "$grp/RUN.md" ] && echo yes || echo no)"
  assert_eq "prune_spares_state"    "yes" "$([ -f "$grp/state.json" ] && echo yes || echo no)"
  assert_eq "prune_spares_handoffs" "yes" "$([ -f "$grp/handoffs/001-abc.json" ] && echo yes || echo no)"

  # Absent sessions/ is not an error: pruning is hygiene, never a gate.
  keep_old="$(mktemp -d "${TMPDIR:-/tmp}/relaytest.prune2.XXXXXX")"
  relay_prune_sessions "$keep_old" 5 7
  assert_eq "prune_no_sessions_dir_ok" "0" "$?"

  # A garbage keep count falls back to the default rather than deleting all.
  mkdir -p "$keep_old/sessions"
  printf 'x\n' > "$keep_old/sessions/001-sid.log"
  relay_prune_sessions "$keep_old" "not-a-number" 7
  assert_eq "prune_bad_keep_is_safe" "yes" "$([ -f "$keep_old/sessions/001-sid.log" ] && echo yes || echo no)"

  rm -rf "$grp" "$keep_old"
}

# ===========================================================================
# main
# ===========================================================================
main() {
  test_timeout
  test_lock
  test_uuid
  test_hash
  test_atomic_write
  test_notify
  test_journal
  test_prune_sessions

  printf '\n--- summary: %d passed, %d failed ---\n' "$PASS_COUNT" "$FAIL_COUNT"
  if [ "$FAIL_COUNT" -ne 0 ]; then
    printf 'failed tests:\n'
    printf '%s' "$FAILED_LIST" | while IFS= read -r name; do
      [ -n "$name" ] && printf '  - %s\n' "$name"
    done
    exit 1
  fi
  exit 0
}

main
