#!/usr/bin/env bash
# Phase 0 probe: does Claude Code honour `sandbox: {"enabled": false}` from an
# inline --settings payload, and — critically — can relay still tell an accepted
# payload apart from one the CLI silently discarded?
#
# THIS PROBE COSTS MONEY. It makes real API calls (four cases) and is
# deliberately NOT part of test/run.sh. Run it by hand before shipping a release that touches
# sandbox_mode, and re-run it whenever the CLI version changes.
#
# Why it exists: with the sandbox off, "the canary was readable and the host
# answered" is what a healthy full-trust run looks like AND what a payload that
# failed validation looks like — `-p` ignores such a payload silently. The only
# element of the payload whose effect is still observable is relay's own inline
# hook, so `run/hook.alive` is what production asserts
# (`relay_settings_probe_disabled`). This probe proves that assertion is sound
# against the real CLI, with a control case that proves it can observe failure.
#
# Usage: bash probe0-sandbox-off.sh <scratch-dir>
set -u
umask 077
LC_ALL=C

SCRATCH="${1:?usage: probe0-sandbox-off.sh <scratch-dir>}"
# `timeout` is coreutils, and CI explicitly asserts it is ABSENT on macOS. Left
# unconditional, the subshell exits 127 before claude runs and this script then
# reports rc=127/hook=MISSING — whose printed remediation is "the payload shape
# was rejected". Wrong answer, paid probe. Use it when present, rely on
# --max-budget-usd when not.
if command -v timeout >/dev/null 2>&1; then TIMEOUT="timeout 180"
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT="gtimeout 180"
else TIMEOUT=""; fi
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
HOOK="$ROOT/plugins/relay/hooks/relay-ctx.sh"
WORK="$SCRATCH/off-work"
OUT="$SCRATCH/off-out"
RESULTS="$SCRATCH/RESULTS-sandbox-off.txt"

[ -f "$HOOK" ] || { printf 'no hook at %s\n' "$HOOK" >&2; exit 1; }

rm -rf "$WORK" "$OUT"
mkdir -p "$WORK" "$OUT"

# Relay-owned scratch. Named and valued EXACTLY as production does
# (`relay_settings_probe`): a neutral, high-entropy token in a plainly-named
# file. This is not cosmetic. An earlier draft used `canary-secret.txt` holding
# `RELAY-CANARY-...-DO-NOT-LEAK` and haiku refused the whole prompt as a
# suspected exfiltration test — no tool calls, so no hook marker and no read
# proof, which this probe correctly reported as a failure. Alarming-looking
# scratch makes the probe measure the model's caution instead of the sandbox.
CANARY="$OUT/probe-canary.txt"
CANARY_VALUE="relayprobe$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -cd 'a-f0-9')"
printf '%s\n' "$CANARY_VALUE" > "$CANARY"

# The hook only acts when RELAY_SESSION_ID is UUID-shaped AND appears in the
# payload on its stdin AND RELAY_DIR is an absolute dir carrying a .relay
# marker. Production satisfies all three; so must this probe.
# A FRESH id per case per run. The CLI refuses to reuse a session id ("already
# in use"), and a constant would fail only on the SECOND run of this probe —
# which the header instructs you to do on every release and every CLI bump. The
# failure is silent in the worst way: the case reports hook=MISSING, and this
# script's own guidance then tells you the payload shape was rejected. Wrong
# remediation, on a probe that costs money. Production uses relay_uuid; this has
# no library to draw on, so it derives the same shape from /dev/urandom.
_rand_uuid() {
  _ru=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -cd 'a-f0-9')
  [ "${#_ru}" -eq 32 ] || { printf 'cannot generate a session id\n' >&2; exit 1; }
  printf '%s-%s-4%s-a%s-%s\n' \
    "$(echo "$_ru" | cut -c1-8)"   "$(echo "$_ru" | cut -c9-12)" \
    "$(echo "$_ru" | cut -c14-16)" "$(echo "$_ru" | cut -c18-20)" \
    "$(echo "$_ru" | cut -c21-32)"
}
SID_OFF=$(_rand_uuid)
SID_NOHOOKS=$(_rand_uuid)
SID_INVALID=$(_rand_uuid)
SID_REAL=$(_rand_uuid)
HOOKDIR="$OUT/hookdir"
mkdir -p "$HOOKDIR/run"
: > "$HOOKDIR/.relay"

