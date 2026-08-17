#!/usr/bin/env bash
# test/lib/fixtures.sh — repo and transcript fixture generators for relay's
# test harness. Sourced by test cases (test/cases/*.sh, test/hook/*.sh) via
# test/run.sh.
#
# Target: bash 3.2.57. No associative arrays, no mapfile, no ${var^^}.
set -u
LC_ALL=C
export LC_ALL
IFS=$' \t\n'

# mkrepo <dir>
# Creates a git repo with one initial commit; local user.name/user.email are
# configured to match the mock's own commit identity (mock/mock@example.com)
# so `git log` output is predictable across fixture-made and mock-made
# commits alike.
mkrepo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main >/dev/null 2>&1 || git -C "$dir" init -q >/dev/null 2>&1
  git -C "$dir" config user.name "mock"
  git -C "$dir" config user.email "mock@example.com"
  git -C "$dir" config commit.gpgsign false
  printf '# scratch repo\n\nFixture repo created by test/lib/fixtures.sh:mkrepo.\n' > "$dir/README.md"
  git -C "$dir" add -A >/dev/null 2>&1
  git -c user.name=mock -c user.email=mock@example.com -C "$dir" \
    commit -q -m "chore: initial commit" >/dev/null 2>&1
}

# mkrun <repo>
# Writes a minimal RUN.md and plan.md into an existing repo directory. Does
# not commit — callers decide whether and when to.
mkrun() {
  local repo="$1"
  mkdir -p "$repo"
  cat > "$repo/RUN.md" <<'EOF'
# RUN

Minimal run description for relay test fixtures.

## Goal
Build out src/ incrementally across fresh sessions until COMPLETE.md is
written and sealed with <!-- relay:sealed -->.
EOF
  cat > "$repo/plan.md" <<'EOF'
# Plan

1. step 1
2. step 2
3. step 3
EOF
}

# --- internal helpers -------------------------------------------------

# _fx_usage_split <pct> <window>
# Sets globals _FX_IN / _FX_OUT such that their sum is pct% of window,
# mirroring test/bin/claude's own token-usage arithmetic exactly.
_fx_usage_split() {
  local pct="$1" window="$2" sum
  case "$pct" in ''|*[!0-9]*) pct=30 ;; esac
  case "$window" in ''|*[!0-9]*) window=200000 ;; esac
  sum=$(( window * pct / 100 ))
  _FX_OUT=100
  [ "$sum" -lt 100 ] && _FX_OUT=0
  _FX_IN=$(( sum - _FX_OUT ))
  [ "$_FX_IN" -ge 0 ] || _FX_IN=0
}

_fx_user_line() {
  jq -nc --arg sid "fixture" \
    '{type:"user", isSidechain:false, sessionId:$sid,
      message:{role:"user", content:"continue the build"}}'
}

_fx_decoy_sidechain_line() {
  jq -nc --arg sid "fixture" \
    '{type:"assistant", isSidechain:true, sessionId:$sid,
      message:{role:"assistant", model:"mock-model",
        content:[{type:"text", text:"decoy sidechain output"}],
        usage:{input_tokens:9999999, cache_creation_input_tokens:0,
               cache_read_input_tokens:0, output_tokens:9999999}}}'
}

# _fx_real_assistant_line <input_tokens> <output_tokens>
_fx_real_assistant_line() {
  jq -nc --arg sid "fixture" --argjson in "$1" --argjson out "$2" \
    '{type:"assistant", isSidechain:false, sessionId:$sid,
      message:{role:"assistant", model:"mock-model",
        content:[{type:"text", text:"real assistant turn"}],
        usage:{input_tokens:$in, cache_creation_input_tokens:0,
               cache_read_input_tokens:0, output_tokens:$out}}}'
}

_fx_real_assistant_no_usage_line() {
  jq -nc --arg sid "fixture" \
    '{type:"assistant", isSidechain:false, sessionId:$sid,
      message:{role:"assistant", model:"mock-model",
        content:[{type:"text", text:"real assistant turn, usage omitted"}]}}'
}

_fx_truncated_line() {
  # Deliberately invalid JSON, no closing quote/brace, no trailing newline:
  # simulates a transcript write that was cut off mid-flush.
  printf '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"this got cut off mid'
}

# mktranscript <file> <pct> [window] [flags]
#
# Flags (single string, space-separated, substring matched):
#   sidechain_only  - the file contains ONLY a sidechain assistant entry;
#                      correct hook code must then find no usable usage.
#   no_usage        - the real (isSidechain:false) assistant entry is
#                      present but has no message.usage field at all.
#   truncated       - append a deliberately truncated, invalid-JSON final
#                      line on top of whatever else the other flags produce.
#
# Default (no flags): a user line, a decoy sidechain entry with a huge
# token count, then the real assistant usage line summing to pct% of
# window. This is the shape correct hook code must parse: skip the
# decoy, find the real one.
mktranscript() {
  local file="$1" pct="$2" window="${3:-200000}" flags="${4:-}"
  mkdir -p "$(dirname "$file")"
  _fx_usage_split "$pct" "$window"

  : > "$file"

  case "$flags" in
    *sidechain_only*)
      _fx_decoy_sidechain_line >> "$file"
      ;;
    *)
      _fx_user_line >> "$file"
      _fx_decoy_sidechain_line >> "$file"
      case "$flags" in
        *no_usage*) _fx_real_assistant_no_usage_line >> "$file" ;;
        *)          _fx_real_assistant_line "$_FX_IN" "$_FX_OUT" >> "$file" ;;
      esac
      ;;
  esac

  case "$flags" in
    *truncated*) _fx_truncated_line >> "$file" ;;
  esac
}

# mkhuge_transcript <file> <pct> [window]
#
# A transcript whose FIRST line is the real usage entry (pct% of window),
# followed by a single line larger than 1.3 MB — reproducing a real measured
# 1.36 MB transcript line. Proves a fixed 64 KB tail window is insufficient
# and forces the reader to escalate its window. Padding is generated with
# awk's O(log n) string-doubling trick, not a bash loop.
mkhuge_transcript() {
  local file="$1" pct="$2" window="${3:-200000}" dir padfile pad_len
  dir="$(dirname "$file")"
  mkdir -p "$dir"
  _fx_usage_split "$pct" "$window"

  padfile="$dir/.mkhuge-pad.tmp.$$"
  pad_len=1430000
  awk -v n="$pad_len" 'BEGIN {
    s = "A"
    while (length(s) < n) { s = s s }
    print substr(s, 1, n)
  }' > "$padfile"

  : > "$file"
  _fx_real_assistant_line "$_FX_IN" "$_FX_OUT" >> "$file"
  jq -nc --rawfile pad "$padfile" \
    '{type:"user", isSidechain:false, sessionId:"fixture",
      message:{role:"user",
        content:[{type:"tool_result", tool_use_id:"toolu_mockbig", content:$pad}]}}' \
    >> "$file"

  rm -f "$padfile"
}
