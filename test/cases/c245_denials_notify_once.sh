PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com \
  commit -q -m "chore: add plan.md" >/dev/null 2>&1
mkdir -p "$STATE/work"
mkrunmd "$STATE"

# The >=3-denials notification fires ONCE per supervisor invocation, however
# many denial-heavy sessions follow — a phone that buzzes every session gets
# silenced, which is worse than one honest buzz.
printf '{"max_sessions":6}\n' > "$STATE/config.json"
mkconsent "$STATE"
export RELAY_SKIP_PROBE=1
export RELAY_MOCK_DENIALS="A,B,C"
export RELAY_MOCK_SCRIPT="work,work,work,complete"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
assert_rc 0 "$?" "c245_completed"
assert_eq "4" "$(grep -c 'session.denials' "$STATE/journal.log")" "c245_every_session_journaled"
assert_eq "1" "$(grep -c 'denials.notified' "$STATE/journal.log")" "c245_notified_exactly_once"
exit 0
