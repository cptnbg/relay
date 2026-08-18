# Relay security model

Every claim here was verified empirically against Claude Code **2.1.233** on macOS 26
(Darwin 25.5.0), bash 3.2.57. Probes live in `test/lint/probe0-*.sh` and are re-runnable.

That pinning is meant literally, in both directions. Every finding below is only as
current as its probe run, the probes cost real money, and **they have not been re-run
against any CLI newer than 2.1.233** — including 2.1.234, a version this repository
already references elsewhere (the marketplace schema notes in `RELEASING.md` were read
from the 2.1.234 binary). Until someone re-runs the probes (`CONTRIBUTING.md`, "The paid
probes"), what a newer CLI changed is unverified, not assumed unchanged. Relay's runtime
covers only part of that gap on its own: the sandbox-enforcement probe's cache key
includes `claude --version`, so a version change forces a fresh runtime proof of the
sandbox — but of the sandbox alone, not of the other findings below.

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
time during Phase 0. The sandbox's `allowWrite` is exactly the project, relay's
session-writable work directory `$STATE/work/`, and `$TMPDIR`
(`plugins/relay/scripts/relay-settings.sh:236`); the context guard writes only under
`$STATE/work/` — the supervisor-only remainder of the state directory (state.json,
journal.log, exec.json, locks/) is deliberately *not* writable from inside a session.
Any future hook must respect the same rule, and the test suite asserts it.

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

### 6. `--permission-mode dontAsk` denies by default — a deny-only payload is unusable

Probe `probe0-permission-mode.sh` (costs money; not part of `test/run.sh`):

| Case | Payload | Result |
|---|---|---|
| A | `permissions.deny` only | project-local `Write` **refused**, `cat > file` Bash fallback **refused** |
| B | `deny` + broad `allow` | same `Write` **succeeds** |
| C | `deny` + `allow: ["Read", …]` | `Read` reaches **outside** the working directory |
| D | broad `allow` + `Bash(<specific>:*)` deny | the specific deny **still fires** |

`dontAsk` means "never prompt", and with nobody to prompt, anything not
explicitly allowed is refused rather than proceeded with. Relay originally
shipped a deny-only payload on the opposite assumption. Its first real session
therefore could not write a single file: the result envelope recorded a denied
`Write`, then a denied `cat > file` Bash fallback, then the session exhausted
its budget having produced nothing.

Case D is the one that makes the fix safe. Adding `Bash` to `allow` does not
void `Bash(sudo:*)` — deny still wins — so the blast-radius layer survives a
broad allow list intact.

**Relay's response.** The payload carries an explicit `permissions.allow` list
covering what a build session needs (`Read`, `Write`, `Edit`, `Glob`, `Grep`,
`Bash`, `Task`, …) alongside the unchanged deny list. `WebFetch` and `WebSearch`
are never allowed. Case C is why the allow list is bare tool names rather than
path-scoped rules: every session must read `RUN.md`, which lives outside the
project by design.

**The general lesson.** No mock-based test could have caught this, because the
mock has no permission layer to get wrong. Behaviour that lives in the real CLI
has to be probed against the real CLI.

## Standing design rules that follow

1. **Fail closed on settings.** `-p` silently ignores settings files that fail validation,
   so relay must positively confirm enforcement before every run rather than assume it.
   The production acceptance probe (`relay_settings_probe`,
   `plugins/relay/scripts/relay-settings.sh:403-492`) is `probe0-sandbox.sh`'s shape:
   in a relay-owned scratch directory (`$STATE/work/probe/`), assert that a `denyRead`
   canary is actually unreadable and that a host outside `network.allowedDomains` is
   actually unreachable. Both assertions leave evidence in files the supervisor reads,
   never in the model's prose: the canary read is redirected into a proof file (a
   sandbox that is off puts the canary's value there whatever the model then says,
   `relay-settings.sh:431-439`), and the egress attempt records `code=`/`rc=` marker
   lines that the verdict parser reads by key — never "the first three digits in the
   file", which once misread curl's own "port 443" error text as an HTTP status and
   refused a working sandbox (`relay-settings.sh:326-331`). The run is refused if the
   canary's value appears in the proof file, the session JSON, or stderr; if the probe
   session did not complete cleanly (`.is_error == false`); or if the egress verdict is
   `reachable` (`relay-settings.sh:467-489`).

   One deliberate asymmetry, added when relay's own audit found the runtime probe testing
   only the canary while this rule claimed both: an egress attempt relay cannot interpret
   is not the same as one that was blocked. `curl` is not a relay dependency, so a box
   without it yields no verdict; that case is journaled as `probe.egress inconclusive` and
   the run proceeds on the canary's proof alone. Refusing on "we could not tell" would make
   relay unrunnable on a machine where nothing is actually wrong. `probe0-sandbox.sh`,
   which is run by a human against a machine that does have `curl`, remains the place
   egress blocking is proven outright.
2. **`sandbox.failIfUnavailable: true` always.** The default is false, and on failure
   commands run *unsandboxed* with only a warning.
3. **Never `sandbox.filesystem.disabled: true`** — it drops `denyRead` protection.
4. **Never `--safe-mode`.** It disables all customizations including relay's own hooks,
   while permissions "work normally". It is a troubleshooting flag, not a sandbox.
5. **Never `--bare` or `--no-session-persistence` in default mode.** `--bare` skips hooks
   (killing the context guard); `--no-session-persistence` destroys the transcript the
   guard reads. `--bare` is used *only* in `--hardened` mode, deliberately, where the
   context guard degrades to supervisor-side estimation.
6. **Pin the CLI version.** Record `claude --version` at `/relay-doctor` time; a version
   change forces re-running doctor, because the settings schema may have moved.
7. **The payload must say what is allowed, not only what is forbidden.** Under
   `dontAsk` an omitted `allow` list is not a permissive default — it is a total
   refusal (finding 6).

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
users cannot reach it, but every process running as the user can). `/relay-doctor` reports
this and prints `chmod 600 ~/.claude/.credentials.json`; relay never modifies files outside
its own state directory.
