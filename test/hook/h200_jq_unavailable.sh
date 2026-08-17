# test/hook/h200_jq_unavailable.sh — jq is not resolvable on PATH: the
# hook's `command -v jq || exit 0` guard must catch this cleanly, no crash.
# A minimal PATH is built containing symlinks to the real bash/date/wc/
# tail/sed/mv/mkdir binaries but deliberately omitting jq, so the hook
# runs its normal flow up to the jq check rather than failing on something
# unrelated.
HOOK="$ROOT/plugins/relay/hooks/relay-ctx.sh"
SID="11111111-2222-3333-4444-555555555555"

RELAY_DIR="$PWD/relay-dir"
mkdir -p "$RELAY_DIR"
printf '{}' > "$RELAY_DIR/state.json"

TRANSCRIPT="$PWD/transcript.jsonl"
mktranscript "$TRANSCRIPT" 65

PAYLOAD_FILE="$PWD/payload.json"
jq -nc --arg sid "$SID" --arg tp "$TRANSCRIPT" \
  '{session_id:$sid, transcript_path:$tp}' > "$PAYLOAD_FILE"

NOBIN="$PWD/nobin"
mkdir -p "$NOBIN"
for t in bash date wc tail sed mv mkdir; do
  src="$(command -v "$t" 2>/dev/null)"
  [ -n "$src" ] && ln -s "$src" "$NOBIN/$t"
done

# The guard must run in a SUBSHELL with the hash table cleared. `command -v` is
# a bash builtin that consults the shell's remembered command locations, so an
# inline `PATH=... command -v jq` still reports the cached /opt/homebrew/bin/jq
# in any shell that has already run jq once. That made this test pass or fail
# depending on the invoking shell's history — the worst kind of test.
# The hook invocation below is unaffected either way: it execs a fresh bash with
# PATH in its environment, which inherits no hash table.
if ( PATH="$NOBIN"; hash -r 2>/dev/null; command -v jq >/dev/null 2>&1 ); then
  _assert_fail "h200: setup broken -- jq is still resolvable on the trimmed PATH"
fi

OUT_FILE="$PWD/out.json"
PATH="$NOBIN" RELAY_SESSION_ID="$SID" RELAY_DIR="$RELAY_DIR" \
  bash "$HOOK" < "$PAYLOAD_FILE" > "$OUT_FILE" 2>"$PWD/err.log"
RC=$?

assert_rc 0 "$RC" "h200_rc"
assert_eq "" "$(cat "$OUT_FILE" 2>/dev/null)" "h200_stdout_empty"
assert_stdout_json_only "$OUT_FILE" "h200_stdout_json_only"

exit 0
