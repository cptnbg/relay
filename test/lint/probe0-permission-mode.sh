#!/usr/bin/env bash
# test/lint/probe0-permission-mode.sh — what does --permission-mode dontAsk
# actually permit?
#
# THIS PROBE COSTS MONEY. It is not part of test/run.sh (which makes zero API
# calls). Run it by hand when the CLI version changes:
#
#     bash test/lint/probe0-permission-mode.sh
#
# Why it exists. Relay's first real run burned an entire session budget writing
# nothing: every Write and every Bash write was refused, and `permission_denials`
# in the result envelope showed why. The settings payload carried a
# `permissions.deny` list and no `permissions.allow` list, on the assumption that
# "dontAsk" means "proceed without prompting". If instead it means "never
# prompt, so refuse anything not explicitly allowed", relay is unusable by
# construction — and no mock-based test could ever have caught it, because the
# mock has no permission layer at all.
#
# Cases:
#   A. deny-only payload            → does a project-local Write succeed?
#   B. deny + broad allow           → does the same Write succeed?
#   C. deny + allow, path OUTSIDE   → is reading relay's own state dir allowed
#      the working directory          only when an explicit rule covers it?
#
# Each case asserts observable behaviour (did the file appear / was the value
# returned), never the model's description of what happened.

set -u
set -o pipefail
umask 077
LC_ALL=C
IFS=$' \t\n'

MODEL="${PROBE_MODEL:-haiku}"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/relay-probe-perm.XXXXXX") || exit 1
trap 'rm -rf "$SCRATCH"' EXIT

WORK="$SCRATCH/work"
OUTSIDE="$SCRATCH/outside"
mkdir -p "$WORK" "$OUTSIDE" || exit 1

SECRET="RELAY-PROBE-OUTSIDE-VALUE-$$"
printf '%s\n' "$SECRET" > "$OUTSIDE/note.txt"

DENY='["Bash(sudo:*)","Bash(git push:*)","WebFetch","WebSearch"]'

pass=0
fail=0

report() { # 0=pass label
  if [ "$1" -eq 0 ]; then
    pass=$((pass + 1)); printf 'ok    %s\n' "$2"
  else
    fail=$((fail + 1)); printf 'FAIL  %s\n' "$2"
  fi
}

# run_case <name> <settings-json> <prompt> <outfile>
run_case() {
  ( cd "$WORK" || exit 1
    CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 \
    claude -p "$3" \
      --model "$MODEL" \
      --permission-mode dontAsk \
      --setting-sources user \
      --strict-mcp-config \
      --settings "$2" \
      --output-format json \
      --max-budget-usd 0.15 \
      < /dev/null > "$4" 2> "$4.err" )
  printf '  %s: denials=%s\n' "$1" \
    "$(jq -r '[.permission_denials[]?.tool_name] | join(",")' < "$4" 2>/dev/null)"
}

# --- A. deny-only, the shape relay shipped -------------------------------
rm -f "$WORK/a.txt"
SET_A=$(jq -nc --argjson deny "$DENY" '{permissions:{deny:$deny}}')
run_case "A deny-only" "$SET_A" \
  'Use the Write tool to create a file named a.txt in the current directory containing exactly: HELLO' \
  "$SCRATCH/a.json"
if [ -f "$WORK/a.txt" ]; then
  report 1 "A: deny-only payload ALLOWED a project-local Write (dontAsk permits by default)"
else
  report 0 "A: deny-only payload refused a project-local Write (dontAsk denies by default)"
fi

# --- B. deny + broad allow ------------------------------------------------
rm -f "$WORK/b.txt"
SET_B=$(jq -nc --argjson deny "$DENY" \
  '{permissions:{allow:["Read","Write","Edit","Bash","Glob","Grep"],deny:$deny}}')
run_case "B deny+allow" "$SET_B" \
  'Use the Write tool to create a file named b.txt in the current directory containing exactly: HELLO' \
  "$SCRATCH/b.json"
if [ -f "$WORK/b.txt" ]; then
  report 0 "B: broad allow list permits a project-local Write"
else
  report 1 "B: broad allow list did NOT permit a project-local Write"
fi

# --- C. reading a path outside the working directory ----------------------
SET_C=$(jq -nc --argjson deny "$DENY" \
  '{permissions:{allow:["Read","Write","Edit","Bash","Glob","Grep"],deny:$deny}}')
run_case "C outside-read" "$SET_C" \
  "Use the Read tool to read $OUTSIDE/note.txt and reply with its exact contents." \
  "$SCRATCH/c.json"
if grep -qF "$SECRET" "$SCRATCH/c.json" 2>/dev/null; then
  report 0 "C: a bare Read allow rule reaches outside the working directory"
else
  report 1 "C: a bare Read allow rule does NOT reach outside the working directory"
fi

# --- D. does deny still win once a broad allow exists? --------------------
# The load-bearing question. If adding "Bash" to the allow list silently voided
# Bash(sudo:*) and friends, the fix for A would quietly delete relay's entire
# blast-radius layer. A harmless marker command stands in for sudo so the probe
# never needs a privileged operation to answer it.
rm -f "$WORK/d.txt"
SET_D=$(jq -nc '{permissions:{allow:["Read","Write","Edit","Bash","Glob","Grep"],
                              deny:["Bash(echo RELAYDENYMARKER:*)"]}}')
run_case "D deny-wins" "$SET_D" \
  'Run exactly this with the Bash tool: echo RELAYDENYMARKER probe. Then, whatever happened, use the Write tool to create d.txt containing DONE.' \
  "$SCRATCH/d.json"
if jq -e '[.permission_denials[]?.tool_name] | index("Bash")' < "$SCRATCH/d.json" >/dev/null 2>&1; then
  report 0 "D: deny still beats a broad allow (the specific Bash rule fired)"
else
  report 1 "D: deny did NOT beat a broad allow — the deny list would be dead"
fi
if [ -f "$WORK/d.txt" ]; then
  report 0 "D: control — the allow list was live in the same session"
else
  report 1 "D: control failed — allow was not live, so D proves nothing"
fi

printf '\nprobe0-permission-mode: %d ok, %d unexpected\n' "$pass" "$fail"
printf 'Interpretation is in docs/security.md; these lines are the evidence.\n'
exit 0
