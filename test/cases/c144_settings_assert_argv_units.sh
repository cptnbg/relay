# c144 — relay_settings_assert_argv unit tests. Until now only the positive
# path was exercised (by supervisor runs that pass the assertion); if the
# case statement degraded to matching nothing, the suite stayed green. Each
# forbidden flag must veto (rc 1) even when the required flags are present,
# each missing required flag must veto, and only the complete, clean argv
# passes.
. "$ROOT/plugins/relay/scripts/lib/relay-lib.sh"
. "$ROOT/plugins/relay/scripts/relay-settings.sh"

a() { # expected_rc label argv...
  local expected="$1" label="$2" rc
  shift 2
  relay_settings_assert_argv "$@" 2>/dev/null
  rc=$?
  assert_rc "$expected" "$rc" "$label"
}

# The exact argv shape the supervisor asserts before each spawn.
a 0 "c144_clean_argv_passes" -p --setting-sources user --strict-mcp-config

# Each forbidden flag, with both required flags present, anywhere in argv.
a 1 "c144_dangerously_skip_permissions_vetoed" \
  -p --setting-sources user --strict-mcp-config --dangerously-skip-permissions
a 1 "c144_bare_vetoed" \
  -p --bare --setting-sources user --strict-mcp-config
a 1 "c144_no_session_persistence_vetoed" \
  -p --setting-sources user --no-session-persistence --strict-mcp-config
a 1 "c144_safe_mode_vetoed" \
  --safe-mode -p --setting-sources user --strict-mcp-config

# Each required flag missing.
a 1 "c144_missing_setting_sources_vetoed" -p --strict-mcp-config
a 1 "c144_missing_strict_mcp_config_vetoed" -p --setting-sources user

# The degenerate argv: if the case statement matched nothing at all, this is
# the call that would sail through.
a 1 "c144_empty_argv_vetoed"
a 1 "c144_unrelated_argv_vetoed" -p some-prompt --model opus

exit 0
