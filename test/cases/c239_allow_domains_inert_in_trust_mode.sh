# c239 — `allow_domains` in full-trust mode: still validated, still journaled,
# but absent from the payload because there is no allowlist to extend.
#
# README states "allow_domains stops applying" in `disabled` mode; nothing
# verified it, and the interaction is easy to misread in both directions. The
# supervisor validates the value BEFORE it reads sandbox_mode, so a malformed
# list still refuses to start even though the value is unused — deliberate (a
# typo should not be silently ignored), but worth pinning so it is not "fixed"
# by accident.
#
# The journal line matters too: a full-trust run records
# `sandbox.extra-domains <list>`, which reads like an allowlist was extended
# when no allowlist exists. Read it as "configured", not "applied". Asserting it
# here keeps that wording honest.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
printf '# RUN\n\nMinimal run.\n' > "$STATE/RUN.md"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":4,"sandbox_mode":"disabled","allow_domains":"registry.npmjs.org,pypi.org"}
EOF

export RELAY_MOCK_PROBE=open
export RELAY_MOCK_SCRIPT="work,complete"

mkconsent "$STATE"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

JOURNAL="$STATE/journal.log"

assert_rc 0 "$RC" "c239_run_completed"
assert_grep "$JOURNAL" 'sandbox\.extra-domains' "c239_domains_journaled_as_configured"
assert_grep "$JOURNAL" 'sandbox\.mode.disabled' "c239_ran_in_trust_mode"

# The payload carries no network policy at all — not an allowlist containing
# these hosts, and not an empty one either.
assert_json "$RELAY_MOCK_DIR/flags-last.json" \
  '(.settings | fromjson | .sandbox | has("network"))' "false" "c239_no_network_key"
assert_json "$RELAY_MOCK_DIR/flags-last.json" \
  '(.settings | fromjson | .sandbox | keys == ["enabled"])' "true" "c239_sandbox_minimal"

# A malformed list is still a preflight refusal, even though the value is unused.
STATE2="$PWD/state2"
mkdir -p "$STATE2/work"
printf '{"max_sessions":2,"sandbox_mode":"disabled","allow_domains":"bad;;value"}\n' > "$STATE2/config.json"
mkconsent "$STATE2"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE2" >"$PWD/out2.log" 2>"$PWD/err2.log"
RC2=$?
assert_rc 78 "$RC2" "c239_malformed_still_refused"
assert_grep "$STATE2/journal.log" 'config\.allow-domains-invalid' "c239_malformed_journaled"

exit 0
