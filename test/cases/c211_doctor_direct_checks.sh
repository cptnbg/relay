# c211 — relay-doctor.sh checks driven directly, one refusal at a time:
#   1. detached HEAD                     -> hard fail
#   2. state dir inside the repository   -> hard fail
#   3. version gate boundaries (_verge): 2.19.9 < 2.20 fails, 2.53.0 >= 2.20
#      passes (the classic string-compare bug would order 2.53.0 < 2.20)
#   4. a required tool resolving INSIDE the project tree -> hard fail
DOCTOR="$ROOT/plugins/relay/scripts/relay-doctor.sh"
PROJ="$PWD/proj"
mkrepo "$PROJ"

# --- 0. healthy baseline: this doctor invocation must pass, or every
# refusal below is meaningless.
bash "$DOCTOR" "$PROJ" >"$PWD/doc0.out" 2>"$PWD/doc0.err"
assert_rc 0 "$?" "c211_healthy_baseline_passes"

# --- 1. detached HEAD.
git -C "$PROJ" checkout -q --detach
bash "$DOCTOR" "$PROJ" >"$PWD/doc1.out" 2>"$PWD/doc1.err"
RC1=$?
assert_rc 78 "$RC1" "c211_detached_head_hard_fail"
assert_grep "$PWD/doc1.err" 'HEAD is detached' "c211_detached_head_message"
git -C "$PROJ" checkout -q - 2>/dev/null || git -C "$PROJ" checkout -q main 2>/dev/null || git -C "$PROJ" checkout -q master

# --- 2. state dir inside the repository.
bash "$DOCTOR" "$PROJ" "$PROJ/state" >"$PWD/doc2.out" 2>"$PWD/doc2.err"
RC2=$?
assert_rc 78 "$RC2" "c211_state_in_repo_hard_fail"
assert_grep "$PWD/doc2.err" 'state dir is inside the repository' "c211_state_in_repo_message"
rm -rf "$PROJ/state"

# --- 3a. _verge boundary: git reporting 2.19.9 is below the required 2.20.
REAL_GIT=$(command -v git)
mkdir -p "$PWD/fakebin19"
cat > "$PWD/fakebin19/git" <<FAKE19
#!/bin/bash
if [ "\${1:-}" = "--version" ]; then printf 'git version 2.19.9\n'; exit 0; fi
exec "$REAL_GIT" "\$@"
FAKE19
chmod +x "$PWD/fakebin19/git"
PATH="$PWD/fakebin19:$PATH" bash "$DOCTOR" "$PROJ" >"$PWD/doc3.out" 2>"$PWD/doc3.err"
RC3=$?
assert_rc 78 "$RC3" "c211_git_2_19_9_hard_fail"
assert_grep "$PWD/doc3.err" 'git 2.19.9 is older than the required 2.20' "c211_verge_below_message"

# --- 3b. _verge boundary: 2.53.0 >= 2.20 must pass. A lexical compare would
# sort "2.53.0" before "2.20" is false here but DOES break for two-digit
# minors elsewhere; the numeric field sort is what this pins.
mkdir -p "$PWD/fakebin53"
cat > "$PWD/fakebin53/git" <<FAKE53
#!/bin/bash
if [ "\${1:-}" = "--version" ]; then printf 'git version 2.53.0\n'; exit 0; fi
exec "$REAL_GIT" "\$@"
FAKE53
chmod +x "$PWD/fakebin53/git"
PATH="$PWD/fakebin53:$PATH" bash "$DOCTOR" "$PROJ" >"$PWD/doc4.out" 2>"$PWD/doc4.err"
RC4=$?
assert_rc 0 "$RC4" "c211_git_2_53_0_passes"
assert_grep "$PWD/doc4.out" 'git 2.53.0' "c211_verge_at_or_above_ok_line"
assert_no_grep "$PWD/doc4.err" 'older than the required' "c211_no_version_complaint"

# --- 4. a required tool resolving inside the project tree. The fake jq execs
# the real jq so the rest of doctor still works; only its LOCATION is wrong.
REAL_JQ=$(command -v jq)
mkdir -p "$PROJ/toolbin"
cat > "$PROJ/toolbin/jq" <<FAKEJQ
#!/bin/bash
exec "$REAL_JQ" "\$@"
FAKEJQ
chmod +x "$PROJ/toolbin/jq"
PATH="$PROJ/toolbin:$PATH" bash "$DOCTOR" "$PROJ" >"$PWD/doc5.out" 2>"$PWD/doc5.err"
RC5=$?
assert_rc 78 "$RC5" "c211_tool_in_tree_hard_fail"
assert_grep "$PWD/doc5.err" 'jq resolves INSIDE the project tree' "c211_tool_in_tree_message"

exit 0
