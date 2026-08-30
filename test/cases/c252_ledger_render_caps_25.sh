PROJ="$PWD/proj"
STATE="$PWD/state"
mkrepo "$PROJ"
printf '# Plan\n\n## Phase 1\n\nstep one\n\n## Phase 2\n\nstep two\n\n## Phase 3\n\nstep three\n\n## Phase 4\n\nstep four\n' > "$PROJ/plan.md"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" -c user.name=mock -c user.email=mock@example.com \
  commit -q -m "chore: add plan.md" >/dev/null 2>&1
mkdir -p "$STATE/work"
mkrunmd "$STATE"
export RELAY_SKIP_PROBE=1

# 28 sessions of history render as the LAST 25 rows plus an honest omission
# line — bounded prompt cost, unbounded run length.
printf '{"max_sessions":28,"budget_usd_total":900}\n' > "$STATE/config.json"
mkconsent "$STATE"
export RELAY_MOCK_SCRIPT="work"
bash "$ROOT/plugins/relay/scripts/relay-supervisor.sh" "$PROJ" "$STATE" >"$PWD/out.log" 2>"$PWD/err.log"
assert_rc 23 "$?" "c252_capped_at_28"
assert_eq "28" "$(grep -c '^| [0-9]' "$STATE/ledger.md")" "c252_all_rows_kept_on_disk"
# Extract the LAST rendered ledger block (prompts contain newlines, so the
# log cannot be split by line; take the final fence pair instead).
tr '\0' '\n' < "$RELAY_MOCK_DIR/argv.log" | awk '
  /<run-ledger>/ {buf=""; f=1}
  f {buf = buf $0 "\n"}
  /<\/run-ledger>/ {f=0; last=buf}
  END {printf "%s", last}' > "$PWD/lastblock.txt"
assert_grep "$PWD/lastblock.txt" 'earlier sessions omitted' "c252_omission_line"
_rows=$(grep -c '^| [0-9]' "$PWD/lastblock.txt")
assert_eq "25" "$_rows" "c252_render_capped_at_25"
exit 0
