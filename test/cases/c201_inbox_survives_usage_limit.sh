# test/cases/c201_inbox_survives_usage_limit.sh — an operator note must not be
# destroyed when the session that would have read it hits a usage limit.
#
# The inbox is consumed (INBOX.md -> run/inbox-current.md, INBOX.md truncated)
# at the top of every iteration. If that session then trips a usage limit, the
# loop does `N=$((N-1)); continue`, and the NEXT iteration used to truncate
# run/inbox-current.md before any session acted on it — silently losing the one
# steering instruction the user sent from their phone. Relay now prepends the
# un-acted note back to INBOX.md on a retry, so the next real session sees it.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
printf '# RUN\n\nMinimal run.\n' > "$STATE/RUN.md"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":8,"on_limit":"wait","max_usage_retries":20}
EOF

# A note is waiting when the first (usage-limited) session starts.
printf 'focus on the auth module next\n' > "$STATE/INBOX.md"

export RELAY_SKIP_PROBE=1
export RELAY_BACKOFF_BASE=1
# First invocation hits a usage limit (consuming the inbox), then real work.
export RELAY_MOCK_SCRIPT="usagelimit,work,complete"

mkconsent "$STATE"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

JOURNAL="$STATE/journal.log"
assert_rc 0 "$RC" "c201_rc"
assert_grep "$JOURNAL" 'inbox\.preserved-on-retry' "c201_note_preserved_journaled"
# The note reached a real session's prompt: the mock records every prompt in
# argv.log, and the operator-note block is rendered into it.
assert_grep "$RELAY_MOCK_DIR/argv.log" 'focus on the auth module next' "c201_note_reached_a_session"

exit 0
