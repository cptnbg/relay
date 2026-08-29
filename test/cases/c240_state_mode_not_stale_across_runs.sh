# state.json's `sandbox_mode` and `reason` describe ONE invocation, and
# `state_set` merges rather than replaces — so left alone they survive into runs
# they say nothing true about.
#
# The observed shape: a project runs once in full trust, the operator sets it
# back to `enforced` for safety, and the next start fails preflight. Nothing
# rewrote sandbox_mode on that path, so state.json still said "disabled" and
# /relay-status announced "FULL-TRUST MODE — the sandbox is OFF" for an enforced
# project that was not even running. Over-warning rather than under-warning, but
# a status line nobody can trust in the safe direction stops being read in the
# dangerous one.
#
# The same applies to `reason`: a `blocked`/`guardrail-drift` from last week must
# not be attached to this week's preflight failure.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com \
  commit -q -m "chore: add plan.md" >/dev/null 2>&1

mkdir -p "$STATE/work"
mkrunmd "$STATE"

# --- run 1: full trust, completes. state.json records the mode it ran in.
# mkconsent AFTER the config write, every time: it edits config.json in place,
# and writing the file afterwards wipes the consent the doctor gate requires.
printf '{"max_sessions":2,"sandbox_mode":"disabled"}\n' > "$STATE/config.json"
mkconsent "$STATE"
export RELAY_MOCK_PROBE=open
export RELAY_MOCK_SCRIPT="work,complete"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out1.log" 2>"$PWD/err1.log"
assert_rc 0 "$?" "c240_trust_run_completed"
assert_json "$STATE/state.json" '.sandbox_mode' "disabled" "c240_mode_recorded"

# Plant a reason too, exactly as a blocked run would have left one.
jq '.reason = "guardrail-drift"' "$STATE/state.json" > "$STATE/state.json.tmp" \
  && mv "$STATE/state.json.tmp" "$STATE/state.json"

# --- run 2: back to enforced, and it fails preflight before reaching the loop.
# A plan_path that does not resolve is the cheapest way to fail after the lock
# and before anything else writes state.
printf '{"max_sessions":2,"sandbox_mode":"enforced","plan_path":"nope.md"}\n' > "$STATE/config.json"
mkconsent "$STATE"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out2.log" 2>"$PWD/err2.log"
assert_rc 78 "$?" "c240_second_run_refused"

# The whole point: /relay-status must not announce full trust for this. The
# recorded value is what THIS invocation was configured with, not an empty
# placeholder — a preflight refusal still answers "what is this project set to".
assert_json "$STATE/state.json" '.sandbox_mode' "enforced" "c240_mode_follows_config_on_preflight_failure"
assert_json "$STATE/state.json" '.reason' "" "c240_stale_reason_cleared"
assert_json "$STATE/state.json" '(.sandbox_mode // "") == "disabled"' "false" "c240_status_would_not_warn"

# --- run 3: a run that gets all the way through records the validated mode, not
# just the configured string. Fresh project and state dir: reusing the first
# run's would carry its `commits_at_start` forward, and verify_complete would
# then reject a perfectly good COMPLETE for adding no commits — a different
# behaviour, tested elsewhere, and noise here.
PROJ2="$PWD/proj2"
STATE2="$PWD/state2"
mkrepo "$PROJ2"
printf '# Plan\n\n1. step one\n' > "$PROJ2/plan.md"
git -C "$PROJ2" add -A >/dev/null 2>&1
git -C "$PROJ2" -c user.name=mock -c user.email=mock@example.com \
  commit -q -m "chore: add plan.md" >/dev/null 2>&1
mkdir -p "$STATE2/work"
mkrunmd "$STATE2"
printf '{"max_sessions":2,"sandbox_mode":"enforced"}\n' > "$STATE2/config.json"
mkconsent "$STATE2"
unset RELAY_MOCK_PROBE
export RELAY_SKIP_PROBE=1
# The mock's invocation counter is a FILE that outlives a run; reset it so this
# supervisor replays the script from the top.
rm -f "$RELAY_MOCK_DIR/invocation_count"
export RELAY_MOCK_SCRIPT="work,complete"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ2" "$STATE2" >"$PWD/out3.log" 2>"$PWD/err3.log"
assert_rc 0 "$?" "c240_enforced_run_completed"
assert_json "$STATE2/state.json" '.sandbox_mode' "enforced" "c240_enforced_recorded"

exit 0
