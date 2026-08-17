#!/usr/bin/env bash
# test/run.sh — zero-API-cost test runner for relay.
#
# Discovers and runs test/cases/*.sh and test/hook/*.sh. Each test runs in a
# fully isolated sandbox: fresh mktemp -d, HOME/CLAUDE_CONFIG_DIR/
# RELAY_MOCK_DIR pointed inside it, PATH prefixed with test/bin so the mock
# `claude` wins, git identity pinned, time-compression knobs exported.
#
# Usage: bash test/run.sh [--filter <substring>] [-v]
#
# Target: bash 3.2.57 (macOS system bash). Deliberately avoids bash arrays
# for the test-file list: bash 3.2's `set -u` throws "unbound variable" on a
# bare "${arr[@]}" expansion for an array built from zero elements (confirmed
# empirically). A newline-accumulated string plus a function-scoped `set --`
# sidesteps the whole class of bug, matching this codebase's own convention
# (see test/lib/test-relay-lib.sh).
set -u
LC_ALL=C
export LC_ALL
IFS=$' \t\n'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export ROOT

PASS_COUNT=0
FAIL_COUNT=0

main() {
  local FILTER="" VERBOSE=0

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --filter)
        if [ "$#" -lt 2 ]; then
          printf 'run.sh: --filter requires a value\n' >&2
          exit 2
        fi
        FILTER="$2"
        shift 2
        ;;
      --filter=*)
        FILTER="${1#*=}"
        shift
        ;;
      -v)
        VERBOSE=1
        shift
        ;;
      *)
        printf 'run.sh: unknown argument: %s\n' "$1" >&2
        exit 2
        ;;
    esac
  done

  # Discover test/cases/*.sh and test/hook/*.sh. Both dirs may not exist yet
  # (nothing to error on) and may be empty (nothing to glob-expand).
  local TESTFILES="__SELFCHECK__
" d f
  for d in "$ROOT/test/cases" "$ROOT/test/hook"; do
    if [ -d "$d" ]; then
      for f in "$d"/*.sh; do
        [ -e "$f" ] || continue
        TESTFILES="${TESTFILES}${f}
"
      done
    fi
  done

  # Repurpose this function's OWN positional parameters (safe: they belong
  # to main(), not to the script) to iterate the newline list without an
  # array. IFS is scoped to just this one word-split.
  local _ifs_save="$IFS" name entry
  IFS='
'
  # shellcheck disable=SC2086 # deliberate word-split of a newline-joined
  # path list into positional params (IFS is scoped to newline-only above);
  # quoting this would pass the whole multi-line string as one argument.
  set -- $TESTFILES
  IFS="$_ifs_save"

  for entry in "$@"; do
    [ -n "$entry" ] || continue
    if [ "$entry" = "__SELFCHECK__" ]; then
      name="selfcheck:mock-wins-on-path"
    else
      case "$entry" in
        "$ROOT"/*) name="${entry#"$ROOT"/}" ;;
        *)         name="$entry" ;;
      esac
    fi
    if [ -n "$FILTER" ]; then
      case "$name" in
        *"$FILTER"*) : ;;
        *) continue ;;
      esac
    fi
    run_one "$name" "$entry" "$VERBOSE"
  done

  printf '\n%d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"
  if [ "$FAIL_COUNT" -ne 0 ]; then
    exit 1
  fi
  exit 0
}

# run_one <display-name> <entry-path-or-__SELFCHECK__> <verbose 0|1>
run_one() {
  local name="$1" entry="$2" verbose="$3" sandbox outfile rc

  sandbox="$(mktemp -d "${TMPDIR:-/tmp}/relay-test.XXXXXX" 2>/dev/null)"
  if [ -z "$sandbox" ] || [ ! -d "$sandbox" ]; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf 'FAIL %s\n' "$name"
    printf '    could not create sandbox via mktemp -d\n'
    return 0
  fi
  outfile="$sandbox/.test-output.log"

  (
    set -u
    LC_ALL=C
    export LC_ALL
    IFS=$' \t\n'

    HOME="$sandbox/home"
    CLAUDE_CONFIG_DIR="$HOME/.claude"
    RELAY_MOCK_DIR="$sandbox/relay-mock"
    mkdir -p "$HOME" "$CLAUDE_CONFIG_DIR" "$RELAY_MOCK_DIR"
    export HOME CLAUDE_CONFIG_DIR RELAY_MOCK_DIR

    PATH="$ROOT/test/bin:$PATH"
    export PATH

    GIT_AUTHOR_NAME=mock; GIT_AUTHOR_EMAIL=mock@example.com
    GIT_COMMITTER_NAME=mock; GIT_COMMITTER_EMAIL=mock@example.com
    GIT_CONFIG_NOSYSTEM=1
    export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_CONFIG_NOSYSTEM

    RELAY_POLL_INTERVAL=1
    RELAY_KILL_GRACE=2
    RELAY_BACKOFF_BASE=1
    RELAY_SESSION_TIMEOUT=5
    RELAY_MIN_SESSION_SECS=0
    export RELAY_POLL_INTERVAL RELAY_KILL_GRACE RELAY_BACKOFF_BASE RELAY_SESSION_TIMEOUT RELAY_MIN_SESSION_SECS

    export ROOT

    cd "$sandbox" || exit 1

    # shellcheck source=/dev/null
    . "$ROOT/test/lib/assert.sh"
    # shellcheck source=/dev/null
    . "$ROOT/test/lib/fixtures.sh"

    if [ "$entry" = "__SELFCHECK__" ]; then
      resolved="$(command -v claude 2>/dev/null || true)"
      expected="$ROOT/test/bin/claude"
      if [ "$resolved" = "$expected" ]; then
        exit 0
      fi
      printf 'self-check: command -v claude resolved to [%s], expected [%s]\n' \
        "$resolved" "$expected" >&2
      exit 1
    fi

    # shellcheck source=/dev/null
    . "$entry"
  ) > "$outfile" 2>&1
  rc=$?

  if [ "$rc" -eq 0 ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    printf 'ok %s\n' "$name"
    if [ "$verbose" -eq 1 ] && [ -s "$outfile" ]; then
      sed 's/^/    /' "$outfile"
    fi
    if [ "${RELAY_TEST_KEEP:-0}" = "1" ]; then
      printf '    (sandbox kept at %s)\n' "$sandbox"
    else
      rm -rf "$sandbox"
    fi
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf 'FAIL %s\n' "$name"
    printf '    --- output ---\n'
    sed 's/^/    /' "$outfile"
    printf '    --- sandbox kept at: %s ---\n' "$sandbox"

    local jf sf af
    jf="$(find "$sandbox" -maxdepth 6 -iname 'journal*' -type f 2>/dev/null | head -1)"
    if [ -n "$jf" ]; then
      printf '    --- journal tail (%s) ---\n' "$jf"
      tail -n 40 "$jf" | sed 's/^/    /'
    fi
    sf="$(find "$sandbox" -maxdepth 6 -iname 'state.json' -type f 2>/dev/null | head -1)"
    if [ -n "$sf" ]; then
      printf '    --- state.json (%s) ---\n' "$sf"
      sed 's/^/    /' "$sf"
    fi
    af="$sandbox/relay-mock/actions"
    if [ -f "$af" ]; then
      printf '    --- mock actions (%s) ---\n' "$af"
      sed 's/^/    /' "$af"
    fi
  fi
  return 0
}

main "$@"
