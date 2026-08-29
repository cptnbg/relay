# c235 — flipping sandbox_mode must force a fresh acceptance proof. The probe
# cache is keyed by (payload + CLI version), and the mode changes the payload,
# so a run that switches modes can never inherit the previous mode's proof.
# Without this, a project could be proven sandboxed and then run unsandboxed on
# that stale evidence.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
mkrunmd "$STATE"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

# --- run 1: enforced, healthy sandbox -------------------------------------
printf '{"max_sessions":2,"sandbox_mode":"enforced"}\n' > "$STATE/config.json"
mkconsent "$STATE"

export RELAY_MOCK_PROBE=blocked
export RELAY_MOCK_SCRIPT="work"

bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out1.log" 2>"$PWD/err1.log"

JOURNAL="$STATE/journal.log"
assert_file "$STATE/run/probe.ok" "c235_enforced_probe_cached"
FP_ENFORCED=$(tr -d '\n' < "$STATE/run/probe.ok")
assert_grep "$RELAY_MOCK_DIR/probe.log" 'probe mode=blocked' "c235_enforced_probe_served"

# --- run 2: same project, flipped to disabled ------------------------------
# The mock's invocation counter is a file that outlives run 1, and it is what
# picks the behaviour out of RELAY_MOCK_SCRIPT — reset it so run 2 starts at
# the first entry rather than silently running the wrong behaviour.
rm -f "$RELAY_MOCK_DIR/invocation_count"
printf '{"max_sessions":4,"sandbox_mode":"disabled"}\n' > "$STATE/config.json"
# Rewriting config.json dropped the consent block that lives in it; doctor hard-
# fails without it, so re-record it exactly as /relay-init would.
mkconsent "$STATE"

export RELAY_MOCK_PROBE=open
export RELAY_MOCK_SCRIPT="work,complete"

bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out2.log" 2>"$PWD/err2.log"
RC2=$?

assert_rc 0 "$RC2" "c235_disabled_run_completed"

# The proof was re-taken, not inherited: the disabled probe really ran...
assert_grep "$RELAY_MOCK_DIR/probe.log" 'probe mode=open' "c235_disabled_probe_served"
assert_grep "$JOURNAL" 'probe\.hook.fired' "c235_disabled_hook_proof"
# ...and the enforced run's cached proof was discarded on entry rather than
# inherited. Asserting absence here is deliberate: reading probe.ok and
# comparing fingerprints would pass trivially once the file stops existing
# (`tr` on a missing file yields the empty string, which differs from anything),
# so the test would keep passing while proving nothing.
assert_no_file "$STATE/run/probe.ok" "c235_enforced_cache_discarded_by_trust_run"
assert_grep "$JOURNAL" 'probe\.cache-discarded' "c235_discard_journaled"
[ -n "$FP_ENFORCED" ] || _assert_fail "c235_enforced_fp_was_cached: run 1 cached nothing"

# Two probe.start lines: one per mode. A cache hit would have skipped the second.
STARTS=$(grep -c 'probe\.start' "$JOURNAL")
assert_eq "2" "$STARTS" "c235_probed_once_per_mode"

# The mock's invocation counter is a FILE that outlives run 1, and it is what
# selects the behaviour from RELAY_MOCK_SCRIPT. Pin the actions log so the reset
# above is load-bearing: without it run 2 starts at entry 2 ("complete") and
# this assertion fails, instead of the test passing while silently exercising
# the wrong behaviour.
# Line 3 is run 2's first session. With the reset it reads "1 work" (counter
# restarted, so behaviour 1 of "work,complete"); without it, invocation 3 falls
# off the end of the script, the last entry repeats, and it reads "3 complete".
assert_eq "1 work" "$(sed -n 3p "$RELAY_MOCK_DIR/actions")" "c235_run2_started_at_first_behaviour"

exit 0
