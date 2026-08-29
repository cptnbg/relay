#!/usr/bin/env bash
# test/lint/citations.sh — every source citation in every Markdown file must
# still land on the code it claims to describe.
#
# Relay's documentation cites its own source by line: `relay-supervisor.sh:269`,
# `(:275)`, `**Line 874**`, `(lines 736-842)`. Those coordinates rot on every
# edit, and a rotted citation is worse than no citation, because it looks
# checked.
#
# The gate that existed before this one covered docs/exit-codes.md alone — which
# is exactly why that was the only file in the tree without rot. This checks
# every `.md`.
#
# TWO things are verified, and the second is the one that matters:
#
#   1. The coordinate resolves. The named file exists, is named unambiguously,
#      and the line range is inside it.
#   2. The CLAIM still fits. At least one code token from the phrase the
#      citation is attached to — `handoff_valid`, `exec_hash`, `PROJECT` — has
#      to appear inside the cited range. A correct line number attached to a
#      sentence about different code fails here, which is this repository's own
#      standard for a citation.
#
# What it cannot do, stated plainly rather than implied: this is a lint, not a
# proof. It shows the cited lines are still *about* what the sentence is about,
# which is the failure mode line numbers actually have. It cannot tell you the
# sentence is true — only reading the code does that.
#
# Anchors come from the phrase between the previous citation and this one,
# because that is the claim this citation supports; the surrounding lines are
# consulted only when that phrase carries no code token of its own. Tokens the
# author marked up with backticks are preferred over prose words, for the
# obvious reason: the author was pointing at an identifier.
#
# Usage: bash test/lint/citations.sh [--verbose]
# Exit:  0 clean, 1 at least one citation is stale, unresolvable or unanchored.

set -u
LC_ALL=C
export LC_ALL
IFS=$' \t\n'

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT" || exit 1

VERBOSE=0
for _a in "$@"; do
  case "$_a" in
    --verbose|-v) VERBOSE=1 ;;
    *) printf 'citations.sh: unknown argument: %s\n' "$_a" >&2; exit 2 ;;
  esac
done

FAIL=0
N_OK=0
N_BAD=0
# ---------------------------------------------------------------------------
# The file index. Every citation target must resolve to exactly one path in
# this tree; an ambiguous basename is a failure, not a coin flip.
# ---------------------------------------------------------------------------
INDEX=$(find . -name .git -prune -o -name .a5c -prune -o -type f -print 2>/dev/null \
        | sed 's|^\./||' | sort)

# resolve_target <token> -> repo-relative path on stdout, or nothing.
resolve_target() {
  _rt_hits=$(printf '%s\n' "$INDEX" | grep -F -- "$1" | while IFS= read -r _p; do
               [ "$_p" = "$1" ] && { printf '%s\n' "$_p"; continue; }
               [ "${_p%"/$1"}" != "$_p" ] && printf '%s\n' "$_p"
             done)
  [ -n "$_rt_hits" ] || { unset _rt_hits; return 0; }
  if [ "$(printf '%s\n' "$_rt_hits" | grep -c '')" -eq 1 ]; then
    printf '%s\n' "$_rt_hits"
  fi
  unset _rt_hits
}

