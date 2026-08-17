# Relay security model

Every claim here was verified empirically against Claude Code **2.1.233** on macOS 26
(Darwin 25.5.0), bash 3.2.57. Probes live in `test/lint/probe0-*.sh` and are re-runnable.

## Phase 0 findings

### 1. A repository's `.claude/settings.json` executes under `-p` — CRITICAL

`claude --help` states the workspace trust dialog is skipped in non-interactive mode.
Probe `probe0-settings-trust.sh` confirms what that means in practice: a repo-supplied
`.claude/settings.json` that registers a `SessionStart` hook **runs that hook**, and a
repo-supplied `.mcp.json` **is loaded**, with no prompt.

| Flags | repo hook fired | repo MCP loaded |
|---|---|---|
| *(none)* | **YES** | **YES** |
| `--strict-mcp-config` | **YES** | NO |
| `--setting-sources user` | NO | NO |
| both | NO | NO |

**Impact.** Cloning a hostile repo and running any headless Claude command in it is
arbitrary code execution on every tool call, plus `env.ANTHROPIC_BASE_URL` redirection of
every API request — which carries the user's credentials. `--strict-mcp-config` alone is
**not** sufficient; it stops MCP but not hooks.

**Relay's response.** Every session is launched with `--setting-sources user
--strict-mcp-config`. Both flags are mandatory and asserted in the supervisor's own argv
check before exec. This generalizes beyond relay: any unattended `claude -p` wrapper
running in a repo it did not author has this exposure.

### 2. Hooks can be delivered through inline `--settings` — architecture-defining

Probe `probe0-settings-hooks.sh`: a `SessionStart` and a `PostToolUse` hook passed inside
an inline `--settings` JSON string both fire, and `permissions.deny` from the same payload
is honoured.

**Consequence: relay registers zero global hooks.** The plugin ships no
`hooks/hooks.json`. Relay's context guard exists only inside relay's own child sessions,
delivered per-invocation. This eliminates, by construction:

- code running on every tool call of every session of everyone who installs relay,
  including people who never run it;
- an on-disk hook script that a compromised plugin update could swap;
- the entire class of "inert path must be provably side-effect free" concerns.

### 3. The sandbox is real, and it is the actual credential protection

Probe `probe0-sandbox.sh`, configured entirely through inline `--settings`:

| Case | Configuration | Result |
|---|---|---|
| Control | `sandbox.enabled: false` | canary secret **LEAKED** (proves the probe detects leaks) |
| Read | `sandbox.enabled: true` + `filesystem.denyRead` | canary **blocked** |
| Network | `sandbox.enabled: true` + `network.allowedDomains: [api.anthropic.com]` | egress to `example.com` **blocked**, CONNECT 403 |

Enforcement is at the OS layer (macOS `sandbox-exec`; Linux bind/tmpfs + seccomp), so it
covers code relay never sees — a `python3 -c "import urllib…"` buried inside `npm test` is
blocked identically to a bare `curl`.

The control case matters as much as the blocked cases: without it, a probe that "passes"
might simply be failing to observe.

### 4. Relay's hooks run *inside* the sandbox's filesystem policy

Probe `probe0-integration.sh` runs relay's real payload — sandbox and hooks together.
Exec-form hooks (`command: "bash", args: [path]`) fire correctly when delivered through
`--settings`, including when the hook path and the project path both contain spaces. Exec
form is used regardless, because shell form re-parses the substituted path.

The trap: **a hook that writes outside `sandbox.filesystem.allowWrite` fails silently, and
the symptom is indistinguishable from "the hook never fired."** This cost real debugging
time during Phase 0. Relay's state directory is in `allowWrite` by construction, and the
context guard writes only there — but any future hook must respect the same rule, and the
test suite asserts it.

Related, and worth knowing before writing a probe: **a sandbox-blocked tool call does not
necessarily emit a `PostToolUse` event.** A probe whose only tool call is the blocked one
cannot distinguish "hook never fired" from "there was nothing to fire on", so every hook
probe must include at least one *successful* tool call.

Hook stdin keys observed on 2.1.233 (`PostToolUse`):

```
cwd, duration_ms, hook_event_name, permission_mode, prompt_id, session_id,
tool_input, tool_name, tool_response, tool_use_id, transcript_path
```

`session_id` and `transcript_path` are both present, which is what the context guard needs.

### 5. `--output-format json` result fields (2.1.233)

```
type, subtype, is_error, result, session_id, uuid, num_turns, total_cost_usd,
usage, modelUsage, permission_denials, stop_reason, terminal_reason,
duration_ms, duration_api_ms, ttft_ms, api_error_status
```

`permission_denials` is directly useful: the supervisor can detect a permission-denial
spin instead of inferring it from a stall.

## Standing design rules that follow

1. **Fail closed on settings.** `-p` silently ignores settings files that fail validation,
   so relay must positively confirm enforcement before every run rather than assume it.
   The production acceptance probe is `probe0-sandbox.sh`'s shape: assert a `denyRead` path
   is actually unreadable and a non-allowlisted host is actually unreachable, in a
   relay-owned scratch directory. If either assertion fails, refuse to start.
2. **`sandbox.failIfUnavailable: true` always.** The default is false, and on failure
   commands run *unsandboxed* with only a warning.
3. **Never `sandbox.filesystem.disabled: true`** — it drops `denyRead` protection.
4. **Never `--safe-mode`.** It disables all customizations including relay's own hooks,
   while permissions "work normally". It is a troubleshooting flag, not a sandbox.
5. **Never `--bare` or `--no-session-persistence` in default mode.** `--bare` skips hooks
   (killing the context guard); `--no-session-persistence` destroys the transcript the
   guard reads. `--bare` is used *only* in `--hardened` mode, deliberately, where the
   context guard degrades to supervisor-side estimation.
6. **Pin the CLI version.** Record `claude --version` at `relay doctor` time; a version
   change forces re-running doctor, because the settings schema may have moved.

## What relay does not protect against

- The agent runs the project's build and test commands. Those execute arbitrary repository
  code. The sandbox confines them; the permission deny-list does not see inside them.
- `permissions.deny` is blast-radius reduction for the agent's own mistakes, not a
  security boundary. Absolute paths, alternative binaries, language runtimes, DNS, and
  `git ls-remote` with a secret in the URL all defeat command-pattern matching.
- Claude Code writes its own complete, unredacted transcript to `~/.claude/projects/`.
  Relay cannot redact that file.
- Relay's own supervisor runs outside the sandbox. Relay's session sandbox does not extend
  to it.

## Local hygiene note

`~/.claude/.credentials.json` ships mode **0644** (inside a 0700 directory, so other OS
users cannot reach it, but every process running as the user can). `relay doctor` reports
this and prints `chmod 600 ~/.claude/.credentials.json`; relay never modifies files outside
its own state directory.
