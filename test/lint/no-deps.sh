#!/usr/bin/env bash
# Fail on dependencies relay promises not to need. The README tells users node,
# python and coreutils are not required; this keeps that promise honest.
#
# Scans SHIPPED shell code only. Tests may use extra tools to set up a scenario,
# and documentation may name a tool in order to explain why it is avoided.
set -u
LC_ALL=C
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FAIL=0

shell_files() {
  find "$ROOT/plugins" -type f -name '*.sh' 2>/dev/null
}

scan() { # <ERE> <explanation>
  _hits=$(shell_files | while IFS= read -r f; do
            grep -nE -- "$1" "$f" 2>/dev/null | sed "s|^|$f:|"
          done | grep -vE ':[0-9]+:[[:space:]]*#')
  if [ -n "$_hits" ]; then printf 'FORBIDDEN DEP: %s\n%s\n\n' "$2" "$_hits"; FAIL=1; fi
}

scan '(^|[^[:alnum:]_./-])timeout[[:space:]]+[0-9$]' 'timeout(1) is absent on stock macOS; use relay_timeout'
scan '(^|[^[:alnum:]_./-])gtimeout\b'                'gtimeout needs Homebrew coreutils'
scan '(^|[^[:alnum:]_./-])flock\b'                   'flock does not exist on macOS; use relay_lock'
scan '(^|[^[:alnum:]_./-])setsid\b'                  'setsid does not exist on macOS; use set -m'
scan '(^|[^[:alnum:]_./-])stat[[:space:]]+-[cf]'     'stat flags differ between macOS and Linux'
scan '(^|[^[:alnum:]_./-])realpath\b'                'realpath is not on stock macOS'
scan 'readlink[[:space:]]+-f'                        'readlink -f is not on stock macOS'
scan '(^|[^[:alnum:]_./-])sha256sum\b'               'not on macOS; use relay_hash'
scan '(^|[^[:alnum:]_./-])python3?[[:space:]]'       'relay must not require python'
scan '(^|[^[:alnum:]_./-])node[[:space:]]'           'relay must not require node'
scan 'grep[[:space:]]+-[A-Za-z]*P[[:space:]]'        'grep -P is unavailable on macOS'
scan 'sed[[:space:]]+-i[[:space:]]'                  'sed -i differs between BSD and GNU'
scan 'date[[:space:]]+-d[[:space:]]'                 'date -d is GNU-only'
scan 'date[[:space:]]+\+%s%N'                        'nanosecond date is GNU-only'

[ "$FAIL" -eq 0 ] && printf 'no-deps: clean\n'
exit "$FAIL"
