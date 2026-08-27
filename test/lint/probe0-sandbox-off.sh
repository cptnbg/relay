#!/usr/bin/env bash
# Phase 0 probe: does Claude Code honour `sandbox: {"enabled": false}` from an
# inline --settings payload, and — critically — can relay still tell an accepted
# payload apart from one the CLI silently discarded?
#
# THIS PROBE COSTS MONEY. It makes real API calls and is deliberately NOT part
# of test/run.sh. Run it by hand before shipping a release that touches
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
# One id PER CASE: the CLI refuses to reuse a session id ("already in use"),
# which silently turned case 2 into a launch failure rather than a control.
SID_OFF="1e1a97b0-0000-4000-a000-00000000d15a"
SID_NOHOOKS="1e1a97b0-0000-4000-a000-00000000d15b"
HOOKDIR="$OUT/hookdir"
mkdir -p "$HOOKDIR/run"
: > "$HOOKDIR/.relay"

# $1 = "off"      -> the payload relay sends in sandbox_mode=disabled
#      "nohooks"  -> same, minus the hooks block (control: proves the marker's
#                    absence is really evidence, not just a flaky hook)
mkpayload() {
  if [ "$1" = "nohooks" ]; then
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
    timeout 180 claude -p "$prompt" \
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

echo | tee -a "$RESULTS"
echo "--- result envelopes ---" | tee -a "$RESULTS"
for l in off nohooks; do
  jq -r '{is_error, subtype, terminal_reason, permission_denials: (.permission_denials|length)}
         | to_entries | map("\(.key)=\(.value|tostring)") | join("  ")' \
     < "$OUT/$l.json" 2>/dev/null | sed "s/^/$l: /" | tee -a "$RESULTS"
done
grep -ih 'sandbox' "$OUT"/off.err "$OUT"/nohooks.err 2>/dev/null | head -5 | tee -a "$RESULTS"

echo | tee -a "$RESULTS"
echo "PASS CRITERIA:" | tee -a "$RESULTS"
echo "  case1: is_error=false, hook=fired, canary=readable, egress code=200 rc=0" | tee -a "$RESULTS"
echo "         (payload accepted AND the sandbox really is off)" | tee -a "$RESULTS"
echo "  case2: hook=MISSING" | tee -a "$RESULTS"
echo "         (the marker is real evidence: no hooks in the payload, no marker)" | tee -a "$RESULTS"
echo | tee -a "$RESULTS"
echo "If case1 shows canary=unreadable, the CLI did not honour enabled:false and" | tee -a "$RESULTS"
echo "relay_settings_probe_disabled's assertion (c) is what will catch it." | tee -a "$RESULTS"
echo "If case1 shows hook=MISSING, the payload shape was rejected: fall back to" | tee -a "$RESULTS"
echo "the full sandbox object with enabled:false and re-run this probe." | tee -a "$RESULTS"
