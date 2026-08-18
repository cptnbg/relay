#!/usr/bin/env bash
# relay-ctx.sh — relay's context-pressure guard (PostToolUse), and its
# PreCompact tripwire when invoked with --precompact.
#
# CONTRACT, in order of importance:
#   1. ALWAYS exits 0. A non-zero exit from a PostToolUse hook is a blocking
#      error whose stderr is fed back to the model — both a way to break the
#      user's session and an injection channel. Relay's telemetry has no
#      business doing either.
#   2. stdout is either empty or EXACTLY one JSON object.
#   3. Writes nothing anywhere unless every guard has passed.
#
# DELIVERY: this hook is passed per-invocation inside relay's --settings
# payload. It is NOT registered globally. Nothing here ever runs in a session
# relay did not start, including for users who installed relay and never ran
# it. (See docs/security.md.)
#
# SANDBOX: hooks run subject to sandbox.filesystem.allowWrite. Writing outside
# it fails silently and is indistinguishable from "the hook never fired".
# Everything below writes only under $RELAY_DIR, which relay puts in allowWrite.
#
# bash 3.2 compatible. No `set -e` (an unbound variable or a failed probe must
# never be fatal here); defensive ${x:-} everywhere instead.

umask 077
LC_ALL=C
IFS=$' \t\n'

# NOTE: deliberately NO `trap ... ERR` and NO `set -e`.
# This script is predicate-heavy: `[ "$PCT" -ge "$CRIT" ]` returning 1 is an
# ANSWER, not an error. An ERR trap turns every such answer into a silent
# exit — which during development made the guard emit nothing at 62%, 78% and
# 92% while looking perfectly healthy. Failing safe is achieved instead by
# defensive ${x:-} defaults, explicit guards, and `exit 0` on every path.

MODE="${1:-posttooluse}"

# ---------------------------------------------------------------------------
# G0 — drain stdin (builtin; no fork)
# Draining before any exit avoids EPIPE upstream. `read -d ''` returns 1 at EOF
# but DOES populate the variable, so the return code is deliberately ignored:
# testing it is the single most likely bug in a hook of this shape.
# ---------------------------------------------------------------------------
PAYLOAD=""
IFS= read -r -d '' -t 5 PAYLOAD 2>/dev/null
: "${PAYLOAD:=}"
IFS=$' \t\n'

# ---------------------------------------------------------------------------
# G1 — is this a relay session at all?
# ---------------------------------------------------------------------------
[ -n "${RELAY_SESSION_ID:-}" ] || exit 0

# ---------------------------------------------------------------------------
# G2 — validate the session id BEFORE it is ever used in a path.
# It reaches a filename below; an id of ../../../../etc/something would be a
# path traversal. Environment is not trustworthy input: .envrc, a Makefile, or
# the agent itself can export anything.
# (bash 3.2: quoting the RHS of =~ makes it literal, so use a variable.)
# ---------------------------------------------------------------------------
_uuid_re='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
[[ ${RELAY_SESSION_ID} =~ $_uuid_re ]] || exit 0

# ---------------------------------------------------------------------------
# G3 — this session only.
# RELAY_SESSION_ID is inherited by everything the relay session spawns,
# including a nested `claude` a Bash tool call might launch. Comparing the
# env's id against the payload's id makes the hook inert everywhere except the
# exact session relay started. `case` keeps it fork-free.
# ---------------------------------------------------------------------------
case "$PAYLOAD" in
  *"$RELAY_SESSION_ID"*) : ;;
  *) exit 0 ;;
esac

