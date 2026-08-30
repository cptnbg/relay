PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com \
  commit -q -m "chore: add plan.md" >/dev/null 2>&1
mkdir -p "$STATE/work"
mkrunmd "$STATE"

# max_wall_secs: the phantom knob the interview used to collect and discard,
# now real. Per-invocation, pre-spawn only, EX_CAPPED reused with a distinct
# reason (the EX_BUDGET precedent: one code, causes split by status+reason).
printf '{"max_sessions":9,"max_wall_secs":1}\n' > "$STATE/config.json"
mkconsent "$STATE"
export RELAY_SKIP_PROBE=1
export RELAY_MOCK_SCRIPT="work"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
assert_rc 23 "$?" "c246_exit_capped"
assert_grep "$STATE/journal.log" 'wallclock.reached' "c246_journaled"
assert_json "$STATE/state.json" '.status' "capped" "c246_status"
assert_json "$STATE/state.json" '.reason' "wall-clock" "c246_reason"

# Nothing persisted: zero the cap in config and the SAME state dir runs to
# completion — a persisted window would still refuse.
printf '{"max_sessions":9,"max_wall_secs":0}\n' > "$STATE/config.json"
mkconsent "$STATE"
rm -f "$RELAY_MOCK_DIR/invocation_count"
export RELAY_MOCK_SCRIPT="work,complete"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out2.log" 2>"$PWD/err2.log"
assert_rc 0 "$?" "c246_zero_means_off"
assert_eq "1" "$(grep -c 'wallclock.reached' "$STATE/journal.log")" "c246_no_second_cap_event"

# Non-numeric refuses through the existing numeric guard.
STATE2="$PWD/state2"
mkdir -p "$STATE2/work"
mkrunmd "$STATE2"
printf '{"max_sessions":2,"max_wall_secs":"soon"}\n' > "$STATE2/config.json"
mkconsent "$STATE2"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE2" >"$PWD/out3.log" 2>"$PWD/err3.log"
assert_rc 78 "$?" "c246_non_numeric_refused"
assert_grep "$STATE2/journal.log" 'config.non-numeric' "c246_numeric_guard"
assert_grep "$PWD/err3.log" 'max_wall_secs' "c246_named_in_error"
exit 0
