#!/usr/bin/env bash
# relay-lib.sh — portable bash library for the relay project.
#
# Target: bash 3.2.57 (macOS system bash). No associative arrays, no mapfile,
# no ${var^^}/${var,,}, no globstar, no `wait -n`, no coproc.
# No `timeout`, `flock`, `setsid`, `stat`, `realpath`, `readlink -f`.
# Allowed externals: bash builtins, git, jq, POSIX utils (awk sed grep tail
# head wc tr od mkdir mv rm rmdir date sleep kill ps mktemp printf cut df
# uname cksum), plus explicit fallback rungs for shasum/sha256sum.
#
# Deliberately NOT `set -e`: every function returns an explicit status and is
# called from if/&&/while, where `set -e` is inert inside functions in
# bash 3.2 anyway.
set -u
set -o pipefail
umask 077
LC_ALL=C
export LC_ALL
IFS=$' \t\n'

# --- bash version gate --------------------------------------------------
if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 3 ]; then
  printf 'relay-lib.sh: requires bash >= 3, got: %s\n' "${BASH_VERSION:-unknown}" >&2
  exit 78
fi

# --- module globals -------------------------------------------------------
# Reachable by trap/signal handlers (relay_install_traps) so a TERM/INT can
# tear down the currently-running child and lock without extra plumbing.
RELAY_CHILD_PGID=""
RELAY_WATCH_PID=""
RELAY_LOCK_HELD=""
RELAY_SHUTTING_DOWN=0
export RELAY_CHILD_PGID RELAY_WATCH_PID

RELAY_KILL_GRACE="${RELAY_KILL_GRACE:-10}"
RELAY_LOCK_STALE_SECS="${RELAY_LOCK_STALE_SECS:-900}"

# ===========================================================================
# relay_journal <event> [detail]
# Append one tab-separated line to ${RELAY_JOURNAL:-/dev/null}. Always 0.
# ===========================================================================
relay_journal() {
  _rl_event="${1:-}"
  _rl_detail="${2:-}"
  _rl_epoch="$(date +%s 2>/dev/null || printf '0')"
  printf '%s\t%s\t%s\n' "$_rl_epoch" "$_rl_event" "$_rl_detail" >> "${RELAY_JOURNAL:-/dev/null}" 2>/dev/null
  unset _rl_event _rl_detail _rl_epoch
  return 0
}

# ===========================================================================
# relay_warn <msg>
# Print to stderr, journal. Always 0.
# ===========================================================================
relay_warn() {
  _rl_msg="${1:-}"
  printf 'relay: WARN: %s\n' "$_rl_msg" >&2
  relay_journal "warn" "$_rl_msg"
  unset _rl_msg
  return 0
}

# ===========================================================================
# relay_die <exit_code> <msg>
# Journal, unlock, kill any tracked child pgid, print to stderr, exit.
# ===========================================================================
relay_die() {
  _rl_code="${1:-1}"
  shift 2>/dev/null || true
  _rl_msg="${1:-}"
  relay_journal "die" "$_rl_msg"
  relay_unlock 2>/dev/null || true
  if [ -n "${RELAY_CHILD_PGID:-}" ]; then
    kill -TERM "-$RELAY_CHILD_PGID" 2>/dev/null || kill -TERM "$RELAY_CHILD_PGID" 2>/dev/null || true
  fi
  printf 'relay: FATAL: %s\n' "$_rl_msg" >&2
  exit "$_rl_code"
}

# ===========================================================================
# relay_reap_pgroup <pgid>
# Kill any pid whose pgid matches but which is not the group leader itself.
# Always returns 0.
# ===========================================================================
relay_reap_pgroup() {
  _rl_pgid="${1:-}"
  if [ -z "$_rl_pgid" ]; then
    return 0
  fi
  # ps columns: pid pgid (both right-justified with leading spaces on macOS
  # and Linux); awk splits on whitespace regardless.
  _rl_victims="$(ps -eo pid=,pgid= 2>/dev/null | awk -v pgid="$_rl_pgid" '{
    p=$1; g=$2;
    if (g == pgid && p != pgid) print p;
  }')"
  if [ -n "$_rl_victims" ]; then
    # shellcheck disable=SC2086 # _rl_victims is a deliberate word-split pid list, not user text
    kill -KILL $_rl_victims 2>/dev/null || true
  fi
  unset _rl_pgid _rl_victims
  return 0
}