# ---------------------------------------------------------------------------
# G4/G5 — state dir sanity and kill switch.
# ---------------------------------------------------------------------------
# RELAY_DIR is relay's session-writable work dir ($STATE/work), the only place
# the sandbox lets this hook write. Its marker is `.relay`, touched by the
# supervisor at startup — state.json now lives one level up at the
# supervisor-only state root, outside this hook's allowWrite, so it can no
# longer serve as the sanity check.
[ -n "${RELAY_DIR:-}" ] || exit 0
case "$RELAY_DIR" in /*) : ;; *) exit 0 ;; esac
[ -d "$RELAY_DIR" ] || exit 0
[ -f "$RELAY_DIR/.relay" ] || exit 0
if [ -f "$RELAY_DIR/hook.off" ]; then exit 0; fi

RUN_DIR="$RELAY_DIR/run"
HSTATE="$RUN_DIR/hook-$RELAY_SESSION_ID.state"

# Refuse to follow a symlink or write to something we do not own. The state dir
# lives outside the repository precisely so an attacker-writable checkout
# cannot pre-create these as links to ~/.zshrc — this is belt and braces.
relay_safe_target() {
  [ -L "$1" ] && return 1
  [ -e "$1" ] && [ ! -O "$1" ] && return 1
  return 0
}

# ---------------------------------------------------------------------------
# PreCompact tripwire.
# Reaching compaction means the thresholds below failed. The marker file is the
# authoritative signal (the supervisor reads it and forces RECOVERY mode next
# session); the injection is best-effort on top.
# ---------------------------------------------------------------------------
if [ "$MODE" = "--precompact" ]; then
  mkdir -p "$RUN_DIR" 2>/dev/null || exit 0
  relay_safe_target "$RUN_DIR/compaction.events" || exit 0
  printf '%s %s\n' "$(date +%s)" "$RELAY_SESSION_ID" \
    >> "$RUN_DIR/compaction.events" 2>/dev/null
  command -v jq >/dev/null 2>&1 || exit 0
  jq -nc --arg t "[relay] Compaction is starting: your working memory is about to be replaced by a summary. As soon as it completes, re-read RUN.md and the handoff, write an updated handoff, commit, and end your turn. Do not resume feature work after compaction." \
    '{hookSpecificOutput:{hookEventName:"PreCompact",additionalContext:$t}}' 2>/dev/null
  exit 0
fi

# ---------------------------------------------------------------------------
# Thresholds. Percentages of the tier's context window — the window is part of
# the model tier record, not a global constant, because relay escalates
# sonnet -> opus -> fable and those differ.
# ---------------------------------------------------------------------------
WINDOW="${RELAY_CTX_WINDOW:-200000}"
case "$WINDOW" in ''|*[!0-9]*) WINDOW=200000 ;; esac
[ "$WINDOW" -ge 1000 ] || WINDOW=200000

SOFT="${RELAY_SOFT_PCT:-60}"
HARD="${RELAY_HARD_PCT:-75}"
CRIT="${RELAY_CRIT_PCT:-88}"
case "$SOFT" in ''|*[!0-9]*) SOFT=60 ;; esac
case "$HARD" in ''|*[!0-9]*) HARD=75 ;; esac
case "$CRIT" in ''|*[!0-9]*) CRIT=88 ;; esac

# ---------------------------------------------------------------------------
# G6 — prior state and throttle. Builtin redirect, no fork.
# ---------------------------------------------------------------------------
LAST_EPOCH=0; LAST_PCT=0; LAST_LEVEL=0; CALLS=0
if [ -f "$HSTATE" ]; then
  IFS='|' read -r LAST_EPOCH LAST_PCT LAST_LEVEL CALLS < "$HSTATE" 2>/dev/null
  IFS=$' \t\n'
fi
case "$LAST_EPOCH" in ''|*[!0-9]*) LAST_EPOCH=0 ;; esac
case "$LAST_PCT"   in ''|*[!0-9]*) LAST_PCT=0   ;; esac
case "$LAST_LEVEL" in ''|*[!0-9]*) LAST_LEVEL=0 ;; esac
case "$CALLS"      in ''|*[!0-9]*) CALLS=0      ;; esac
CALLS=$(( CALLS + 1 ))

NOW=$(date +%s)
AGE=$(( NOW - LAST_EPOCH ))
[ "$AGE" -ge 0 ] || AGE=99999   # clock stepped backwards: force a rescan

# Cheap when there is slack, every call once pressure is real.
INTERVAL=30
if [ "$LAST_PCT" -ge 40 ]; then INTERVAL=15; fi
if [ "$LAST_PCT" -ge 55 ]; then INTERVAL=0; fi

relay_save_state() {
  mkdir -p "$RUN_DIR" 2>/dev/null || return 0
  relay_safe_target "$HSTATE" || return 0
  printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" > "$HSTATE.tmp.$$" 2>/dev/null \
    && mv -f "$HSTATE.tmp.$$" "$HSTATE" 2>/dev/null
  return 0
}

if [ "$INTERVAL" -gt 0 ] && [ "$AGE" -lt "$INTERVAL" ]; then
  relay_save_state "$LAST_EPOCH" "$LAST_PCT" "$LAST_LEVEL" "$CALLS"
  exit 0
fi

# ---------------------------------------------------------------------------
# G7 — active path.
# ---------------------------------------------------------------------------
command -v jq >/dev/null 2>&1 || exit 0
mkdir -p "$RUN_DIR" 2>/dev/null || exit 0

TP=$(printf '%s' "$PAYLOAD" | jq -r '.transcript_path // empty' 2>/dev/null)

# transcript_path arrives from outside. A FIFO here would hang the hook
# forever, blocking every tool call in the session — a denial of service on the
# whole product. Require a regular, non-symlink file.
if [ -z "$TP" ] || [ ! -f "$TP" ] || [ -L "$TP" ]; then
  relay_safe_target "$RUN_DIR/hook.alive" && : > "$RUN_DIR/hook.alive" 2>/dev/null
  relay_save_state "$NOW" "$LAST_PCT" "$LAST_LEVEL" "$CALLS"
  exit 0
fi
relay_safe_target "$RUN_DIR/hook.alive" && : > "$RUN_DIR/hook.alive" 2>/dev/null

FSIZE=$(wc -c < "$TP" 2>/dev/null | tr -d ' ')
case "$FSIZE" in ''|*[!0-9]*) exit 0 ;; esac

# Sum the newest non-sidechain assistant usage entry.
#   - isSidechain entries are subagents; we measure the ORCHESTRATOR's context,
#     and a subagent's usage would wildly misreport it.
#   - The tail window escalates because a single transcript line was measured
#     at 1.36 MB in a real 42 MB transcript: a fixed 64 KB window can contain
#     zero complete lines and silently yield nothing.
relay_scan_usage() {
  _bytes="$1"
  if [ "$FSIZE" -le "$_bytes" ]; then
    jq -c -R 'fromjson?
      | select(.type == "assistant")
      | select(.isSidechain != true)
      | select(.message.usage != null)
      | .message.usage
      | ((.input_tokens // 0) + (.cache_creation_input_tokens // 0)
         + (.cache_read_input_tokens // 0) + (.output_tokens // 0))' \
      "$TP" 2>/dev/null | tail -1
  else
    # sed 1d drops the almost-certainly truncated first line of the window.
    tail -c "$_bytes" "$TP" 2>/dev/null | sed '1d' \
      | jq -c -R 'fromjson?
        | select(.type == "assistant")
        | select(.isSidechain != true)
        | select(.message.usage != null)
        | .message.usage
        | ((.input_tokens // 0) + (.cache_creation_input_tokens // 0)
           + (.cache_read_input_tokens // 0) + (.output_tokens // 0))' \
        2>/dev/null | tail -1
  fi
}

USED=""
for KB in 64 256 1024 4096; do
  USED=$(relay_scan_usage $(( KB * 1024 )))
  case "$USED" in
    ''|*[!0-9]*) USED="" ;;
    *) break ;;
  esac
  [ "$FSIZE" -le $(( KB * 1024 )) ] && break
done

# Unknown usage means no injection. Guessing high would derail a healthy
# session; guessing low would miss the handoff entirely.
if [ -z "$USED" ]; then
  relay_save_state "$NOW" "$LAST_PCT" "$LAST_LEVEL" "$CALLS"
  exit 0
fi

PCT=$(( USED * 100 / WINDOW ))
[ "$PCT" -le 100 ] || PCT=100

# A large drop means autocompact fired despite our thresholds. Reset the level
# machine, or the guard would never warn again for the rest of the session.
LEVEL="$LAST_LEVEL"
if [ "$LAST_PCT" -gt 0 ] && [ $(( LAST_PCT - PCT )) -ge 15 ]; then
  LEVEL=0
  relay_safe_target "$RUN_DIR/compacted.flag" && : > "$RUN_DIR/compacted.flag" 2>/dev/null
fi

NEWLEVEL="$LEVEL"
if [ "$PCT" -ge "$SOFT" ] && [ "$NEWLEVEL" -lt 1 ]; then NEWLEVEL=1; fi
if [ "$PCT" -ge "$HARD" ] && [ "$NEWLEVEL" -lt 2 ]; then NEWLEVEL=2; fi
if [ "$PCT" -ge "$CRIT" ] && [ "$NEWLEVEL" -lt 3 ]; then NEWLEVEL=3; fi

relay_save_state "$NOW" "$PCT" "$NEWLEVEL" "$CALLS"

if relay_safe_target "$RUN_DIR/ctx.log"; then
  printf '%s pct=%s used=%s level=%s calls=%s\n' \
    "$NOW" "$PCT" "$USED" "$NEWLEVEL" "$CALLS" >> "$RUN_DIR/ctx.log" 2>/dev/null
fi

# Emit once per level transition. Level 3 re-emits every call: at that point
# the model has ignored two escalations and the session is about to lose its
# working state.
EMIT=0
if [ "$NEWLEVEL" -gt "$LEVEL" ]; then EMIT=1; fi
if [ "$NEWLEVEL" -ge 3 ]; then EMIT=1; fi
[ "$EMIT" = "1" ] || exit 0

case "$NEWLEVEL" in
  1) MSG="[relay] CONTEXT CHECKPOINT — ${PCT}% of your context window is used.

Begin landing this session. Finish the CURRENT atomic step only: do not start a
new plan step, open a new area of the codebase, or dispatch new exploratory
subagents.

You have judgment here. It is fine to briefly exceed this band to finish a unit
of work coherently — complete the file, make the test pass, close the commit —
rather than leave it half-done for the next session to untangle. Half-finished
work is more expensive than a slightly longer session.

When the current step is done and verified:
  1. Checkpoint-commit everything complete.
  2. Rewrite the handoff (write the .tmp file, then rename it).
  3. Commit the handoff.
  4. End your turn.

Ending your turn IS the handoff. A fresh session is launched automatically from
what you write. This is the designed mechanism, not a failure." ;;
  2) MSG="[relay] MANDATORY HANDOFF — ${PCT}% of your context window is used.

The judgment window is over. Start nothing new: no subagents, no new files, no
next step. If an edit in flight cannot be made consistent within two tool
calls, revert it rather than leave the tree broken.

Now, in this order:
  1. Commit whatever is complete.
  2. Write the handoff: what is DONE (with proof), what is IN PROGRESS and its
     exact state, the single NEXT action, and anything the next session must
     not re-litigate. Write the .tmp file, then rename it.
  3. Commit it.
  4. End your turn.

Anything not in the handoff or in git is lost when this session ends." ;;
  3) MSG="[relay] CRITICAL — ${PCT}% used. Compaction is imminent and will destroy
your working state.

Write the handoff NOW, even if incomplete — say plainly in it what is
unfinished. Rename it into place, commit whatever is on disk, and end your turn
with your very next action. Take no other action of any kind." ;;
esac

# The emitted text is assembled ONLY from relay-computed scalars (a percentage)
# and these fixed strings. Nothing derived from the transcript or the payload
# is ever interpolated: that would turn this hook into a laundering pipe,
# promoting untrusted repository text into operator-shaped instruction.
# jq --arg handles quoting.
jq -nc --arg t "$MSG" \
  '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$t}}' \
  2>/dev/null

exit 0
