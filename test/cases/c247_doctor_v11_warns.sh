# Doctor's three v1.1 warnings, invoked directly (c211 style). All warns,
# never fails: each names a run that will FIGHT its configuration, not one
# that cannot start.
DOCTOR="$ROOT/plugins/relay/scripts/relay-doctor.sh"
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"
mkdir -p "$STATE/work"
mkrunmd "$STATE"
printf '{"max_sessions":2}\n' > "$STATE/config.json"
mkconsent "$STATE"

# 0. Healthy baseline: none of the three warnings fire.
bash "$DOCTOR" "$PROJ" "$STATE" >"$PWD/d0.out" 2>"$PWD/d0.err"
assert_rc 0 "$?" "c247_baseline_passes"
assert_no_grep "$PWD/d0.err" 'user-scope hook' "c247_baseline_no_hook_warn"
assert_no_grep "$PWD/d0.err" 'deny Write/Edit' "c247_baseline_no_denypath_warn"
assert_no_grep "$PWD/d0.err" 'budget_usd_per_session' "c247_baseline_no_budget_warn"

# 1. A user-scope PreToolUse hook is surfaced (harness HOME is sandboxed).
mkdir -p "$HOME/.claude/hooks"
cat > "$HOME/.claude/settings.json" <<'EOF'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"$HOME/.claude/hooks/guard.sh"}]}]}}
EOF
bash "$DOCTOR" "$PROJ" "$STATE" >"$PWD/d1.out" 2>"$PWD/d1.err"
assert_rc 0 "$?" "c247_hook_warn_is_not_fail"
assert_grep "$PWD/d1.err" 'user-scope hook runs INSIDE relay sessions' "c247_hook_warned"
assert_grep "$PWD/d1.err" 'guard.sh' "c247_hook_named"
rm -f "$HOME/.claude/settings.json"

# 2. A project under a deny-write dir: every Write tool call refused.
PROJ2="$HOME/.claude/proj2"
mkrepo "$PROJ2"
bash "$DOCTOR" "$PROJ2" "$STATE" >"$PWD/d2.out" 2>"$PWD/d2.err"
assert_grep "$PWD/d2.err" 'deny Write/Edit' "c247_denypath_warned"

# 3. Full-trust + opus + low per-session budget: handoff-less budget deaths.
printf '{"max_sessions":2,"sandbox_mode":"disabled","model_tier":"opus","budget_usd_per_session":2.00}\n' > "$STATE/config.json"
mkconsent "$STATE"
bash "$DOCTOR" "$PROJ" "$STATE" >"$PWD/d3.out" 2>"$PWD/d3.err"
assert_grep "$PWD/d3.err" 'budget_usd_per_session is 2.00' "c247_budget_warned"
printf '{"max_sessions":2,"sandbox_mode":"disabled","model_tier":"opus","budget_usd_per_session":5.00}\n' > "$STATE/config.json"
mkconsent "$STATE"
bash "$DOCTOR" "$PROJ" "$STATE" >"$PWD/d4.out" 2>"$PWD/d4.err"
assert_no_grep "$PWD/d4.err" 'budget_usd_per_session is' "c247_budget_ok_at_5"
printf '{"max_sessions":2,"sandbox_mode":"disabled","model_tier":"sonnet","budget_usd_per_session":2.00}\n' > "$STATE/config.json"
mkconsent "$STATE"
bash "$DOCTOR" "$PROJ" "$STATE" >"$PWD/d5.out" 2>"$PWD/d5.err"
assert_no_grep "$PWD/d5.err" 'budget_usd_per_session is' "c247_budget_opus_only"
exit 0
