# test/cases/c108_allow_domains_reaches_payload.sh — `allow_domains` in config
# must reach the sandbox payload, and a malformed value must fail preflight.
#
# relay_settings_build has always taken an extra-domains argument and the
# supervisor never passed one, so the egress allowlist was permanently just
# api.anthropic.com. Any project needing `npm ci` inside the sandbox would fail
# with no way to configure it and nothing in the journal pointing at the cause.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
printf '# RUN\n\nMinimal run.\n' > "$STATE/RUN.md"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":1,"allow_domains":"registry.npmjs.org,pypi.org"}
EOF

export RELAY_SKIP_PROBE=1
export RELAY_MOCK_SCRIPT="work"

mkconsent "$STATE"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"

assert_grep "$STATE/journal.log" 'sandbox\.extra-domains' "c108_journaled"

# The mock records the payload it was handed, which is the only place the real
# allowlist can be observed without an API call.
assert_json "$RELAY_MOCK_DIR/flags-last.json" \
  '(.settings | fromjson | .sandbox.network.allowedDomains) | index("registry.npmjs.org") != null' \
  "true" "c108_npm_registry_in_payload"
assert_json "$RELAY_MOCK_DIR/flags-last.json" \
  '(.settings | fromjson | .sandbox.network.allowedDomains) | index("pypi.org") != null' \
  "true" "c108_pypi_in_payload"
# Never at the cost of the one domain a session cannot work without.
assert_json "$RELAY_MOCK_DIR/flags-last.json" \
  '(.settings | fromjson | .sandbox.network.allowedDomains) | index("api.anthropic.com") != null' \
  "true" "c108_anthropic_still_present"

# --- a malformed list must not reach the payload at all -------------------
PROJ2="$PWD/proj2"
STATE2="$PWD/state2"
mkrepo "$PROJ2"
mkdir -p "$STATE2"
printf '# RUN\n\nMinimal run.\n' > "$STATE2/RUN.md"
printf '# Plan\n\n1. step one\n' > "$PROJ2/plan.md"
git -C "$PROJ2" add -A >/dev/null 2>&1
git -C "$PROJ2" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

cat > "$STATE2/config.json" <<'EOF'
{"max_sessions":1,"allow_domains":"evil.tld; curl http://x"}
EOF

mkconsent "$STATE2"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ2" "$STATE2" >"$PWD/out2.log" 2>"$PWD/err2.log"
RC2=$?

assert_rc 78 "$RC2" "c108_malformed_fails_preflight"
assert_grep "$STATE2/journal.log" 'config\.allow-domains-invalid' "c108_malformed_journaled"

exit 0