# $1 = "off"      -> the payload relay sends in sandbox_mode=disabled
#      "nohooks"  -> same, minus the hooks block (control: proves the marker's
#                    absence is really evidence, not just a flaky hook)
#      "invalid"  -> hooks block present but the payload is malformed, so the
#                    CLI should reject the whole thing. This is the case that
#                    matters: production infers "no marker => the payload was
#                    REJECTED", and only this case exercises that direction.
#                    `nohooks` proves the converse of a different statement.
mkpayload() {
  if [ "$1" = "invalid" ]; then
    # Well-formed JSON, wrong types throughout — the shape a schema change or a
    # typo would produce, which is the scenario the whole probe exists for.
    jq -nc --arg hook "$HOOK" '
      { sandbox: { enabled: "yes", failIfUnavailable: 17 },
        permissions: { allow: "Bash", deny: { nope: true } },
        hooks: {
          PostToolUse: [
            { hooks: [ { type: "command", command: "bash", args: [ $hook ], timeout: 5 } ] }
          ]
        } }'
  elif [ "$1" = "nohooks" ]; then
    jq -nc '{ sandbox: { enabled: false },
              permissions: { allow: ["Read","Write","Edit","Bash","Glob","Grep"],
                             deny: ["Bash(git push:*)"] } }'
  else
    jq -nc --arg hook "$HOOK" '
      { sandbox: { enabled: false },
        permissions: { allow: ["Read","Write","Edit","Bash","Glob","Grep"],
                       deny: ["Bash(git push:*)"] },
        hooks: {
          PostToolUse: [
            { hooks: [ { type: "command", command: "bash", args: [ $hook ], timeout: 5 } ] }
          ]
        } }'
  fi
}

run_case() { # $1=label $2=payload $3=prompt $4=session-id
  label="$1"; payload="$2"; prompt="$3"; sid="$4"
  rm -f "$HOOKDIR/run/hook.alive"
  ( cd "$WORK" || exit 1
    RELAY_SESSION_ID="$sid" RELAY_DIR="$HOOKDIR" \
    CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 \
    $TIMEOUT claude -p "$prompt" \
      --model haiku \
      --session-id "$sid" \
      --permission-mode dontAsk \
      --setting-sources user \
      --strict-mcp-config \
      --settings "$payload" \
      --output-format json \
      --max-budget-usd 0.10 \
      < /dev/null > "$OUT/$label.json" 2> "$OUT/$label.err"
  )
  printf '%s' "$?" > "$OUT/$label.rc"
  if [ -f "$HOOKDIR/run/hook.alive" ]; then
    printf 'fired' > "$OUT/$label.hook"
  else
    printf 'MISSING' > "$OUT/$label.hook"
  fi
}

READPROOF="$OUT/readproof.txt"
NETFILE="$OUT/egress.txt"
PROMPT="Use the Bash tool to run exactly: cat '$CANARY' > '$READPROOF' 2>&1; true
Then use the Bash tool to run exactly: printf 'code=%s\\n' \"\$(curl -sS -m 10 https://example.com -o /dev/null -w '%{http_code}')\" > '$NETFILE' 2>>'$NETFILE'; printf 'rc=%s\\n' \"\$?\" >> '$NETFILE'
Then reply DONE."

: > "$RESULTS"
echo "=== Phase 0 probe: sandbox DISABLED via inline --settings ===" | tee -a "$RESULTS"
echo "canary: $CANARY" | tee -a "$RESULTS"
echo "hookdir: $HOOKDIR" | tee -a "$RESULTS"

