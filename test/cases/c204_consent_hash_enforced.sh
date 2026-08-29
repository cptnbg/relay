# PKG-5 regression: SECURITY.md promises that changing the consent terms
# invalidates recorded consent. The mechanism is doctor recomputing the hash of
# the consent notice in the installed SKILL.md and hard-failing when
# config.json's consent.notice_hash is absent or different. Before this
# existed, a run started happily with no recorded consent at all.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE/work"
mkrunmd "$STATE"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"

# 1. NO recorded consent: the supervisor must refuse at preflight via doctor.
cat > "$STATE/config.json" <<'EOF'
{"max_sessions":3}
EOF

export RELAY_SKIP_PROBE=1
export RELAY_ALLOW_DIRTY=1
export RELAY_MOCK_SCRIPT="complete"

bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

assert_rc 78 "$RC" "c204_absent_consent_refused"
assert_grep "$PWD/err.log" 'no recorded consent' "c204_absent_consent_message"
assert_grep "$STATE/journal.log" 'preflight\.failed' "c204_preflight_journal"
assert_no_grep "$STATE/journal.log" 'session\.start' "c204_no_session_started"

# 2. STALE consent (recorded against different notice text): doctor must
#    hard-fail with the re-consent remedy.
STATE2="$PWD/state2"
mkdir -p "$STATE2/work"
mkrunmd "$STATE2"
jq -n '{max_sessions: 3,
        consent: {accepted_at: "1970-01-01T00:00:00Z",
                  notice_hash: "0000000000000000000000000000000000000000"}}' \
  > "$STATE2/config.json"

bash "$ROOT/plugins/relay/scripts/relay-doctor.sh" "$PROJ" "$STATE2" --allow-dirty \
  >"$PWD/doc.out" 2>"$PWD/doc.err"
RC2=$?
assert_rc 78 "$RC2" "c204_stale_consent_refused"
assert_grep "$PWD/doc.err" 'consent notice has changed' "c204_stale_consent_message"
assert_grep "$PWD/doc.err" 're-run /relay-init' "c204_stale_consent_remedy"

# 3. VALID consent (the canonical extraction) must pass the consent check.
STATE3="$PWD/state3"
mkdir -p "$STATE3/work"
mkrunmd "$STATE3"
printf '{"max_sessions":2}\n' > "$STATE3/config.json"
mkconsent "$STATE3"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE3" >"$PWD/out3.log" 2>"$PWD/err3.log"
RC3=$?
assert_rc 0 "$RC3" "c204_valid_consent_runs"

exit 0