# ===========================================================================
# relay_timeout <seconds> <cmd> [args...]
# Run a command with a deadline, without the `timeout` binary.
# Returns: child's own status; 124 if TERM-killed on deadline; 137 if the
# child ignored TERM and had to be KILLed.
# ===========================================================================
relay_timeout() {
  _rt_secs="${1:-}"
  shift 2>/dev/null || true
  if [ -z "${1:-}" ]; then
    printf 'relay_timeout: usage: relay_timeout <seconds> <cmd> [args...]\n' >&2
    return 2
  fi
  case "$_rt_secs" in
    ''|*[!0-9]*) printf 'relay_timeout: seconds must be a non-negative integer: %s\n' "$_rt_secs" >&2; return 2 ;;
  esac

  _rt_tmp="$(mktemp -d "${TMPDIR:-/tmp}/relay-timeout.XXXXXX" 2>/dev/null)"
  if [ -z "$_rt_tmp" ] || [ ! -d "$_rt_tmp" ]; then
    printf 'relay_timeout: mktemp -d failed\n' >&2
    return 2
  fi
  _rt_fired="$_rt_tmp/fired"
  _rt_killed="$_rt_tmp/killed"
  _rt_timer_pid=""
  _rt_child_pid=""
  _rt_child_pgid=""
  _rt_status=0

  # Background the child in its own process group (job control), so we can
  # signal the whole tree via `kill -TERM "-$pgid"` without setsid.
  set -m
  ( exec "$@" ) &
  _rt_child_pid="$!"
  set +m

  _rt_child_pgid="$_rt_child_pid"
  RELAY_CHILD_PGID="$_rt_child_pgid"
  export RELAY_CHILD_PGID

  # Sibling timer subprocess: sleeps in 1s increments (keeps its own TERM
  # trap responsive rather than blocking in one long sleep), then escalates
  # TERM -> grace -> KILL against the process group. Communicates back via
  # flag files since it's a subshell and cannot set parent variables.
  (
    trap 'exit 0' TERM
    _remaining="$_rt_secs"
    while [ "$_remaining" -gt 0 ]; do
      sleep 1
      _remaining=$((_remaining - 1))
    done
    : > "$_rt_fired"
    if ! kill -TERM "-$_rt_child_pgid" 2>/dev/null; then
      kill -TERM "$_rt_child_pgid" 2>/dev/null || true
    fi
    _grace="${RELAY_KILL_GRACE:-10}"
    _g=0
    while [ "$_g" -lt "$_grace" ]; do
      sleep 1
      if ! kill -0 "$_rt_child_pgid" 2>/dev/null; then
        exit 0
      fi
      _g=$((_g + 1))
    done
    if kill -0 "$_rt_child_pgid" 2>/dev/null; then
      : > "$_rt_killed"
      kill -KILL "-$_rt_child_pgid" 2>/dev/null || kill -KILL "$_rt_child_pgid" 2>/dev/null || true
    fi
  ) &
  _rt_timer_pid="$!"
  RELAY_WATCH_PID="$_rt_timer_pid"
  export RELAY_WATCH_PID

  # `wait` is the only correct reaper: unlike a `kill -0` poll loop, it
  # cannot be fooled by a zombie that hasn't been reaped yet, and it is
  # interruptible by trapped signals.
  wait "$_rt_child_pid" 2>/dev/null
  _rt_status="$?"

  # Stop the timer (it may already have exited) and reap it so no
  # background job leaks back to the caller's shell.
  kill -TERM "$_rt_timer_pid" 2>/dev/null || true
  wait "$_rt_timer_pid" 2>/dev/null

  relay_reap_pgroup "$_rt_child_pgid"

  if [ -f "$_rt_killed" ]; then
    _rt_status=137
  elif [ -f "$_rt_fired" ]; then
    _rt_status=124
  fi

  rm -rf "$_rt_tmp" 2>/dev/null

  RELAY_CHILD_PGID=""
  RELAY_WATCH_PID=""
  export RELAY_CHILD_PGID RELAY_WATCH_PID

  unset _rt_secs _rt_tmp _rt_fired _rt_killed _rt_timer_pid _rt_child_pid _rt_child_pgid
  return "$_rt_status"
}

