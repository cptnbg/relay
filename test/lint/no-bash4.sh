#!/usr/bin/env bash
# Fail on constructs that need bash 4+. macOS ships bash 3.2.57 and that is the
# floor relay targets, so a bash-4ism is a portability bug that shows up only on
# someone else's machine.
#
# Scans shell CODE only, and ignores comment lines: the files under test
# document these very constructs in their headers, and a linter that cannot
# tell code from prose about code is a linter nobody will keep.
set -u
LC_ALL=C
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FAIL=0

shell_files() {
  find "$ROOT/plugins" "$ROOT/test" -type f \
    \( -name '*.sh' -o -name 'claude' \) 2>/dev/null \
    | grep -v '/test/lint/'
}

scan() { # <ERE> <explanation>
  _hits=$(shell_files | while IFS= read -r f; do
            grep -nE -- "$1" "$f" 2>/dev/null | sed "s|^|$f:|"
          done | grep -vE ':[0-9]+:[[:space:]]*#')
  if [ -n "$_hits" ]; then printf 'BASH4: %s\n%s\n\n' "$2" "$_hits"; FAIL=1; fi
}

scan 'declare -A'                              'associative arrays are bash 4+'
scan 'local -A'                                'associative arrays are bash 4+'
scan '\bmapfile\b'                             'mapfile is bash 4+'
scan '\breadarray\b'                           'readarray is bash 4+'
scan '\$\{[A-Za-z_][A-Za-z0-9_]*\^\^'          '${v^^} is bash 4+'
scan '\$\{[A-Za-z_][A-Za-z0-9_]*,,'            '${v,,} is bash 4+'
scan '\bwait[[:space:]]+-n\b'                  'wait -n is bash 4.3+'
scan '\bcoproc\b'                              'coproc is bash 4+'
scan '&>>'                                     '&>> is bash 4+'
scan ';;&'                                     ';;& case fallthrough is bash 4+'
scan 'shopt[[:space:]]+-s[[:space:]]+globstar' 'globstar is bash 4+'

[ "$FAIL" -eq 0 ] && printf 'no-bash4: clean\n'
exit "$FAIL"
