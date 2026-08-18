# test/hook/h150_stdout_json_only_everywhere.sh — sweeps several distinct
# scenarios (silent, soft, critical x2, kill switch, precompact) and proves
# via assert_stdout_json_only that stdout is ALWAYS either completely empty
# or exactly one valid JSON object, never partial output or stray text.
HOOK="$ROOT/plugins/relay/hooks/relay-ctx.sh"
SID="11111111-2222-3333-4444-555555555555"

run_hook() {
  # run_hook <relay_dir> <transcript_path_or_empty> <outfile> [extra hook args...]
  local rdir="$1" tp="$2" outfile="$3" payload
  shift 3
  if [ -n "$tp" ]; then
    payload="$(jq -nc --arg sid "$SID" --arg tp "$tp" '{session_id:$sid, transcript_path:$tp}')"
  else
    payload="$(jq -nc --arg sid "$SID" '{session_id:$sid}')"
  fi
  printf '%s' "$payload" \
    | RELAY_SESSION_ID="$SID" RELAY_DIR="$rdir" "$HOOK" "$@" > "$outfile" 2>/dev/null
}

# scenario 1: well below soft -> silent
D1="$PWD/d1"; mkdir -p "$D1"; printf '{}' > "$D1/state.json"; : > "$D1/.relay"
T1="$PWD/t1.jsonl"; mktranscript "$T1" 10
run_hook "$D1" "$T1" "$PWD/o1.json"
assert_stdout_json_only "$PWD/o1.json" "h150_below_soft"
assert_eq "" "$(cat "$PWD/o1.json")" "h150_below_soft_empty"

# scenario 2: soft -> emits
D2="$PWD/d2"; mkdir -p "$D2"; printf '{}' > "$D2/state.json"; : > "$D2/.relay"
T2="$PWD/t2.jsonl"; mktranscript "$T2" 62
run_hook "$D2" "$T2" "$PWD/o2.json"
assert_stdout_json_only "$PWD/o2.json" "h150_soft"
assert_contains "$(cat "$PWD/o2.json")" "CONTEXT CHECKPOINT" "h150_soft_text"

# scenario 3+4: critical, called twice (level 3 re-emits every call)
D3="$PWD/d3"; mkdir -p "$D3"; printf '{}' > "$D3/state.json"; : > "$D3/.relay"
T3="$PWD/t3.jsonl"; mktranscript "$T3" 92
run_hook "$D3" "$T3" "$PWD/o3.json"
assert_stdout_json_only "$PWD/o3.json" "h150_crit_call1"
run_hook "$D3" "$T3" "$PWD/o3b.json"
assert_stdout_json_only "$PWD/o3b.json" "h150_crit_call2"
assert_contains "$(cat "$PWD/o3b.json")" "CRITICAL" "h150_crit_call2_text"

# scenario 5: kill switch beats critical -> silent
D4="$PWD/d4"; mkdir -p "$D4"; printf '{}' > "$D4/state.json"; : > "$D4/.relay"
: > "$D4/hook.off"
T4="$PWD/t4.jsonl"; mktranscript "$T4" 92
run_hook "$D4" "$T4" "$PWD/o4.json"
assert_stdout_json_only "$PWD/o4.json" "h150_killswitch"
assert_eq "" "$(cat "$PWD/o4.json")" "h150_killswitch_empty"

# scenario 6: precompact mode -> always emits its fixed payload
D5="$PWD/d5"; mkdir -p "$D5"; printf '{}' > "$D5/state.json"; : > "$D5/.relay"
run_hook "$D5" "" "$PWD/o5.json" --precompact
assert_stdout_json_only "$PWD/o5.json" "h150_precompact"
assert_contains "$(cat "$PWD/o5.json")" "hookSpecificOutput" "h150_precompact_text"

exit 0
