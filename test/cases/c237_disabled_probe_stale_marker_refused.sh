# c237 — a stale hook marker must never be mistaken for proof.
#
# Regression, and the nastiest kind: a FALSE PASS on the assertion that exists
# to catch a silently-dropped payload. `relay_settings_probe_disabled` proves
# the payload was accepted by requiring run/hook.alive to appear. That scratch
# lives under $STATE/work, which every session can write, and the `rm -rf` that
# cleared it did not check its exit status.
#
# So: a session plants the marker and chmods its parent 0555. `rm -rf` then
# fails (unlink needs write permission on the CONTAINING directory) while the
# following `mkdir -p` and `: >` both still return 0 — setup looks clean. The
# next probe reads the pre-planted marker, reports the payload proven accepted,
# caches probe.ok, and an unattended full-trust run starts with NO deny list and
# NO context guard.
#
# The mock is configured to `dropped` here: it writes NO marker of its own, so
# the only marker that could satisfy assertion (b) is the planted one. A run
# that reaches session 1 means the false pass is back.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
mkrunmd "$STATE"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":4,"sandbox_mode":"disabled"}
EOF

# Plant the marker exactly where the probe will look, then make its parent
# directory unremovable the way a hostile session would.
HOOKDIR="$STATE/work/probe/probe-hook"
mkdir -p "$HOOKDIR/run"
: > "$HOOKDIR/run/hook.alive"
chmod 555 "$HOOKDIR/run"

export RELAY_MOCK_PROBE=dropped
export RELAY_MOCK_SCRIPT="work,complete"

mkconsent "$STATE"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

# Restore write permission so the harness can clean up regardless of outcome.
chmod 755 "$HOOKDIR/run" 2>/dev/null

JOURNAL="$STATE/journal.log"

assert_rc 78 "$RC" "c237_refused"
assert_no_grep "$JOURNAL" 'probe\.ok' "c237_no_probe_ok"
assert_no_grep "$JOURNAL" 'session\.start' "c237_no_session_launched"
assert_no_file "$STATE/run/probe.ok" "c237_no_probe_cache_written"

# The refusal must be about the unclearable scratch, not a lucky downstream
# failure: the probe must never have reached its hook assertion at all.
assert_grep "$PWD/err.log" 'probe scratch could not be cleared' "c237_stderr_names_the_cause"
assert_no_grep "$JOURNAL" 'probe\.hook.fired' "c237_never_claimed_the_marker_as_proof"

exit 0
