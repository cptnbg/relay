#!/usr/bin/env bash
# Phase 0/1 integration probe: relay's REAL settings payload, exactly as
# relay_settings_build emits it, must simultaneously:
#   1. be accepted by `claude -p` (which silently ignores invalid payloads),
#   2. fire relay's context hook via EXEC form (command + args array),
#   3. enforce sandbox filesystem denyRead.
#
# Exec form matters: shell form re-parses the substituted path, so any user
# whose home directory contains a space gets a silently broken plugin. This
# probe proves exec form works when delivered through --settings.
#
# Usage: bash probe0-integration.sh <scratch-dir>
set -u
umask 077
LC_ALL=C
IFS=$' \t\n'

SCRATCH="${1:?usage: probe0-integration.sh <scratch-dir>}"
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$ROOT/plugins/relay/scripts/relay-settings.sh"

# Deliberately exercise a path containing a space — the exact case shell-form
# hook commands get wrong.
WORK="$SCRATCH/integ/pro ject"
STATE="$SCRATCH/integ/state"
rm -rf "$SCRATCH/integ"
mkdir -p "$WORK" "$STATE"

HOOK="$SCRATCH/integ/relay hook.sh"
# NOTE: the hook writes into STATE, not into an arbitrary scratch path.
# Hooks run subject to the sandbox filesystem policy, so a hook that writes
# outside sandbox.filesystem.allowWrite fails silently and looks exactly like
# "the hook never fired". Relay's state dir is in allowWrite by construction.
cat > "$HOOK" <<EOF
#!/usr/bin/env bash
# Minimal stand-in for the real context guard: drain stdin, prove we ran,
# emit nothing, exit 0.
payload=\$(cat)
printf '%s\n' "\$payload" > "$STATE/hook-payload.json"
printf 'fired\n' >> "$STATE/hook-fired"
exit 0
EOF

CANARY="$SCRATCH/integ/canary.txt"
CANARY_VALUE="RELAY-INTEG-CANARY-DO-NOT-LEAK"
printf '%s\n' "$CANARY_VALUE" > "$CANARY"

PAYLOAD=$(relay_settings_build "$WORK" "$STATE" "$HOOK")
PAYLOAD=$(printf '%s' "$PAYLOAD" | jq -c --arg c "$CANARY" '.sandbox.filesystem.denyRead += [$c]')

ARGS="-p --model haiku --permission-mode dontAsk --setting-sources user --strict-mcp-config --output-format json"
# shellcheck disable=SC2086  # intentional word split of our own literal flag list
if ! relay_settings_assert_argv $ARGS --settings "$PAYLOAD"; then
  echo "FAIL: relay built an argv that fails its own safety assertion" >&2
  exit 1
fi

( cd "$WORK" || exit 1
  CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 \
  claude -p "Do these two things with the Bash tool, in order:
1. Run exactly: echo relay-probe-ok
2. Run exactly: cat '$CANARY'
Then reply with what step 2 printed, or BLOCKED if it failed.

(Step 1 must succeed so a PostToolUse event is generated: a sandbox-blocked
command does not necessarily emit one, so a probe whose only tool call is the
blocked read cannot distinguish 'hook never fired' from 'nothing to fire on'.)" \
    --model haiku \
    --permission-mode dontAsk \
    --setting-sources user \
    --strict-mcp-config \
    --settings "$PAYLOAD" \
    --output-format json \
    --max-budget-usd 0.10 \
    < /dev/null > "$SCRATCH/integ/out.json" 2> "$SCRATCH/integ/out.err"
)
rc=$?

fail=0
report() { # label  0|1 (0 = pass)
  if [ "$2" = "0" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s\n' "$1"; fail=1; fi
}
# Each check captures its own status into a named variable first. Passing `$?`
# straight into a function reads as "the thing above", but by then it may have
# been overwritten — and where two checks chain (a grep followed by a test of
# its result) it becomes genuinely ambiguous which command it refers to.
check() { # label  command...
  local _label="$1"; shift
  if "$@"; then report "$_label" 0; else report "$_label" 1; fi
}
check_not() { # label  command...   (passes when the command FAILS)
  local _label="$1"; shift
  if "$@"; then report "$_label" 1; else report "$_label" 0; fi
}

check     "session completed (rc=$rc)"                                   test "$rc" -eq 0
check     "exec-form hook fired via --settings (path with space)"        test -f "$STATE/hook-fired"
check_not "sandbox denyRead enforced (canary not leaked)" \
          grep -qF "$CANARY_VALUE" "$SCRATCH/integ/out.json" "$SCRATCH/integ/out.err"
result_ok() { jq -e '.is_error == false' "$1" >/dev/null 2>&1; }
check     "result reports success"  result_ok "$SCRATCH/integ/out.json"

if [ -f "$STATE/hook-payload.json" ]; then
  printf 'hook stdin keys: %s\n' \
    "$(jq -r 'keys|join(", ")' < "$STATE/hook-payload.json" 2>/dev/null)"
fi
printf 'hook invocations: %s\n' "$(wc -l < "$STATE/hook-fired" 2>/dev/null | tr -d ' ')"

exit $fail
