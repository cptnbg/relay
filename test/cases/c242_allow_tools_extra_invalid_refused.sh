PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com \
  commit -q -m "chore: add plan.md" >/dev/null 2>&1
mkdir -p "$STATE/work"
mkrunmd "$STATE"

# Fail closed on a malformed allow_tools_extra, in EVERY mode — a typo must
# refuse loudly, never ride along unread.
_try() { # name config-json
  _S="$PWD/state-$1"
  mkdir -p "$_S/work"
  mkrunmd "$_S"
  printf '%s\n' "$2" > "$_S/config.json"
  mkconsent "$_S"
  rm -f "$RELAY_MOCK_DIR/invocation_count"
  bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$_S" >"$PWD/$1.out" 2>"$PWD/$1.err"
  RC=$?
}
export RELAY_SKIP_PROBE=1
export RELAY_MOCK_SCRIPT="work,complete"

_try space '{"max_sessions":2,"sandbox_mode":"disabled","allow_tools_extra":"foo bar"}'
assert_rc 78 "$RC" "c242_space_refused"
assert_grep "$_S/journal.log" 'config.allow-tools-extra-invalid' "c242_space_journaled"

_try leadcomma '{"max_sessions":2,"sandbox_mode":"disabled","allow_tools_extra":",X"}'
assert_rc 78 "$RC" "c242_leading_comma_refused"

_try doublecomma '{"max_sessions":2,"sandbox_mode":"disabled","allow_tools_extra":"x,,y"}'
assert_rc 78 "$RC" "c242_double_comma_refused"

_try digit '{"max_sessions":2,"sandbox_mode":"disabled","allow_tools_extra":"9tool"}'
assert_rc 78 "$RC" "c242_digit_start_refused"
assert_grep "$_S/journal.log" 'config.allow-tools-extra-invalid' "c242_digit_journaled"

# Validated regardless of mode: enforced ignores the value but a broken one
# still refuses (same stance as allow_domains in disabled mode, c239).
_try enforcedbad '{"max_sessions":2,"sandbox_mode":"enforced","allow_tools_extra":"bad value"}'
assert_rc 78 "$RC" "c242_enforced_invalid_refused"
exit 0