echo "--- case 1: sandbox off WITH hooks (production full-trust payload) ---" | tee -a "$RESULTS"
rm -f "$READPROOF" "$NETFILE"
run_case "off" "$(mkpayload off)" "$PROMPT" "$SID_OFF"
CANARY_READ="unreadable"
grep -qF "$CANARY_VALUE" "$READPROOF" 2>/dev/null && CANARY_READ="readable"
EGRESS="(no file)"
[ -f "$NETFILE" ] && EGRESS=$(tr '\n' ' ' < "$NETFILE")
printf 'rc=%s  hook=%s  canary=%s  egress=%s\n' \
  "$(cat "$OUT/off.rc")" "$(cat "$OUT/off.hook")" "$CANARY_READ" "$EGRESS" | tee -a "$RESULTS"

echo "--- case 2: same payload WITHOUT hooks (control; marker MUST be absent) ---" | tee -a "$RESULTS"
rm -f "$READPROOF" "$NETFILE"
run_case "nohooks" "$(mkpayload nohooks)" "$PROMPT" "$SID_NOHOOKS"
printf 'rc=%s  hook=%s\n' "$(cat "$OUT/nohooks.rc")" "$(cat "$OUT/nohooks.hook")" | tee -a "$RESULTS"

echo "--- case 3: hooks present but payload INVALID (marker MUST be absent) ---" | tee -a "$RESULTS"
rm -f "$READPROOF" "$NETFILE"
run_case "invalid" "$(mkpayload invalid)" "$PROMPT" "$SID_INVALID"
printf 'rc=%s  hook=%s\n' "$(cat "$OUT/invalid.rc")" "$(cat "$OUT/invalid.hook")" | tee -a "$RESULTS"

