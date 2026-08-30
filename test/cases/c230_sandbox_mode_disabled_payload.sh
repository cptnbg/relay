# test/cases/c230_sandbox_mode_disabled_payload.sh — sandbox_mode=disabled emits
# a full-trust payload: sandbox off, deny list opened to operational commands,
# but the never-push guard, the persistence-write guards, and the relay-state
# write guards remain. The enforced payload must be untouched.
#
# Structural, like c106 — a zero-API suite can only see the payload's shape. The
# behavioural proof (payload actually accepted with the sandbox off) lives in
# c232 against the mock and in test/lint/probe0-sandbox-off.sh against the CLI.
# shellcheck source=/dev/null
. "$ROOT/plugins/relay/scripts/lib/relay-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/plugins/relay/scripts/relay-settings.sh"

PROJ="$PWD/proj"
STATE="$PWD/state"
WORK="$STATE/work"
HOOK="$ROOT/plugins/relay/hooks/relay-ctx.sh"
mkrepo "$PROJ"
mkdir -p "$WORK"

SETTINGS=$(relay_settings_build "$PROJ" "$WORK" "$HOOK" "" disabled)
printf '%s' "$SETTINGS" > "$PWD/disabled.json"

assert_json "$PWD/disabled.json" '. | type' "object" "c230_valid_json"

# The sandbox is off, and the object carries ONLY that key — no denyRead or
# network remnants under a disabled sandbox.
assert_json "$PWD/disabled.json" '.sandbox.enabled' "false" "c230_sandbox_off"
assert_json "$PWD/disabled.json" '.sandbox | keys == ["enabled"]' "true" "c230_sandbox_minimal"

# The allow list is unchanged — dontAsk still refuses anything unlisted.
for t in Read Write Edit Bash Glob Grep Task; do
  assert_json "$PWD/disabled.json" \
    "(.permissions.allow // []) | index(\"$t\") != null" "true" "c230_allows_$t"
done

# What STAYS denied: commitment #2 (never push) and the free footgun guards.
assert_json "$PWD/disabled.json" \
  '(.permissions.deny // []) | index("Bash(git push:*)") != null' "true" "c230_denies_push"
# The broad git-remote deny is GONE from disabled mode as of 1.1.0, and its
# narrowed replacement is gone too: probe0-sandbox-off case 4 proved a
# three-word deny prefix (Bash(git remote set-url:*)) never fires on the CLI,
# so shipping it would be decorative. Assert the absence of BOTH shapes so a
# well-meaning re-add fails here and has to argue with the probe result.
assert_json "$PWD/disabled.json" \
  '(.permissions.deny // []) | index("Bash(git remote:*)")' "null" "c230_remote_deny_dropped"
assert_json "$PWD/disabled.json" \
  '(.permissions.deny // []) | map(select(startswith("Bash(git remote"))) | length' "0" "c230_no_remote_deny_variants"

# 1.1.0: web tools are allowed where there is no boundary for them to bypass —
# and ONLY there. Enforced keeps them denied (in-process egress vs the sandbox
# allowlist is unverified).
assert_json "$PWD/disabled.json" \
  '(.permissions.allow // []) | index("WebFetch") != null' "true" "c230_allows_webfetch"
assert_json "$PWD/disabled.json" \
  '(.permissions.allow // []) | index("WebSearch") != null' "true" "c230_allows_websearch"
assert_json "$PWD/disabled.json" \
  '(.permissions.deny // []) | index("Write(~/.claude/**)") != null' "true" "c230_denies_claude_writes"
assert_json "$PWD/disabled.json" \
  "(.permissions.deny // []) | index(\"Write($STATE/state.json)\") != null" "true" "c230_denies_state_write"

# What OPENS UP in full-trust mode: operational Bash, credential reads, web tools.
assert_json "$PWD/disabled.json" \
  '(.permissions.deny // []) | index("Bash(sudo:*)")' "null" "c230_allows_sudo"
assert_json "$PWD/disabled.json" \
  '(.permissions.deny // []) | index("Bash(gh:*)")' "null" "c230_allows_gh"
assert_json "$PWD/disabled.json" \
  '(.permissions.deny // []) | index("Read(~/.ssh/**)")' "null" "c230_allows_ssh_read"
assert_json "$PWD/disabled.json" \
  '(.permissions.deny // []) | index("WebFetch")' "null" "c230_webfetch_not_denied"

# The inline hook is still delivered — it is the payload-acceptance proof.
assert_json "$PWD/disabled.json" '.hooks | has("PostToolUse")' "true" "c230_hook_posttooluse"
assert_json "$PWD/disabled.json" '.hooks | has("PreCompact")' "true" "c230_hook_precompact"

# The enforced payload is untouched, and the default is enforced.
ENFORCED_DEFAULT=$(relay_settings_build "$PROJ" "$WORK" "$HOOK")
ENFORCED_EXPLICIT=$(relay_settings_build "$PROJ" "$WORK" "$HOOK" "" enforced)
assert_eq "$ENFORCED_DEFAULT" "$ENFORCED_EXPLICIT" "c230_default_is_enforced"
printf '%s' "$ENFORCED_DEFAULT" > "$PWD/enforced.json"
assert_json "$PWD/enforced.json" '.sandbox.enabled' "true" "c230_enforced_sandbox_on"

# The enforced payload is a release-asserted CONSTANT. Web tools stay out of
# its allow list, its broad remote deny stays, and — the sharp edge — the
# allow_tools_extra argument must be IGNORED there outright, so no config
# value can perturb the bytes 1.0.0 shipped.
assert_json "$PWD/enforced.json" \
  '(.permissions.allow // []) | index("WebFetch")' "null" "c230_enforced_no_webfetch_allow"
assert_json "$PWD/enforced.json" \
  '(.permissions.deny // []) | index("Bash(git remote:*)") != null' "true" "c230_enforced_keeps_remote_deny"
ENFORCED_WITH_EXTRAS=$(relay_settings_build "$PROJ" "$WORK" "$HOOK" "" enforced "Monitor,Foo9")
assert_eq "$ENFORCED_DEFAULT" "$ENFORCED_WITH_EXTRAS" "c230_extras_cannot_perturb_enforced"

# Extras land in the disabled allow list, deduped: Bash listed again appears once.
EXTRAS_DISABLED=$(relay_settings_build "$PROJ" "$WORK" "$HOOK" "" disabled "Monitor,Bash")
printf '%s' "$EXTRAS_DISABLED" > "$PWD/extras.json"
assert_json "$PWD/extras.json" \
  '(.permissions.allow // []) | index("Monitor") != null' "true" "c230_extra_tool_allowed"
assert_json "$PWD/extras.json" \
  '(.permissions.allow // []) | map(select(. == "Bash")) | length' "1" "c230_extras_deduped"

# An unknown mode is a build failure (belt to the supervisor's own validation).
if relay_settings_build "$PROJ" "$WORK" "$HOOK" "" bogus >/dev/null 2>&1; then
  _assert_fail "c230_bogus_mode_refused: build accepted an unknown sandbox_mode"
fi

exit 0