# ---------------------------------------------------------------------------
# Citation extraction.
#
# Four grammars are in use across the docs, and all four are checked:
#   `path/to/file.sh:120`  `file.sh:120-140`  `file.sh:79-82, 94-106`
#   `:275`                 — inherits its file from the surrounding text
#   **Line 874**           — docs/exit-codes.md's call-site bullets
#   (lines 736-842)        — the same file's prose form, previously unchecked
#
# Deliberately NOT parsed: the bare `| 183 | ... |` rows of docs/exit-codes.md's
# EX_PREFLIGHT table. A leading integer in a Markdown table is a line number
# there and an exit code in the two tables above it, and nothing in the syntax
# tells them apart. test/publish-check.sh keeps that one, where it can bound the
# guess to sections headed by an EX_ constant and check the stronger property
# — that the cited line mentions that constant or `exit <code>`.
#
# All three patterns are matched in ONE left-to-right scan rather than in three
# passes, because the text BETWEEN two citations is what the second one claims,
# and three independent passes cannot see that ordering.
#
# A Markdown line whose backticks are unbalanced is joined to the next before
# matching: (`:79-82,\n  94-106`) is one citation wrapped by an editor, and half
# a citation is not something to skip silently.
#
# Emits, tab-separated: mdline, path-or-dash, first, last, near-text, wide-text
# ---------------------------------------------------------------------------
EXTRACT='
{ gsub(/\t/, " "); raw[NR] = $0 }
END {
  n = NR
  for (i = 1; i <= n; i++) {
    line = raw[i]; startline = i
    while (i < n && (gsub(/`/, "`", line) % 2) == 1) { i++; line = line " " raw[i] }
    lo = startline - 3; if (lo < 1) lo = 1
    hi = startline + 1; if (hi > n) hi = n
    wide = ""
    for (k = lo; k <= hi; k++) wide = wide " " raw[k]
    back = ""
    for (k = (startline - 2 < 1 ? 1 : startline - 2); k < startline; k++) back = back " " raw[k]
    scan(line, startline, wide, back)
  }
}
function scan(line, ln, wide, back,   rest, pre, p1, p2, p3, l1, l2, l3, best, blen, kind, tok, j, path, nums, near, after) {
  rest = line
  pre = back
  while (1) {
    p1 = match(rest, /`[A-Za-z0-9_.\/-]*:[0-9]+(-[0-9]+)?(,[[:space:]]*[0-9]+(-[0-9]+)?)*`/)
    l1 = RLENGTH
    p2 = match(rest, /\*\*Lines?[[:space:]]+[0-9]+(-[0-9]+)?/)
    l2 = RLENGTH
    p3 = match(rest, /(\(|[[:space:]])lines?[[:space:]]+[0-9]+(-[0-9]+)?/)
    l3 = RLENGTH
    best = 0; kind = 0; blen = 0
    if (p1 > 0)                             { best = p1; kind = 1; blen = l1 }
    if (p2 > 0 && (best == 0 || p2 < best)) { best = p2; kind = 2; blen = l2 }
    if (p3 > 0 && (best == 0 || p3 < best)) { best = p3; kind = 3; blen = l3 }
    if (best == 0) return
    # The phrase this citation is attached to. That phrase is usually before
    # the citation, but not always — docs/exit-codes.md leads with the
    # coordinate ("**Line 1095** — post-exit: ...") — so the text up to the
    # NEXT citation is included too. Earlier lines are folded in only when
    # what precedes the citation on its own line is too short to be a claim,
    # because otherwise a bullet three lines up donates its identifiers and
    # validates a coordinate belonging to something else.
    after = substr(rest, best + blen)
    if (match(after, /`[A-Za-z0-9_.\/-]*:[0-9]/)) after = substr(after, 1, RSTART - 1)
    near = substr(rest, 1, best - 1)
    if (length(near) < 40) near = pre " " near
    near = near " " after
    tok  = substr(rest, best, blen)
    rest = substr(rest, best + blen)
    pre = ""
    if (kind == 1) {
      tok = substr(tok, 2, length(tok) - 2)
      j = index(tok, ":")
      path = substr(tok, 1, j - 1)
      nums = substr(tok, j + 1)
      ranges(path, nums, ln, near, wide)
    } else if (kind == 2) {
      sub(/^\*\*Lines?[[:space:]]+/, "", tok)
      ranges("", tok, ln, near, wide)
    } else {
      sub(/^.*lines?[[:space:]]+/, "", tok)
      ranges("", tok, ln, near, wide)
    }
  }
}
function ranges(path, nums, ln, near, wide,   np, parts, j, a, b, r) {
  np = split(nums, parts, /,[[:space:]]*/)
  for (j = 1; j <= np; j++) {
    r = parts[j]
    if (r == "") continue
    if (index(r, "-") > 0) { a = substr(r, 1, index(r, "-") - 1); b = substr(r, index(r, "-") + 1) }
    else { a = r; b = r }
    if (a == "" || b == "") continue
    if (path == "") path = "-"
    printf "%d\t%s\t%s\t%s\t%s\t%s\n", ln, path, a, b, near, wide
  }
}
'

# ---------------------------------------------------------------------------
# Anchors, strongest first.
#
#   A  code-shaped: carries an underscore (`handoff_valid`), is a dotted
#      journal event or state key (`probe.egress`, `state.json`), or is
#      SCREAMING_CASE (`PROJECT`, `EX_OK`). Specific enough that finding one
#      inside a range is evidence rather than luck.
#   B  marked up as code by the author with backticks, but an ordinary word
#      otherwise (`fable`, `dontAsk`, `denyRead`, `cfg`). Three characters or
#      more, minus the vocabulary that appears on every page of this
#      repository. Backticks are required here precisely so the threshold can
#      be this low: `cfg` in a code span is the author naming a function, while
#      `cfg` as a bare word would be noise.
#   C  long prose words, for claims written in English ("install signal
#      traps"). Deliberately the weakest, and reached only when nothing above
#      exists.
#
# Locality wins over strength: all three tiers are tried against the near
# phrase before any of them is tried against the surrounding paragraph. A weak
# token from the sentence the citation is in beats a strong one three lines up
# that belongs to a different claim.
# Anything ending in a known file extension is dropped throughout: the citation
# already names its file, so matching on that would pass every citation.
#
# The stoplist is the load-bearing half of tiers B and C. Without it `run`,
# `work`, `and` and `The` all read as anchors — every one of those was matched
# out of a backtick span while this gate was being written, and each turned a
# stale citation green.
# ---------------------------------------------------------------------------
STOPWORDS=' about after against already always another anything because before
behind being below between beyond both cannot case claude command comment
commit compare config context deliberately different directory does done
document documented either else enough error esac every everything except exit
 git grep
fail false file files first from further having here however inside instead
into itself just like little longer machine matter meaning message mode module
moment name next nothing null number object only operator others otherwise
paragraph path plugin position present process project property purpose read
reading reason record relay repository result rather really run running script
second section sentence session setting shell simply single something source
states status still string structure subject supervisor supposed system takes
talking that then there these this those through together toward true trying
type unless until useful using value verified version what when where whether
which with within without work worth write writing written '

# Drop only tokens that name a file in THIS tree, because the citation already
# names its file and matching on that would pass every citation. Everything
# else that merely looks like a filename is kept and is worth keeping:
# `INBOX.md`, `state.json`, `probe.ok`, `hook.alive` and `continue.json` are
# runtime artefacts, not source files, and they are the most identifying tokens
# this documentation has.
drop_paths() { grep -F -x -v -i -f "$TMPD/basenames"; }

not_stopword() {
  while IFS= read -r _w; do
    case "$STOPWORDS" in
      *" $(printf '%s' "$_w" | tr 'A-Z' 'a-z') "*) : ;;
      *) printf '%s\n' "$_w" ;;
    esac
  done
}

# Identifier runs from inside backtick spans only.
#
# Leading dashes are stripped rather than rejected: half the tokens the docs
# actually point at are flags — `--max-budget-usd`, `--setting-sources`,
# `--precompact` — and a regex anchored at [A-Za-z_] threw every one of them
# away, which is why a run of probe citations looked stale when they were fine.
# When the backtick count is ODD the span boundaries are ambiguous — the text
# began or ended mid-span, which happens whenever the near phrase is stitched
# together from a wrapped line. Both readings are emitted rather than guessing,
# because guessing wrong drops every real anchor and reports a healthy citation
# as stale.
tokens_backtick() { # <text>
  printf '%s\n' "$1" | awk '
    BEGIN { RS = "`" }
    { if (NR % 2 == 0) print; else odd = odd "\n" $0; n++ }
    END { if (n % 2 == 0) print odd }' \
    | tr -c 'A-Za-z0-9_.-' '\n' | sed 's/^-*//' \
    | grep -E '^[A-Za-z_][A-Za-z0-9_.-]*$'
}

# Identifier runs from the whole text, marked up or not.
tokens_all() { # <text>
  printf '%s\n' "$1" | tr -c 'A-Za-z0-9_.-' '\n' \
    | grep -E '^[A-Za-z_][A-Za-z0-9_.-]*$'
}

# An underscore, or a dotted pair with two real halves (`probe.egress`, and
# not `e.g.`). SCREAMING_CASE is tier A only when the author backticked it:
# unmarked, it matches English acronyms — CLI, BSD, API, MAJOR — which are
# everywhere in this prose and identify nothing.
CODE_SHAPE='(_[A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9]\.[A-Za-z][A-Za-z])'
SHOUTY='^[A-Z][A-Z0-9_]+$'

anchors_a() {
  { tokens_all      "$1" | grep -E "$CODE_SHAPE"
    tokens_backtick "$1" | grep -E "$SHOUTY"
  } | drop_paths | sort -u
}
anchors_b() { tokens_backtick "$1" | grep -vE "$CODE_SHAPE" | grep -E '^.{3,}$' \
                | drop_paths | not_stopword | sort -u; }

# Tier C splits on punctuation the other two keep, because it is looking for
# English words: "acceptance-command" has to yield `acceptance`, not one token
# nothing will ever match.
anchors_c() {
  printf '%s\n' "$1" | tr -c 'A-Za-z0-9' '\n' \
    | grep -E '^[A-Za-z][A-Za-z0-9]{6,}$' | drop_paths | not_stopword | sort -u
}

# Fill $TMPD/anch with every anchor, strongest and nearest first, one
# "tier<TAB>token" per line. All of them are tried: a tier that produces
# tokens but no match hands over to the next rather than condemning the
# citation, because "this phrase happens to contain a long word" is not
# evidence that the coordinate is wrong. The tier that matched is reported, so
# a C-wide pass can be read for what it is — the weakest thing this gate says.
build_anchors() { # <near> <wide>
  { anchors_a "$1" | sed 's/^/A-near	/'
    anchors_b "$1" | sed 's/^/B-near	/'
    anchors_c "$1" | sed 's/^/C-near	/'
    anchors_a "$2" | sed 's/^/A-wide	/'
    anchors_b "$2" | sed 's/^/B-wide	/'
    anchors_c "$2" | sed 's/^/C-wide	/'
  } | awk -F'	' '!seen[$2]++' > "$TMPD/anch"
  [ -s "$TMPD/anch" ]
}

report() { # <md> <mdline> <cite> <message>
  printf 'FAIL  %s:%s  %s\n        %s\n' "$1" "$2" "$3" "$4"
  N_BAD=$((N_BAD + 1))
  FAIL=1
}

verify_one() { # <md> <mdline> <a> <b> <near> <wide> <candidate paths>
  _vo_md="$1"; _vo_ln="$2"; _vo_a="$3"; _vo_b="$4"
  _vo_near="$5"; _vo_wide="$6"; _vo_cands="$7"
  case "$_vo_a$_vo_b" in *[!0-9]*) return 0 ;; esac
  if [ "$_vo_b" -lt "$_vo_a" ] || [ "$_vo_a" -lt 1 ]; then
    report "$_vo_md" "$_vo_ln" "$_vo_a-$_vo_b" "is not a line range"
    return 0
  fi
  if ! build_anchors "$_vo_near" "$_vo_wide"; then
    report "$_vo_md" "$_vo_ln" "$_vo_a-$_vo_b" \
      "carries no token that says what it is about; name the function, key or constant"
    return 0
  fi

  _vo_oob=""
  _vo_first=""
  _vo_inrange=0
  for _vo_f in $_vo_cands; do
    [ -n "$_vo_f" ] || continue
    _vo_len=$(grep -c '' "$_vo_f" 2>/dev/null)
    if [ "$_vo_b" -gt "${_vo_len:-0}" ]; then
      _vo_oob="$_vo_oob $_vo_f is ${_vo_len:-0} lines;"
      continue
    fi
    _vo_inrange=1
    [ -n "$_vo_first" ] || _vo_first="$_vo_f"
    sed -n "${_vo_a},${_vo_b}p" "$_vo_f" > "$TMPD/range"
    while IFS=$'\t' read -r _vo_tier _vo_tok; do
      if grep -F -i -q -- "$_vo_tok" "$TMPD/range" 2>/dev/null; then
        N_OK=$((N_OK + 1))
        if [ "$VERBOSE" -eq 1 ]; then
          printf 'ok    %s:%s  %s:%s-%s  [%s: %s]\n' \
            "$_vo_md" "$_vo_ln" "$_vo_f" "$_vo_a" "$_vo_b" "$_vo_tier" "$_vo_tok"
        fi
        return 0
      fi
    done < "$TMPD/anch"
  done

  # Every candidate ended past the end of its file: the coordinate is not just
  # wrong, it cannot exist.
  if [ "$_vo_inrange" -eq 0 ]; then
    _vo_first=$(printf '%s\n' "$_vo_cands" | head -1)
    report "$_vo_md" "$_vo_ln" "$_vo_first:$_vo_a-$_vo_b" "past end of file —$_vo_oob"
    return 0
  fi

  # In range, but about something else. Say where the strongest token lives
  # now, so the correction travels with the failure.
  _vo_hint=""
  while IFS=$'\t' read -r _vo_tier _vo_tok; do
    _vo_at=$(grep -n -F -i -- "$_vo_tok" "$_vo_first" 2>/dev/null | cut -d: -f1 \
             | tr '\n' ',' | sed 's/,$//')
    if [ -n "$_vo_at" ]; then _vo_hint="[$_vo_tok] is at $_vo_at"; break; fi
  done < "$TMPD/anch"
  [ -n "$_vo_hint" ] || _vo_hint="none of [$(cut -f2 "$TMPD/anch" | tr '\n' ' ')] occur in that file"
  report "$_vo_md" "$_vo_ln" "$_vo_first:$_vo_a-$_vo_b" \
    "does not mention what the sentence claims — $_vo_hint"
}

check_file() { # <markdown path>
  _cf_md="$1"
  awk "$EXTRACT" "$_cf_md" > "$TMPD/cites" 2>/dev/null
  [ -s "$TMPD/cites" ] || { unset _cf_md; return 0; }

  # What a bare `:275` or **Line 874** inherits. Three candidates, all tried:
  #
  #   1. the most recent explicit citation — right inside a section that is
  #      about one file, which is most of docs/architecture.md;
  #   2. the file the document DECLARES it is citing, with
  #      `<!-- citations-default: path -->` near the top. docs/exit-codes.md is
  #      a page of `**Line N**` bullets against one file with two asides, so
  #      rule 1 alone binds sixty citations to whichever file was mentioned
  #      last. Saying it outright beats inferring it;
  #   3. the document's most-cited file, for anything that declares nothing.
  #
  # A parenthetical aside ("via `relay_lock` in `lib/relay-lib.sh:212-251`")
  # moves rule 1's pointer without moving the subject of the surrounding list,
  # which is exactly why more than one candidate is tried.
  _cf_declared=$(sed -n 's/^[[:space:]]*<!--[[:space:]]*citations-default:[[:space:]]*\([^[:space:]]*\).*/\1/p' \
                 "$_cf_md" | head -1)
  [ -n "$_cf_declared" ] && _cf_declared=$(resolve_target "$_cf_declared")
  _cf_dominant=$(cut -f2 "$TMPD/cites" | grep -v '^-$' | sort | uniq -c | sort -rn \
                 | head -1 | awk '{print $2}')
  [ -n "$_cf_dominant" ] && _cf_dominant=$(resolve_target "$_cf_dominant")
  _cf_last=""

  while IFS=$'\t' read -r _ln _path _a _b _near _wide; do
    [ -n "${_ln:-}" ] || continue
    if [ "$_path" != "-" ]; then
      _t=$(resolve_target "$_path")
      if [ -z "$_t" ]; then
        report "$_cf_md" "$_ln" "$_path:$_a-$_b" \
          "names a file that does not resolve to exactly one path in this tree"
        continue
      fi
      _cf_last="$_t"
      _cands="$_t"
    else
      _cands=""
      for _c in "$_cf_last" "$_cf_declared" "$_cf_dominant"; do
        [ -n "$_c" ] || continue
        case "$_cands" in
          "$_c"|"$_c
"*|*"
$_c"|*"
$_c
"*) continue ;;
        esac
        _cands="${_cands:+$_cands
}$_c"
      done
      if [ -z "$_cands" ]; then
        report "$_cf_md" "$_ln" "(bare):$_a-$_b" \
          "a bare line citation with no file citation anywhere to inherit from"
        continue
      fi
    fi
    verify_one "$_cf_md" "$_ln" "$_a" "$_b" "$_near" "$_wide" "$_cands"
  done < "$TMPD/cites"
  unset _cf_md _cf_dominant _cf_declared _cf_last
}

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/relay-cite.XXXXXX") || exit 1
trap 'rm -rf "$TMPD"' EXIT INT TERM HUP

printf '%s\n' "$INDEX" | sed 's|.*/||' | sort -u > "$TMPD/basenames"

printf '%s\n' "$INDEX" | grep -E '\.md$' | sort > "$TMPD/mds"
while IFS= read -r _md; do
  [ -n "$_md" ] || continue
  check_file "$_md"
done < "$TMPD/mds"

printf '\ncitations: %d verified, %d stale\n' "$N_OK" "$N_BAD"
exit "$FAIL"
