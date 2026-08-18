# PKG-1 regression: CLAUDE_PLUGIN_ROOT is not guaranteed to be set in the
# Bash-tool environment, and a stale value is worse than an unset one — every
# skill-issued script invocation would resolve to a broken path, invisibly when
# detached. Doctor must report an unresolvable/unreal plugin root as a HARD
# failure, and must keep passing when the root is genuinely resolvable.
PROJ="$PWD/proj"
mkrepo "$PROJ"

# 1. CLAUDE_PLUGIN_ROOT set but pointing at something that is not a relay
#    install: hard failure (78). No STATE arg, so only root/toolchain/repo
#    checks run — isolating the failure to the plugin-root check.
mkdir -p "$PWD/not-a-plugin"
CLAUDE_PLUGIN_ROOT="$PWD/not-a-plugin" \
  bash "$ROOT/plugins/relay/scripts/relay-doctor.sh" "$PROJ" \
  >"$PWD/doc1.out" 2>"$PWD/doc1.err"
RC1=$?
assert_rc 78 "$RC1" "c210_stale_root_hard_fail"
assert_grep "$PWD/doc1.err" 'CLAUDE_PLUGIN_ROOT is set but is not a relay install' "c210_stale_root_message"

# 2. Unset CLAUDE_PLUGIN_ROOT with a healthy install (doctor running from the
#    real scripts dir): the self-derived root must pass, and doctor exit 0.
env -u CLAUDE_PLUGIN_ROOT \
  bash "$ROOT/plugins/relay/scripts/relay-doctor.sh" "$PROJ" \
  >"$PWD/doc2.out" 2>"$PWD/doc2.err"
RC2=$?
assert_rc 0 "$RC2" "c210_healthy_root_passes"
assert_grep "$PWD/doc2.out" 'plugin root:' "c210_root_reported"

# 3. A copy of doctor whose own directory lacks relay-supervisor.sh (a broken
#    install): hard failure regardless of env.
mkdir -p "$PWD/broken-install/scripts"
cp "$ROOT/plugins/relay/scripts/relay-doctor.sh" "$PWD/broken-install/scripts/"
cp "$ROOT/plugins/relay/scripts/relay-git.sh" "$PWD/broken-install/scripts/"
env -u CLAUDE_PLUGIN_ROOT \
  bash "$PWD/broken-install/scripts/relay-doctor.sh" "$PROJ" \
  >"$PWD/doc3.out" 2>"$PWD/doc3.err"
RC3=$?
assert_rc 78 "$RC3" "c210_broken_install_hard_fail"
assert_grep "$PWD/doc3.err" 'plugin root does not contain scripts/relay-supervisor.sh' "c210_broken_install_message"

exit 0
