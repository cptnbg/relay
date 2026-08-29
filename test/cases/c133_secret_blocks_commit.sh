# test/cases/c133_secret_blocks_commit.sh — a file left in the working tree
# containing an Anthropic-shaped API key must make relay's own
# relay_git_commit refuse to commit at all. Exit 20, commit.secret-blocked
# journaled, and the secret must never land in git history.
#
# The key is assembled at runtime from two pieces plus a random body so no
# literal contiguous key-shaped string ever appears in this source file.
PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"

mkdir -p "$STATE"
mkrunmd "$STATE"
printf '# Plan\n\n1. step one\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com commit -q -m "chore: add plan.md" >/dev/null 2>&1

cat > "$STATE/config.json" <<'EOF'
{"max_sessions":6}
EOF

_secret_prefix="sk-ant"
_secret_body=$(head -c 512 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 40)
SECRET="${_secret_prefix}-${_secret_body}"

# Left untracked and uncommitted on purpose: this is what the doctor's
# dirty-tree check would normally hard-fail on, so we explicitly acknowledge
# it via RELAY_ALLOW_DIRTY. The point of this test is what happens AFTER
# doctor passes, when relay's own commit step scans the tree.
printf 'DEPLOY_TOKEN=%s\n' "$SECRET" > "$PROJ/leftover-notes.txt"

export RELAY_SKIP_PROBE=1
export RELAY_ALLOW_DIRTY=1
export RELAY_MOCK_SCRIPT="noop"

mkconsent "$STATE"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
RC=$?

JOURNAL="$STATE/journal.log"

assert_rc 20 "$RC" "c133_rc"
assert_grep "$JOURNAL" 'commit\.secret-blocked' "c133_secret_blocked_journaled"

git -C "$PROJ" log --all -p > "$PWD/gitlog.txt" 2>/dev/null
assert_no_grep "$PWD/gitlog.txt" "$SECRET" "c133_secret_never_entered_history"

STATUS=$(git -C "$PROJ" status --porcelain)
assert_contains "$STATUS" "leftover-notes.txt" "c133_secret_file_still_uncommitted"

exit 0
