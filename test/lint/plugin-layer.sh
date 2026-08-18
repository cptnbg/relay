#!/usr/bin/env bash
# test/lint/plugin-layer.sh — coherence checks for the plugin packaging layer.
#
# The scripts have a test suite; the layer that DELIVERS them (commands, skill,
# manifests, defaults) had nothing, and that is where the audit found silent
# breakage: a command pointing at a skill section that had been renamed, a cfg
# key the supervisor read that defaults.json never declared (PKG-3), manifests
# whose versions drifted apart. Pure shell, zero API, bash 3.2.
set -u
LC_ALL=C
IFS=$' \t\n'

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
PLUGIN="$ROOT/plugins/relay"
SKILL="$PLUGIN/skills/relay/SKILL.md"
DEFAULTS="$PLUGIN/config/defaults.json"
SUPERVISOR="$PLUGIN/scripts/relay-supervisor.sh"
PLUGIN_JSON="$PLUGIN/.claude-plugin/plugin.json"
MARKET_JSON="$ROOT/.claude-plugin/marketplace.json"

FAIL=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; FAIL=1; }

# ---------------------------------------------------------------------------
# 1. All 8 command files exist with parseable frontmatter: an opening `---` on
#    line 1, a closing `---`, and a non-empty description: line between them.
# ---------------------------------------------------------------------------
COMMANDS="relay-approve relay-doctor relay-init relay-note relay-resume relay-run relay-status relay-stop"

for c in $COMMANDS; do
  f="$PLUGIN/commands/$c.md"
  if [ ! -f "$f" ]; then
    bad "missing command file: $f"
    continue
  fi
  if [ "$(head -1 "$f")" != "---" ]; then
    bad "$c.md: frontmatter does not open with --- on line 1"
    continue
  fi
  _fm=$(sed -n '2,20p' "$f" | sed -n '1,/^---$/p')
  if ! printf '%s\n' "$_fm" | grep -q '^---$'; then
    bad "$c.md: frontmatter never closes with ---"
    continue
  fi
  if ! printf '%s\n' "$_fm" | grep -qE '^description:[[:space:]]*[^[:space:]]'; then
    bad "$c.md: frontmatter has no non-empty description:"
    continue
  fi
  ok "$c.md frontmatter"
done

# ---------------------------------------------------------------------------
# 2. Every command references a section that actually exists in SKILL.md.
#    Commands delegate with the phrase: follow its `X` section.
# ---------------------------------------------------------------------------
if [ ! -f "$SKILL" ]; then
  bad "SKILL.md missing: $SKILL"
else
  for c in $COMMANDS; do
    f="$PLUGIN/commands/$c.md"
    [ -f "$f" ] || continue
    _sec=$(grep -oE 'follow its `[a-z]+` section' "$f" | head -1 \
           | sed 's/follow its `//; s/` section//')
    if [ -z "$_sec" ]; then
      bad "$c.md: does not reference a skill section (expected: follow its \`X\` section)"
      continue
    fi
    if grep -qE "^## \`$_sec( |\`)" "$SKILL"; then
      ok "$c.md -> SKILL.md section \`$_sec\`"
    else
      bad "$c.md references skill section \`$_sec\` which SKILL.md does not define"
    fi
  done
fi

# ---------------------------------------------------------------------------
# 3. Every `cfg <key>` the supervisor reads is declared in defaults.json, so
#    defaults.json stays a truthful schema of the config surface. This is the
#    check that would have caught PKG-3 (plan_path/allow_domains/keep_sessions/
#    keep_days read by cfg() but absent from defaults.json).
# ---------------------------------------------------------------------------
if [ ! -f "$SUPERVISOR" ] || [ ! -f "$DEFAULTS" ]; then
  bad "supervisor or defaults.json missing"
else
  if ! jq -e 'type == "object"' "$DEFAULTS" >/dev/null 2>&1; then
    bad "defaults.json is not a JSON object"
  else
    _keys=$(grep -oE '\bcfg [a-z_]+' "$SUPERVISOR" | sed 's/^cfg //' | sort -u)
    if [ -z "$_keys" ]; then
      bad "found no cfg reads in relay-supervisor.sh (extraction broken?)"
    fi
    _missing=""
    for k in $_keys; do
      if ! jq -e --arg k "$k" 'has($k)' "$DEFAULTS" | grep -qx true; then
        _missing="$_missing $k"
      fi
    done
    if [ -n "$_missing" ]; then
      bad "cfg keys read by the supervisor but absent from defaults.json:$_missing"
    else
      ok "all $(printf '%s\n' "$_keys" | wc -l | tr -d ' ') cfg keys declared in defaults.json"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 4. plugin.json and marketplace.json agree on name and version.
# ---------------------------------------------------------------------------
if [ ! -f "$PLUGIN_JSON" ] || [ ! -f "$MARKET_JSON" ]; then
  bad "plugin.json or marketplace.json missing"
else
  _pn=$(jq -r '.name // empty' "$PLUGIN_JSON" 2>/dev/null)
  _pv=$(jq -r '.version // empty' "$PLUGIN_JSON" 2>/dev/null)
  if [ -z "$_pn" ] || [ -z "$_pv" ]; then
    bad "plugin.json has no usable name/version"
  else
    _mv=$(jq -r --arg n "$_pn" \
          '.plugins[]? | select(.name == $n) | .version // empty' "$MARKET_JSON" 2>/dev/null)
    if [ -z "$_mv" ]; then
      bad "marketplace.json lists no plugin named $_pn"
    elif [ "$_mv" != "$_pv" ]; then
      bad "version drift: plugin.json $_pv vs marketplace.json $_mv"
    else
      ok "manifests agree: $_pn $_pv"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 5. SKILL.md must carry the plugin-root resolver every command depends on
#    (PKG-1): without it, an unset CLAUDE_PLUGIN_ROOT makes `run` fail
#    invisibly inside nohup.
# ---------------------------------------------------------------------------
if [ -f "$SKILL" ]; then
  if grep -q '^## Resolve the plugin root' "$SKILL" \
     && grep -q 'RELAY_ROOT="\${CLAUDE_PLUGIN_ROOT:-}"' "$SKILL"; then
    ok "SKILL.md carries the plugin-root resolver"
  else
    bad "SKILL.md is missing the 'Resolve the plugin root' section or its snippet"
  fi
  # Flag actual invocation lines only — the resolver section legitimately
  # MENTIONS the bare form in prose while explaining why it is forbidden.
  if grep -qE '^[[:space:]]*(nohup[[:space:]]+)?bash[[:space:]]+"\$\{?CLAUDE_PLUGIN_ROOT' "$SKILL"; then
    bad "SKILL.md still invokes scripts through a bare CLAUDE_PLUGIN_ROOT expansion"
  else
    ok "no bare CLAUDE_PLUGIN_ROOT script invocations in SKILL.md"
  fi
fi

if [ "$FAIL" -eq 0 ]; then
  printf 'plugin-layer: clean\n'
fi
exit "$FAIL"