# ===========================================================================
# relay_lock <lockdir> [wait_seconds]
# Acquire an atomic mkdir-based lock. Sets RELAY_LOCK_HELD to lockdir on
# success. Returns 0 on success, 1 on failure/timeout.
# ===========================================================================
relay_lock() {
  _rlk_dir="${1:-}"
  _rlk_wait="${2:-0}"
  if [ -z "$_rlk_dir" ]; then
    printf 'relay_lock: usage: relay_lock <lockdir> [wait_seconds]\n' >&2
    return 2
  fi
  case "$_rlk_wait" in
    ''|*[!0-9]*) _rlk_wait=0 ;;
  esac

  _rlk_deadline_iters="$_rlk_wait"
  _rlk_elapsed=0

  while :; do
    if mkdir "$_rlk_dir" 2>/dev/null; then
      _rlk_now="$(date +%s 2>/dev/null || printf '0')"
      _rlk_host="$(uname -n 2>/dev/null || printf 'unknown-host')"
      if printf '%s|%s|%s|%s\n' "$$" "$_rlk_now" "$_rlk_host" "${RELAY_RUN_ID:-}" > "$_rlk_dir/owner" 2>/dev/null; then
        RELAY_LOCK_HELD="$_rlk_dir"
        unset _rlk_dir _rlk_wait _rlk_deadline_iters _rlk_elapsed _rlk_now _rlk_host
        return 0
      fi
      rmdir "$_rlk_dir" 2>/dev/null
      return 1
    fi

    if [ -d "$_rlk_dir" ] && _relay_lock_try_break "$_rlk_dir"; then
      # Breaking succeeded; loop back around and try mkdir again immediately.
      continue
    fi

    if [ "$_rlk_elapsed" -ge "$_rlk_deadline_iters" ]; then
      unset _rlk_dir _rlk_wait _rlk_deadline_iters _rlk_elapsed
      return 1
    fi
    sleep 1
    _rlk_elapsed=$((_rlk_elapsed + 1))
  done
}

# Internal: attempt to break a stale lock. Returns 0 if it broke the lock
# (caller should retry mkdir), 1 otherwise (lock is live or breaking failed).
_relay_lock_try_break() {
  _rlb_dir="${1:?}"
  _rlb_owner="$_rlb_dir/owner"
  _rlb_stale=0

  if [ ! -f "$_rlb_owner" ]; then
    _rlb_stale=1
  else
    _rlb_line="$(head -n 1 -- "$_rlb_owner" 2>/dev/null)"
    _rlb_pid="$(printf '%s' "$_rlb_line" | cut -d'|' -f1)"
    _rlb_epoch="$(printf '%s' "$_rlb_line" | cut -d'|' -f2)"
    _rlb_host="$(printf '%s' "$_rlb_line" | cut -d'|' -f3)"

    case "$_rlb_pid" in
      ''|*[!0-9]*) _rlb_stale=1 ;;
    esac
    case "$_rlb_epoch" in
      ''|*[!0-9]*) _rlb_stale=1 ;;
    esac

    if [ "$_rlb_stale" -eq 0 ]; then
      _rlb_here="$(uname -n 2>/dev/null || printf 'unknown-host')"
      if [ "$_rlb_host" = "$_rlb_here" ]; then
        # Same host: pid liveness is authoritative.
        if ! ps -p "$_rlb_pid" >/dev/null 2>&1; then
          _rlb_stale=1
        fi
      else
        # Different host: pid liveness is meaningless. Only break on age.
        _rlb_now="$(date +%s 2>/dev/null || printf '0')"
        _rlb_age=$((_rlb_now - _rlb_epoch))
        if [ "$_rlb_age" -lt 0 ]; then
          _rlb_age=0
        fi
        _rlb_threshold=$((RELAY_LOCK_STALE_SECS * 4))
        if [ "$_rlb_age" -ge "$_rlb_threshold" ]; then
          relay_warn "breaking cross-host lock $_rlb_dir (host=$_rlb_host age=${_rlb_age}s >= ${_rlb_threshold}s)"
          _rlb_stale=1
        fi
      fi
    fi
  fi

  if [ "$_rlb_stale" -ne 1 ]; then
    unset _rlb_dir _rlb_owner _rlb_stale _rlb_line _rlb_pid _rlb_epoch _rlb_host _rlb_here _rlb_now _rlb_age _rlb_threshold
    return 1
  fi

  # Race-safe break: a second mkdir acts as a mutex so two supervisors
  # cannot both destroy the lock concurrently.
  _rlb_breaking="$_rlb_dir.breaking"
  if ! mkdir "$_rlb_breaking" 2>/dev/null; then
    unset _rlb_dir _rlb_owner _rlb_stale _rlb_line _rlb_pid _rlb_epoch _rlb_host _rlb_breaking
    return 1
  fi

  relay_journal "lock_break" "$_rlb_dir"
  rm -rf "$_rlb_dir" 2>/dev/null
  rmdir "$_rlb_breaking" 2>/dev/null
  unset _rlb_dir _rlb_owner _rlb_stale _rlb_line _rlb_pid _rlb_epoch _rlb_host _rlb_breaking
  return 0
}

