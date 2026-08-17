# test/cases/c106_settings_payload_allows_work.sh — the settings payload must
# carry a permissions.allow list, and deny must still be present alongside it.
#
# Regression. `--permission-mode dontAsk` REFUSES anything not explicitly
# allowed (verified against the real CLI in test/lint/probe0-permission-mode.sh,
# case A). Relay shipped a deny-only payload, so its first real session could
# not write a file: the result envelope recorded a denied Write followed by a
# denied `cat > file` Bash fallback, and the session exhausted its budget having
# produced nothing.
#
# This case is structural — it asserts the payload's shape, which is all a
# zero-API-call suite can see. The behavioural proof lives in the probe, which
# also confirms deny still beats allow so the list below cannot quietly void the
# blast-radius layer.
# shellcheck source=/dev/null
. "$ROOT/plugins/relay/scripts/lib/relay-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/plugins/relay/scripts/relay-settings.sh"

PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"
mkdir -p "$STATE"

SETTINGS=$(relay_settings_build "$PROJ" "$STATE" "$ROOT/plugins/relay/hooks/relay-ctx.sh")
printf '%s' "$SETTINGS" > "$PWD/settings.json"

assert_json "$PWD/settings.json" '. | type' "object" "c106_valid_json"

# Every tool a build session cannot work without.
for t in Read Write Edit Bash Glob Grep Task; do
  assert_json "$PWD/settings.json" \
    "(.permissions.allow // []) | index(\"$t\") != null" "true" "c106_allows_$t"
done

# The deny list survived alongside it, including the write-denies that stop a
# session making itself persistent.
assert_json "$PWD/settings.json" \
  '(.permissions.deny // []) | index("Bash(sudo:*)") != null' "true" "c106_still_denies_sudo"
assert_json "$PWD/settings.json" \
  '(.permissions.deny // []) | index("Bash(git push:*)") != null' "true" "c106_still_denies_push"
assert_json "$PWD/settings.json" \
  '(.permissions.deny // []) | index("Write(~/.claude/**)") != null' "true" "c106_still_denies_claude_writes"

# Network egress and credential reads are untouched by the allow list.
assert_json "$PWD/settings.json" '.sandbox.enabled' "true" "c106_sandbox_on"
assert_json "$PWD/settings.json" '.sandbox.failIfUnavailable' "true" "c106_fail_if_unavailable"
assert_json "$PWD/settings.json" \
  '(.permissions.allow // []) | index("WebFetch")' "null" "c106_never_allows_webfetch"

# The session must be able to read RUN.md, which lives OUTSIDE the project.
assert_json "$PWD/settings.json" \
  "(.sandbox.filesystem.allowWrite // []) | index(\"$STATE\") != null" "true" "c106_state_writable"

exit 0