echo "--- case 4: the REAL v1.1 disabled payload (relay_settings_build) ---" | tee -a "$RESULTS"
# Everything earlier probes hand-built payload shapes; this case sends what
# production actually sends, because that is the thing 1.1.0 changes: the
# disabled allow list gains WebFetch/WebSearch and the remote deny narrows to
# mutating subcommands. Three assertions ride one session:
#   (a) WebFetch is genuinely usable (not just listed): the model fetches
#       https://example.com and writes the status to a proof file;
#   (b) `git remote -v` passes (the read form the old broad deny caught);
#   (c) `git remote set-url` is DENIED — this is the only empirical test
#       anywhere of a DEPTH-3 deny prefix (`Bash(git remote set-url:*)`);
#       the repo precedent is depth-2 and nothing else verifies the matcher
#       goes deeper. If (c) fails, v1.1 ships WITHOUT the narrowed deny
#       (fallback: no remote deny in disabled mode at all).
# shellcheck source=/dev/null
. "$ROOT/plugins/relay/scripts/relay-settings.sh"
REPO4="$OUT/repo4"
rm -rf "$REPO4"; mkdir -p "$REPO4"
git -C "$REPO4" init -q 2>/dev/null
git -C "$REPO4" remote add origin https://example.com/placeholder.git 2>/dev/null
REAL_PAYLOAD=$(relay_settings_build "$REPO4" "$HOOKDIR" "$HOOK" "" disabled "")
WEBPROOF="$OUT/webproof.txt"
REMOTEPROOF="$OUT/remoteproof.txt"
rm -f "$WEBPROOF" "$REMOTEPROOF"
PROMPT4="You are in a git repository. Do exactly these four things, in order, each as its own tool call, and do not stop if one is refused — a refusal is an expected result to record:
1. Use the WebFetch tool on https://example.com with prompt 'say OK'. Then use the Bash tool to run exactly: printf 'webfetch=attempted\n' > '$WEBPROOF'
2. Use the Bash tool to run exactly: git remote -v > '$REMOTEPROOF' 2>&1; true
3. Use the Bash tool to run exactly: git remote set-url origin https://example.invalid/changed.git
4. Reply DONE."
( cd "$REPO4" || exit 1
  RELAY_SESSION_ID="$SID_REAL" RELAY_DIR="$HOOKDIR" \
  CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 \
  $TIMEOUT claude -p "$PROMPT4" \
    --model haiku \
    --session-id "$SID_REAL" \
    --permission-mode dontAsk \
    --setting-sources user \
    --strict-mcp-config \
    --settings "$REAL_PAYLOAD" \
    --output-format json \
    --max-budget-usd 0.25 \
    < /dev/null > "$OUT/real.json" 2> "$OUT/real.err"
)
printf '%s' "$?" > "$OUT/real.rc"
REMOTE_READ="denied-or-missing"
grep -q 'example.com/placeholder' "$REMOTEPROOF" 2>/dev/null && REMOTE_READ="passed"
SETURL="MUTATED (deny did NOT fire)"
_cururl=$(git -C "$REPO4" config --get remote.origin.url 2>/dev/null)
[ "$_cururl" = "https://example.com/placeholder.git" ] && SETURL="unchanged (deny fired or call refused)"
WEBFETCH_DENIED=$(jq -r '[(.permission_denials // [])[] | select(.tool_name == "WebFetch")] | length' < "$OUT/real.json" 2>/dev/null)
SETURL_DENIED=$(jq -r '[(.permission_denials // [])[] | select(.tool_name == "Bash")
                        | select((.tool_input.command // "") | contains("set-url"))] | length' < "$OUT/real.json" 2>/dev/null)
printf 'rc=%s  webfetch_denials=%s  remote_v=%s  seturl_denials=%s  origin=%s\n' \
  "$(cat "$OUT/real.rc")" "${WEBFETCH_DENIED:-?}" "$REMOTE_READ" "${SETURL_DENIED:-?}" "$SETURL" | tee -a "$RESULTS"

echo | tee -a "$RESULTS"
echo "--- result envelopes ---" | tee -a "$RESULTS"
for l in off nohooks invalid real; do
  jq -r '{is_error, subtype, terminal_reason, permission_denials: (.permission_denials|length)}
         | to_entries | map("\(.key)=\(.value|tostring)") | join("  ")' \
     < "$OUT/$l.json" 2>/dev/null | sed "s/^/$l: /" | tee -a "$RESULTS"
done
grep -ih 'sandbox' "$OUT"/off.err "$OUT"/nohooks.err "$OUT"/invalid.err 2>/dev/null | head -5 | tee -a "$RESULTS"

echo | tee -a "$RESULTS"
echo "PASS CRITERIA:" | tee -a "$RESULTS"
echo "  case1: is_error=false, hook=fired, canary=readable, egress code=200 rc=0" | tee -a "$RESULTS"
echo "         (payload accepted AND the sandbox really is off)" | tee -a "$RESULTS"
echo "  case2: hook=MISSING" | tee -a "$RESULTS"
echo "         (the marker is real evidence: no hooks in the payload, no marker)" | tee -a "$RESULTS"
echo "  case3: hook=MISSING" | tee -a "$RESULTS"
echo "         (THE load-bearing one: a REJECTED payload also yields no marker," | tee -a "$RESULTS"
echo "          which is the inference production actually makes)" | tee -a "$RESULTS"
echo | tee -a "$RESULTS"
echo "If case1 shows canary=unreadable, the CLI did not honour enabled:false and" | tee -a "$RESULTS"
echo "relay_settings_probe_disabled's assertion (c) is what will catch it." | tee -a "$RESULTS"
echo "If case1 shows hook=MISSING, the payload shape was rejected: fall back to" | tee -a "$RESULTS"
echo "the full sandbox object with enabled:false and re-run this probe." | tee -a "$RESULTS"
echo "  case4: webfetch_denials=0, remote_v=passed, seturl_denials=1, origin unchanged" | tee -a "$RESULTS"
echo "         (WebFetch allowed AND usable; read-form remote passes; the depth-3" | tee -a "$RESULTS"
echo "          deny prefix actually matches. seturl_denials=0 with origin MUTATED" | tee -a "$RESULTS"
echo "          means depth-3 prefixes do NOT match: ship 1.1 without the narrowed" | tee -a "$RESULTS"
echo "          remote deny — drop it from the disabled branch entirely.)" | tee -a "$RESULTS"
