#!/usr/bin/env bash
# test/publish-check.sh — the acceptance gate for docs/phase5-publish-plan.md.
#
# Makes no API calls. Checks that the publish-prep deliverables exist with real
# content, that the README's honest-limitations section still precedes the
# install instructions, and that both plugin manifests still validate.
#
# A word on the length thresholds below: they are not a quality bar and cannot
# be. They exist so that an empty stub cannot pass a gate whose whole purpose is
# to say "this was written". Whether a document is any good is settled by
# reading it, which is why the plan's acceptance criteria say so explicitly.
set -u
LC_ALL=C
IFS=$' \t\n'

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 1

FAIL=0
ok()   { printf 'ok    %s\n' "$1"; }
bad()  { printf 'FAIL  %s\n' "$1"; FAIL=1; }

# need <path> <min-lines> <must-contain-ERE>
need() {
  if [ ! -f "$1" ]; then bad "$1 is missing"; return; fi
  _n=$(grep -c '' "$1" 2>/dev/null)
  if [ "${_n:-0}" -lt "$2" ]; then bad "$1 has $_n lines, expected at least $2"; return; fi
  if [ -n "${3:-}" ] && ! grep -qE "$3" "$1"; then
    bad "$1 never mentions ${3}"; return
  fi
  ok "$1 ($_n lines)"
}

need docs/architecture.md   80 'exit code'
need docs/exit-codes.md     30 '\b78\b'
need docs/portability.md    50 'bash 3\.2'
need docs/troubleshooting.md 60 'sandbox'
need CONTRIBUTING.md        30 'second maintainer'
need RELEASING.md           30 'sha256'

# Every EX_* code the supervisor can return must be documented. A table that
# silently lags the source is worse than no table.
for _c in $(grep -oE '\bEX_[A-Z]+=[0-9]+' plugins/relay/scripts/relay-supervisor.sh \
            | cut -d= -f2 | sort -un); do
  if grep -qE "(^|[^0-9])$_c([^0-9]|$)" docs/exit-codes.md 2>/dev/null; then
    ok "exit code $_c documented"
  else
    bad "exit code $_c is in the supervisor but not in docs/exit-codes.md"
  fi
done

# The limitations section is a security control, so its POSITION is part of it.
_lim=$(grep -n 'Read this before you run it' README.md | head -1 | cut -d: -f1)
_ins=$(grep -n '^## Install' README.md | head -1 | cut -d: -f1)
if [ -n "$_lim" ] && [ -n "$_ins" ] && [ "$_lim" -lt "$_ins" ]; then
  ok "README limitations precede install"
else
  bad "README limitations must appear above the install instructions"
fi

# Deliberately NOT checked here: whether the run modified an executable file.
# The only honest comparison is against the commit the run started from, which
# this script does not know, and comparing against the root commit just reports
# the whole project history as a violation. The guardrail is stated in the plan
# and verified by reading `git log` for the run.

# The validate gate needs the claude CLI, which CI does not have. Guarded so
# every pure-shell gate above and below still runs there; locally (and in the
# release checklist), claude exists and this gate exercises fully.
if command -v claude >/dev/null 2>&1; then
  if claude plugin validate --strict .claude-plugin/marketplace.json >/dev/null 2>&1 \
     && claude plugin validate --strict plugins/relay/.claude-plugin/plugin.json >/dev/null 2>&1; then
    ok "both manifests pass claude plugin validate --strict"
  else
    bad "a plugin manifest failed claude plugin validate --strict"
  fi
else
  printf 'skip  claude CLI not on PATH; plugin validate not run (all other gates still apply)\n'
fi

# ---------------------------------------------------------------------------
# Exit-code line citations. docs/exit-codes.md cites supervisor call sites as
# "**Line NNN**" bullets (and, in the EX_PREFLIGHT section, as table rows).
# The number-presence gate above cannot see citation rot, so each cited line
# is checked against the supervisor: it must exist and actually mention the
# section's EX_ constant or a literal `exit <code>`.
# ---------------------------------------------------------------------------
_sup=plugins/relay/scripts/relay-supervisor.sh
_doc=docs/exit-codes.md
_sup_len=$(grep -c '' "$_sup" 2>/dev/null)

_citations=$(awk '
  /^## /  {
    ex = ""; code = ""
    if (match($0, /EX_[A-Z]+/)) {
      ex = substr($0, RSTART, RLENGTH)
      if (match($0, /[0-9]+/)) code = substr($0, RSTART, RLENGTH)
    }
    next
  }
  ex == "" { next }
  {
    line = $0
    while (match(line, /\*\*Lines? [0-9]+/)) {
      cite = substr(line, RSTART, RLENGTH)
      gsub(/[^0-9]/, "", cite)
      print code, ex, cite
      line = substr(line, RSTART + RLENGTH)
    }
  }
  /^\|[[:space:]]*[0-9]+[[:space:]]*\|/ {
    row = $0
    sub(/^\|[[:space:]]*/, "", row)
    sub(/[^0-9].*/, "", row)
    if (row != "") print code, ex, row
  }
' "$_doc" 2>/dev/null)

if [ -z "$_citations" ]; then
  bad "docs/exit-codes.md contains no '**Line NNN**' call-site citations to verify"
else
  _rot=0
  _seen=0
  while read -r _code _ex _n; do
    [ -n "$_n" ] || continue
    _seen=$((_seen + 1))
    if [ "$_n" -gt "${_sup_len:-0}" ] 2>/dev/null; then
      bad "exit-codes.md cites $_ex at line $_n, past the end of the supervisor (${_sup_len} lines)"
      _rot=1
      continue
    fi
    _text=$(sed -n "${_n}p" "$_sup")
    case "$_text" in
      *"\$$_ex"*|*"exit $_code"*) : ;;
      *)
        bad "exit-codes.md cites $_ex ($_code) at supervisor line $_n, but that line is: $(printf '%s' "$_text" | head -c 100)"
        _rot=1
        ;;
    esac
  done <<CITATIONS
$_citations
CITATIONS
  if [ "$_rot" -eq 0 ]; then
    ok "all $_seen exit-code line citations land on their call sites"
  fi
fi

# The constants-block citation (relay-supervisor.sh:N-M), when present, must
# bracket the actual EX_* declaration block.
_range=$(grep -oE 'relay-supervisor\.sh:[0-9]+-[0-9]+' "$_doc" | head -1)
if [ -n "$_range" ]; then
  _a=${_range#*:}; _b=${_a#*-}; _a=${_a%-*}
  if sed -n "${_a},${_b}p" "$_sup" | grep -q 'EX_OK=0'; then
    ok "constants-block citation ($_range) is live"
  else
    bad "exit-codes.md cites the EX_* constants at $_range, but EX_OK=0 is not in that range"
  fi
fi

if [ "$FAIL" -eq 0 ]; then
  printf '\npublish-check: all gates green\n'
else
  printf '\npublish-check: FAILED\n'
fi
exit "$FAIL"
