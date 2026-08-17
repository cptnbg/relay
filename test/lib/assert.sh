#!/usr/bin/env bash
# test/lib/assert.sh — assertion helpers sourced by relay test cases
# (test/cases/*.sh, test/hook/*.sh) via test/run.sh.
#
# Every assertion prints expected-vs-actual on failure and calls `exit 1`,
# terminating the calling test file immediately. Since test/run.sh runs each
# test file inside its own isolated subshell, this only ends that one test —
# it does not abort the rest of the suite.
#
# Target: bash 3.2.57. No associative arrays, no mapfile, no ${var^^}.
set -u
LC_ALL=C
export LC_ALL
IFS=$' \t\n'

_assert_fail() {
  printf 'ASSERT FAIL: %s\n' "$1" >&2
  exit 1
}

# assert_eq <expected> <actual> [label]
assert_eq() {
  if [ "$1" != "$2" ]; then
    _assert_fail "${3:-assert_eq}: expected [$1] got [$2]"
  fi
}

# assert_ne <unexpected> <actual> [label]
assert_ne() {
  if [ "$1" = "$2" ]; then
    _assert_fail "${3:-assert_ne}: expected value to differ from [$1], but got the same"
  fi
}

# assert_file <path> [label]
assert_file() {
  [ -f "$1" ] || _assert_fail "${2:-assert_file}: expected file to exist: $1"
}

# assert_no_file <path> [label]
assert_no_file() {
  if [ -f "$1" ]; then
    _assert_fail "${2:-assert_no_file}: expected file NOT to exist: $1"
  fi
  return 0
}

# assert_dir <path> [label]
assert_dir() {
  [ -d "$1" ] || _assert_fail "${2:-assert_dir}: expected directory to exist: $1"
}

# assert_contains <haystack> <needle> [label]  -- substring test via case
assert_contains() {
  case "$1" in
    *"$2"*) : ;;
    *) _assert_fail "${3:-assert_contains}: expected [$1] to contain [$2]" ;;
  esac
}

# assert_grep <file> <pattern> [label]  -- basic regex, `grep -q`
assert_grep() {
  [ -f "$1" ] || _assert_fail "${3:-assert_grep}: file does not exist: $1"
  if ! grep -q -- "$2" "$1" 2>/dev/null; then
    _assert_fail "${3:-assert_grep}: expected pattern [$2] to appear in $1"
  fi
}

# assert_no_grep <file> <pattern> [label]
assert_no_grep() {
  [ -f "$1" ] || _assert_fail "${3:-assert_no_grep}: file does not exist: $1"
  if grep -q -- "$2" "$1" 2>/dev/null; then
    _assert_fail "${3:-assert_no_grep}: expected pattern [$2] NOT to appear in $1"
  fi
}

# assert_json <file> <jq-filter> <expected> [label]
# Compares the raw (-r) output of `jq <filter> <file>` against <expected>.
assert_json() {
  local file="$1" filter="$2" expected="$3" label="${4:-assert_json}" actual
  [ -f "$file" ] || _assert_fail "$label: file does not exist: $file"
  actual="$(jq -r "$filter" "$file" 2>/dev/null)"
  if [ -z "$actual" ] && ! jq -e "$filter" "$file" >/dev/null 2>&1; then
    _assert_fail "$label: jq filter [$filter] failed on $file"
  fi
  if [ "$actual" != "$expected" ]; then
    _assert_fail "$label: jq [$filter] on $file expected [$expected] got [$actual]"
  fi
}

# assert_rc <expected_rc> <actual_rc> [label]
assert_rc() {
  if [ "$1" != "$2" ]; then
    _assert_fail "${3:-assert_rc}: expected exit code [$1] got [$2]"
  fi
}

# assert_between <value> <min> <max> [label]  -- integers only
assert_between() {
  local value="$1" min="$2" max="$3" label="${4:-assert_between}"
  case "$value" in
    ''|*[!0-9]*) _assert_fail "$label: value [$value] is not a non-negative integer" ;;
  esac
  if [ "$value" -lt "$min" ] || [ "$value" -gt "$max" ]; then
    _assert_fail "$label: expected $min <= $value <= $max"
  fi
}

# assert_stdout_json_only <file> [label]
# Proves a captured-stdout file is either empty or contains EXACTLY one
# valid JSON object (used to prove a hook/mock never prints stray output).
assert_stdout_json_only() {
  local file="$1" label="${2:-assert_stdout_json_only}" count
  [ -f "$file" ] || _assert_fail "$label: file does not exist: $file"
  [ -s "$file" ] || return 0
  if ! jq -e . >/dev/null 2>&1 < "$file"; then
    _assert_fail "$label: $file is non-empty but not valid JSON"
  fi
  count="$(jq -s 'length' < "$file" 2>/dev/null)"
  if [ "$count" != "1" ]; then
    _assert_fail "$label: $file expected exactly one JSON value, got count=$count"
  fi
}