# ===========================================================================
# relay_unlock [lockdir]
# Never releases a lock owned by a different pid. Defaults to RELAY_LOCK_HELD.
# ===========================================================================
relay_unlock() {
  _rlu_dir="${1:-${RELAY_LOCK_HELD:-}}"
  if [ -z "$_rlu_dir" ] || [ ! -d "$_rlu_dir" ]; then
    return 0
  fi
  if [ ! -f "$_rlu_dir/owner" ]; then
    return 1
  fi
  _rlu_owner_pid="$(cut -d'|' -f1 -- "$_rlu_dir/owner" 2>/dev/null)"
  if [ "$_rlu_owner_pid" != "$$" ]; then
    unset _rlu_dir _rlu_owner_pid
    return 1
  fi
  rm -rf "$_rlu_dir" 2>/dev/null
  if [ "$_rlu_dir" = "${RELAY_LOCK_HELD:-}" ]; then
    RELAY_LOCK_HELD=""
  fi
  unset _rlu_dir _rlu_owner_pid
  return 0
}

# ===========================================================================
# relay_uuid
# Print a lowercase RFC4122-shaped UUID. Ladder: uuidgen -> kernel random ->
# /dev/urandom derivation. Returns 1 if all rungs fail.
# ===========================================================================
relay_uuid() {
  _ru_val=""

  if command -v uuidgen >/dev/null 2>&1; then
    _ru_val="$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    case "$_ru_val" in
      [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
        printf '%s\n' "$_ru_val"
        unset _ru_val
        return 0
        ;;
    esac
  fi

  if [ -r /proc/sys/kernel/random/uuid ]; then
    _ru_val="$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    case "$_ru_val" in
      [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
        printf '%s\n' "$_ru_val"
        unset _ru_val
        return 0
        ;;
    esac
  fi

  if [ -r /dev/urandom ]; then
    _ru_hex="$(od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n')"
    if [ "${#_ru_hex}" -eq 32 ]; then
      _ru_a="${_ru_hex:0:8}"
      _ru_b="${_ru_hex:8:4}"
      _ru_c="${_ru_hex:12:4}"
      _ru_d="${_ru_hex:16:4}"
      _ru_e="${_ru_hex:20:12}"
      # Force version 4 (nibble 0 of the 3rd group) and variant a (nibble 0
      # of the 4th group, RFC4122 "10xx" family -> 8/9/a/b; we pin to 'a').
      _ru_c="4${_ru_c#?}"
      _ru_d="a${_ru_d#?}"
      _ru_val="${_ru_a}-${_ru_b}-${_ru_c}-${_ru_d}-${_ru_e}"
      case "$_ru_val" in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
          printf '%s\n' "$_ru_val"
          unset _ru_hex _ru_a _ru_b _ru_c _ru_d _ru_e _ru_val
          return 0
          ;;
      esac
    fi
    unset _ru_hex _ru_a _ru_b _ru_c _ru_d _ru_e
  fi

  unset _ru_val
  printf 'relay_uuid: all rungs failed\n' >&2
  return 1
}

# ===========================================================================
# relay_hash <file>
# Content hash ladder: git hash-object -> shasum -a 256 -> cksum (weak,
# prefixed cksum:). Prints MISSING (status 1) if the file does not exist,
# UNKNOWN (status 1) if every rung fails.
# ===========================================================================
relay_hash() {
  _rh_file="${1:-}"
  if [ -z "$_rh_file" ] || [ ! -f "$_rh_file" ]; then
    printf 'MISSING\n'
    return 1
  fi

  if command -v git >/dev/null 2>&1; then
    # git hash-object's exit status is not trustworthy on its own (it can
    # print `fatal:` to stderr yet still exit 0 in some configurations, or
    # vice versa depending on repo state) — validate the captured stdout
    # shape instead of trusting $?.
    _rh_out="$(git hash-object -- "$_rh_file" 2>/dev/null)"
    case "$_rh_out" in
      [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
        printf '%s\n' "$_rh_out"
        unset _rh_file _rh_out
        return 0
        ;;
    esac
    unset _rh_out
  fi

  if command -v shasum >/dev/null 2>&1; then
    _rh_out="$(shasum -a 256 -- "$_rh_file" 2>/dev/null | awk '{print $1}')"
    case "$_rh_out" in
      [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
        printf '%s\n' "$_rh_out"
        unset _rh_file _rh_out
        return 0
        ;;
    esac
    unset _rh_out
  fi

  if command -v cksum >/dev/null 2>&1; then
    _rh_out="$(cksum -- "$_rh_file" 2>/dev/null | awk '{print $1"-"$2}')"
    if [ -n "$_rh_out" ]; then
      printf 'cksum:%s\n' "$_rh_out"
      unset _rh_file _rh_out
      return 0
    fi
    unset _rh_out
  fi

  unset _rh_file
  printf 'UNKNOWN\n'
  return 1
}

# ===========================================================================
# relay_atomic_write <dest>
# Read stdin, write atomically via same-directory temp + mv. Creates parent
# dirs. On any failure, removes the temp and returns 1, leaving dest intact.
# ===========================================================================
relay_atomic_write() {
  _raw_dest="${1:-}"
  if [ -z "$_raw_dest" ]; then
    printf 'relay_atomic_write: usage: relay_atomic_write <dest>\n' >&2
    return 1
  fi

  _raw_dir="${_raw_dest%/*}"
  if [ "$_raw_dir" = "$_raw_dest" ]; then
    _raw_dir="."
  fi

  if [ ! -d "$_raw_dir" ]; then
    if ! mkdir -p -- "$_raw_dir" 2>/dev/null; then
      unset _raw_dest _raw_dir
      return 1
    fi
  fi

  _raw_base="${_raw_dest##*/}"
  _raw_tmp="$(mktemp "$_raw_dir/.${_raw_base}.XXXXXX" 2>/dev/null)"
  if [ -z "$_raw_tmp" ] || [ ! -f "$_raw_tmp" ]; then
    unset _raw_dest _raw_dir _raw_base _raw_tmp
    return 1
  fi

  if ! cat > "$_raw_tmp" 2>/dev/null; then
    rm -f -- "$_raw_tmp" 2>/dev/null
    unset _raw_dest _raw_dir _raw_base _raw_tmp
    return 1
  fi

  if ! mv -f -- "$_raw_tmp" "$_raw_dest" 2>/dev/null; then
    rm -f -- "$_raw_tmp" 2>/dev/null
    unset _raw_dest _raw_dir _raw_base _raw_tmp
    return 1
  fi

  unset _raw_dest _raw_dir _raw_base _raw_tmp
  return 0
}

# ===========================================================================
# relay_notify <title> <message>
# Never fails (always returns 0). Never blocks more than 5s per attempt.
# Sanitizes both args before use (repo text is untrusted input).
# ===========================================================================
relay_notify() {
  if [ "${RELAY_NOTIFY:-1}" = "0" ]; then
    return 0
  fi

  # NOTE: semicolon deliberately excluded from the allowed set even though
  # argv-only invocation (never eval/sh -c) makes it inert here — belt and
  # braces against any future rung that shells out, and matches the "no
  # semicolon" security assertion this function must satisfy.
  _rn_title="$(printf '%s' "${1:-}" | tr -cd 'A-Za-z0-9 .,:/_()@#%+-')"
  _rn_msg="$(printf '%s' "${2:-}" | tr -cd 'A-Za-z0-9 .,:/_()@#%+-')"
  _rn_title="$(printf '%s' "$_rn_title" | cut -c1-80)"
  _rn_msg="$(printf '%s' "$_rn_msg" | cut -c1-200)"

  if [ -n "${RELAY_NOTIFY_CMD:-}" ] && command -v "${RELAY_NOTIFY_CMD}" >/dev/null 2>&1; then
    if relay_timeout 5 "$RELAY_NOTIFY_CMD" "$_rn_title" "$_rn_msg" 2>/dev/null; then
      unset _rn_title _rn_msg
      return 0
    fi
  fi

  if command -v terminal-notifier >/dev/null 2>&1; then
    if relay_timeout 5 terminal-notifier -title "$_rn_title" -message "$_rn_msg" >/dev/null 2>&1; then
      unset _rn_title _rn_msg
      return 0
    fi
  fi

  if command -v osascript >/dev/null 2>&1; then
    # argv-only: title/message are passed as `-e` script text built from
    # already-sanitized (alnum + a narrow punctuation set only) strings, so
    # there is no quote/backtick/metacharacter left to break out with.
    _rn_script="display notification \"$_rn_msg\" with title \"$_rn_title\""
    if relay_timeout 5 osascript -e "$_rn_script" >/dev/null 2>&1; then
      unset _rn_title _rn_msg _rn_script
      return 0
    fi
    unset _rn_script
  fi

  if command -v notify-send >/dev/null 2>&1; then
    if relay_timeout 5 notify-send -- "$_rn_title" "$_rn_msg" >/dev/null 2>&1; then
      unset _rn_title _rn_msg
      return 0
    fi
  fi

  unset _rn_title _rn_msg
  return 0
}

# ===========================================================================
# relay_install_traps
# Idempotent INT/TERM/HUP handlers: kill timer + child pgroup with a
# TERM -> grace -> KILL escalation, reap, unlock, exit with the conventional
# code. Also installs an EXIT trap that only cleans up if signals didn't.
# ===========================================================================
_relay_signal_cleanup() {
  _rsc_code="${1:-1}"
  if [ "$RELAY_SHUTTING_DOWN" = "1" ]; then
    return 0
  fi
  RELAY_SHUTTING_DOWN=1

  relay_journal "signal_cleanup" "code=$_rsc_code"

  if [ -n "${RELAY_WATCH_PID:-}" ]; then
    kill -TERM "$RELAY_WATCH_PID" 2>/dev/null || true
  fi

  if [ -n "${RELAY_CHILD_PGID:-}" ]; then
    if ! kill -TERM "-$RELAY_CHILD_PGID" 2>/dev/null; then
      kill -TERM "$RELAY_CHILD_PGID" 2>/dev/null || true
    fi
    _rsc_grace="${RELAY_KILL_GRACE:-10}"
    _rsc_g=0
    while [ "$_rsc_g" -lt "$_rsc_grace" ]; do
      if ! kill -0 "$RELAY_CHILD_PGID" 2>/dev/null; then
        break
      fi
      sleep 1
      _rsc_g=$((_rsc_g + 1))
    done
    if kill -0 "$RELAY_CHILD_PGID" 2>/dev/null; then
      kill -KILL "-$RELAY_CHILD_PGID" 2>/dev/null || kill -KILL "$RELAY_CHILD_PGID" 2>/dev/null || true
    fi
    relay_reap_pgroup "$RELAY_CHILD_PGID"
    unset _rsc_grace _rsc_g
  fi

  relay_unlock 2>/dev/null || true
  unset _rsc_code
}

_relay_trap_int() {
  _relay_signal_cleanup 130
  trap - INT
  kill -INT "$$" 2>/dev/null || exit 130
}

_relay_trap_term() {
  _relay_signal_cleanup 143
  trap - TERM
  kill -TERM "$$" 2>/dev/null || exit 143
}

_relay_trap_hup() {
  _relay_signal_cleanup 129
  trap - HUP
  kill -HUP "$$" 2>/dev/null || exit 129
}

_relay_trap_exit() {
  # Capture $? immediately: it is the script's real exit status only until
  # the very next command runs. The `if` test below would otherwise
  # overwrite it before _relay_signal_cleanup ever sees it (shellcheck SC2319
  # caught this — it was a real bug, not a false positive).
  _rte_status="$?"
  if [ "$RELAY_SHUTTING_DOWN" != "1" ]; then
    _relay_signal_cleanup "$_rte_status"
  fi
  unset _rte_status
}

relay_install_traps() {
  trap '_relay_trap_int' INT
  trap '_relay_trap_term' TERM
  trap '_relay_trap_hup' HUP
  trap '_relay_trap_exit' EXIT
  return 0
}
