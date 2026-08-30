# Relay security model

Every claim here was verified empirically against Claude Code **2.1.233** on macOS 26
(Darwin 25.5.0), bash 3.2.57. Probes live in `test/lint/probe0-*.sh` and are re-runnable.

That pinning is meant literally, in both directions: every finding below is only as
current as its probe run, and the probes cost real money to run.

**Re-verified on 2.1.234 (2026-08-18): findings 1 and 3, unchanged.**
`probe0-settings-trust.sh` still reports the repo-supplied `SessionStart` hook firing
with no flags and suppressed under `--setting-sources user`; `probe0-sandbox.sh` still
reports its control case leaking (so the probe can still observe a leak), the `denyRead`
canary blocked, and egress to `example.com` refused with a CONNECT 403. The two findings
relay's whole threat model rests on therefore hold on the newer CLI.

**Finding 7 established on 2.1.234 (2026-08-27)** by `probe0-sandbox-off.sh`, for
`sandbox_mode: "disabled"`. Case 1 (relay's full-trust payload): `is_error=false`,
relay's inline hook wrote `run/hook.alive`, the canary was **readable**, and
`https://example.com` answered `code=200 rc=0`. So the CLI honours the minimal
`sandbox: {"enabled": false}` object rather than rejecting the payload, and full
trust really is full. Case 2 (same payload, `hooks` block removed): no marker —
the control proving the marker is evidence of delivery rather than a coincidence.

**Case 3, added 2026-08-29 and the load-bearing one:** a payload that keeps the
`hooks` block but is otherwise malformed (`enabled: "yes"`, `allow` a string,
`deny` an object) also produced **no marker**, with `permission_denials=1`
confirming the CLI processed it differently. Case 2 only established *no hooks
key ⇒ no marker*, which is the converse of a different statement; production
infers *no marker ⇒ the payload was REJECTED*, and only case 3 exercises that
direction. Without it the probe did not prove what its own header claimed.
Together the three cases are what lets the disabled-mode probe distinguish an
accepted payload from a silently discarded one.

One empirical caveat found while establishing it, and the reason the probe's
scratch is named the way it is: an earlier draft used a canary file called
`canary-secret.txt` holding `RELAY-CANARY-…-DO-NOT-LEAK`, and haiku **refused the
prompt outright** as a suspected exfiltration test. It made no tool calls, so no
hook marker and no read proof appeared. Two consequences worth keeping in mind.
Probe scratch must look mundane — production already uses a neutral
`relayprobe<hex>` token for exactly this reason. And a model refusal is a real
failure mode for the disabled-mode probe: it fails **closed** (missing marker →
refuse to run), which is the safe direction, but the cause is the model, not the
payload. `docs/troubleshooting.md` lists it under the missing-marker symptom.

**Findings 6 (all four cases) re-verified and case E added on 2.1.251
(2026-08-30)** by `probe0-permission-mode.sh`: `dontAsk` still default-denies,
deny still beats a broad allow, and — new — a denial leaves the session
healthy (`is_error` false) with `permission_denials` entries carrying exactly
`tool_name`/`tool_use_id`/`tool_input`, the shape the supervisor's
`session.denials` telemetry parses. **Case 4 added to `probe0-sandbox-off.sh`
the same day, on the REAL 1.1.0 disabled payload**: WebFetch allowed and
working, `git remote -v` passing — and the planned
`Bash(git remote set-url:*)` deny NEVER FIRING: a three-word deny prefix does
not match on this CLI (the session mutated the origin with the rule in
place, zero denials). That probe result is why 1.1.0 ships no `git remote`
deny in disabled mode at all rather than a decorative narrowed one.

**Finding 5 re-verified on 2.1.234 (2026-08-27)**, after `relay_settings_build`
gained its `sandbox_mode` argument. `probe0-integration.sh` reports relay's real
payload accepted, the exec-form hook firing through a path containing a space,
and `denyRead` still enforced — so the refactor did not disturb the enforced
path. That is corroborated statically too: the `enforced` payload is byte-for-byte
identical to the one 0.1.0 shipped.

**Not re-run on 2.1.234: findings 2 and 6** (`probe0-settings-hooks.sh`,
`probe0-permission-mode.sh`). What a newer CLI changed there is
unverified, not assumed unchanged. Relay's runtime covers part of that gap on its own —
the sandbox-enforcement probe's cache key includes `claude --version`, so a version
change forces a fresh runtime proof of the sandbox before any run starts, and that proof
now asserts blocked egress as well as the unreadable canary. It proves the sandbox, not
the hook-delivery or permission-mode findings.

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
(`plugins/relay/scripts/relay-settings.sh:388`); the context guard writes only under
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
are never allowed **in `enforced` mode**: they fetch from the CLI process, not
from a sandboxed Bash child, and whether that in-process egress honours
`sandbox.network.allowedDomains` is unverified — an unverified hole in the
egress boundary is not a convenience worth having. In `disabled` mode both are
allowed since 1.1.0, because there is no boundary for them to bypass (curl
already reaches every host) and a refusal under `dontAsk` was pure friction —
observed as real `permission_denials` in run telemetry. The same release adds
`allow_tools_extra` (config, disabled-mode only) for tool names relay has never
heard of: a `Monitor` call from a newer harness was observed denied mid-run,
and a per-project config key beats a relay release every time that happens.
Case C is why the allow list is bare tool names rather than
path-scoped rules: every session must read `RUN.md`, which lives outside the
project by design.

**The general lesson.** No mock-based test could have caught this, because the
mock has no permission layer to get wrong. Behaviour that lives in the real CLI
has to be probed against the real CLI.

## Standing design rules that follow

Rules 1-3 describe the default `enforced` mode. Where `sandbox_mode: "disabled"`
(full trust) changes them, that is stated inline and in "Trust mode inverts the
probe" below; rules 4-7 hold in both modes, unconditionally.

1. **Fail closed on settings.** `-p` silently ignores settings files that fail validation,
   so relay must positively confirm enforcement before every run rather than assume it.
   The production acceptance probe (`relay_settings_probe`,
   `plugins/relay/scripts/relay-settings.sh:555-655`) is `probe0-sandbox.sh`'s shape:
   in a relay-owned scratch directory (`$STATE/work/probe/`), assert that a `denyRead`
   canary is actually unreadable and that a host outside `network.allowedDomains` is
   actually unreachable. Both assertions leave evidence in files the supervisor reads,
   never in the model's prose: the canary read is redirected into a proof file (a
   sandbox that is off puts the canary's value there whatever the model then says,
   `relay-settings.sh:594-602`), and the egress attempt records `code=`/`rc=` marker
   lines that the verdict parser reads by key — never "the first three digits in the
   file", which once misread curl's own "port 443" error text as an HTTP status and
   refused a working sandbox (`relay-settings.sh:476-482`). The run is refused if the
   canary's value appears in the proof file, the session JSON, or stderr; if the probe
   session did not complete cleanly (`.is_error == false`); or if the egress verdict is
   `reachable` (`relay-settings.sh:627-651`).

   One deliberate asymmetry, added when relay's own audit found the runtime probe testing
   only the canary while this rule claimed both: an egress attempt relay cannot interpret
   is not the same as one that was blocked. `curl` is not a relay dependency, so a box
   without it yields no verdict; that case is journaled as `probe.egress inconclusive` and
   the run proceeds on the canary's proof alone. Refusing on "we could not tell" would make
   relay unrunnable on a machine where nothing is actually wrong. `probe0-sandbox.sh`,
   which is run by a human against a machine that does have `curl`, remains the place
   egress blocking is proven outright.
2. **`sandbox.failIfUnavailable: true` whenever the sandbox is on.** The default is
   false, and on failure commands run *unsandboxed* with only a warning — a silent
   downgrade to exactly the state `sandbox_mode: "disabled"` reaches deliberately, but
   without the operator having chosen it, without consent, and without the status
   surfaces saying so. The distinction relay draws is not sandbox-vs-no-sandbox, it is
   chosen-vs-accidental.
3. **Never `sandbox.filesystem.disabled: true`** — it drops `denyRead` protection while
   leaving `sandbox.enabled` reading as `true`, i.e. a payload that misreports itself.
   Full-trust mode instead emits `{"enabled": false}` and nothing else: no `denyRead`
   and no `network` keys whose behaviour under a switched-off sandbox relay has not
   verified, and no shape that could be mistaken for an enforcing payload.
4. **Never `--safe-mode`.** It disables all customizations including relay's own hooks,
   while permissions "work normally". It is a troubleshooting flag, not a sandbox.
5. **Never `--bare` or `--no-session-persistence`, in any mode.** `--bare` skips hooks
   (killing the context guard); `--no-session-persistence` destroys the transcript the
   guard reads. Both are in `relay_settings_assert_argv`'s forbidden list and are
   refused unconditionally — there is no mode, flag or config value that permits
   either. Earlier revisions of this rule said `--bare` was used "only in `--hardened`
   mode". **There is no `--hardened` mode**, there never was one, and now that
   `sandbox_mode` gives relay a real mode axis that sentence read as a live exemption
   for full trust. It is deleted rather than corrected.
6. **Pin the CLI version.** Record `claude --version` at `/relay-doctor` time; a version
   change forces re-running doctor, because the settings schema may have moved.
7. **The payload must say what is allowed, not only what is forbidden.** Under
   `dontAsk` an omitted `allow` list is not a permissive default — it is a total
   refusal (finding 6).

## Trust mode inverts the probe

`sandbox_mode: "disabled"` is a per-project opt-in recorded at `/relay-init`. It emits
`sandbox: {"enabled": false}` and opens the deny-list to operational commands, keeping
only the `git push` deny and the write-persistence guards. (Until 1.1.0 it also kept a
broad `git remote` deny, which caught read-only `git remote -v` in real runs; the
narrowing to mutating subcommands died in probe: a three-word deny prefix like
`Bash(git remote set-url:*)` **never fires** on Claude Code 2.1.251 — the probe ran the
mutation with the rule in place, zero denials, origin rewritten. A deny that
demonstrably does not match is decorative, so it was dropped rather than narrowed;
the residual is recorded under "What full trust actually costs".) Sessions can then SSH,
reach any host, and read anything the user can read.

The reason this needs its own probe rather than no probe is rule 1: `-p` silently ignores
a payload that fails validation. With the sandbox off, "canary readable and host
reachable" is what a **healthy** full-trust run looks like — and it is also exactly what a
**dropped payload** looks like. Reads and egress cannot tell them apart, and a dropped
payload means no hooks and no deny-list at all while the journal claims otherwise.

The discriminator is relay's own inline `PostToolUse` hook, which is delivered inside the
same `--settings` payload. `relay_settings_probe_disabled`
(`plugins/relay/scripts/relay-settings.sh:680-799`) supplies the environment the hook
requires — `RELAY_SESSION_ID` (also passed as `--session-id`, so the id appears in the
hook's stdin payload) and a `RELAY_DIR` holding a `.relay` marker — then asserts three
things, refusing on each: the session completed cleanly; `run/hook.alive` exists, proving
the payload was accepted; and the canary *was* readable, proving the sandbox really is off
rather than the operator being misled about which mode they are in. Egress is journaled
and never refuses, because `reachable` is the expected result here and `blocked` may only
mean an offline machine.

Because the probe cache is keyed by `(payload + CLI version)`, flipping the mode always
forces a fresh proof. That is a statement about the KEY, not about the file: `probe.ok`
is session-writable once the sandbox is off, so in `disabled` mode relay neither trusts
nor writes it — the cache is dropped on entry and every full-trust start re-proves
(`test/cases/c235_mode_switch_invalidates_probe_cache.sh`,
`c232_disabled_mode_end_to_end.sh`).

**Residual, not closed.** That still does not stop a hostile full-trust session
*planting* an enforced-mode fingerprint for a LATER run to find: the session can
recompute any fingerprint it likes, having `relay-settings.sh`, `jq`, `git` and
`claude --version` to hand. No in-file scheme fixes this — the attacker computes the
key and can rewrite any marker meant to flag the exposure — and closing it properly
needs storage the session cannot reach, which full trust by definition does not
provide. It is called out separately from the general "state files are convention, not
boundary" note because of where it lands: it degrades a *later* run in the mode the
operator switched back to for safety. **After running a project in full trust, delete
`$STATE/run/probe.ok` before switching back to `enforced`.** The supervisor journals
`probe.cache-discarded` whenever it drops the cache itself.

The guardrail-drift filter is deliberately **not** relaxed in this mode — it is one of the
few rails left once the sandbox is gone. RUN.md instead gives sessions the phrase
"full-trust mode", which is accurate and does not match the filter.

## What full trust actually costs, itemised

The mode's own description — "sessions can reach any host, SSH to your machines, and
read anything you can read" — is true and still understates it, because two of the
things it stops protecting are not files and not hosts. These are **accepted** risks:
they were weighed against the operational capability full trust exists to provide, and
the deny list is deliberately left open rather than patched with guards a shell walks
around anyway. They are written down so the choice is informed, not so it is reversed.

- **The macOS keychain.** `Bash(security:*)` is denied in `enforced` mode and lifted in
  `disabled`. `security dump-keychain` and `security find-generic-password -w` read
  secrets out of the login keychain, which is not "a readable file" and is therefore
  not covered by the sentence above. Whatever the keychain holds — App Store
  credentials, Wi-Fi passwords, whatever an app put there — is in reach of a full-trust
  session, subject to whatever the OS itself prompts for.
- **Uncommitted work.** `Bash(git reset --hard:*)`, `Bash(git clean:*)` and
  `Bash(git filter-branch:*)` are denied in `enforced` and lifted in `disabled`. Relay
  still never pushes, so nothing reaches a remote — but the working tree and the local
  history are destroyable, and a `git clean -fdx` takes untracked files no commit ever
  saw. Relay's commit-per-session habit narrows the window; it does not close it.
- **Persistence.** `Bash(crontab:*)`, `Bash(launchctl:*)`, `Bash(at:*)` and
  `Bash(systemctl:*)` are denied in `enforced` and lifted in `disabled`. A full-trust
  session can install something that outlives the run and every later relay session.
- **Your git remotes.** Since 1.1.0 nothing in disabled mode denies `git remote`
  at all (see "Trust mode inverts the probe" for why the narrowed deny was
  dropped: the CLI does not match three-word deny prefixes). Relay itself still
  never pushes — but a session can rewrite `origin`, and the accident that
  outlives the run is YOUR next `git push` landing somewhere wrong. Check
  `git remote -v` before pushing anything a full-trust run touched.
- **The run's own history surfaces.** `$STATE/ledger.md` (the per-session run
  arc rendered into later prompts) and the `gates_passed` record in
  `state.json` are Bash-reachable in this mode like every other state file. The
  ledger is re-filtered at render time and gate *definitions* are anchored
  in memory (see below) — but a session determined to lie can mark gates
  passed or rewrite history rows. Convention, not boundary, as ever here.
- **Shell startup files the write guards miss.** The retained Write/Edit deny rules
  cover `~/.zshrc`, `~/.bashrc`, `~/.profile` and `~/.zprofile`. They do **not** cover
  `~/.zshenv`, which zsh sources for every invocation including non-interactive ones,
  nor `~/.bash_profile`, `~/.bash_login` or `~/.config/fish/`. And the whole list binds
  the Write and Edit *tools* only: `printf >> ~/.zshrc` through Bash is not a tool call
  and no rule sees it. The guards stop an agent that reaches for the obvious tool. They
  are not a boundary and are not offered as one.

The general form of all four: in `disabled` mode `permissions.deny` is a reminder, not
a control. Anything reachable from a shell is reachable. Choose the mode for a
repository you would trust with your SSH keys, and re-read
`relay_settings_deny_for_mode` if you want the exact list rather than these examples.

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
- Under `sandbox_mode: "disabled"`, anything a shell can reach: SSH keys, other hosts,
  the whole readable filesystem. The remaining deny-list entries are honoured by the
  Write/Edit tools only, so relay's own `$STATE` files — journal, `state.json`,
  `probe.ok` — are protected there by convention rather than by enforcement. The one
  checks that still bite are the in-memory anchors, which predate every session:
  the acceptance command's (before running it, relay re-reads `exec.json` and requires
  both that its hash matches the recorded `exec_hash` *and* that the argv still equals
  `ACCEPT_CMD_JSON`, the value captured at preflight), the phase gates' (same dual
  anchor over `GATES_JSON`, checked immediately before every gate execution), and the
  RUN.md integrity guard's (the protected-region hash is computed at supervisor start
  and held in memory, so a session that rewrites the mission still halts the run even
  though it could also rewrite the on-disk baseline used for the diff). Rewriting any
  of those files together with their recorded hashes therefore still fails.

## Local hygiene note

`~/.claude/.credentials.json` ships mode **0644** (inside a 0700 directory, so other OS
users cannot reach it, but every process running as the user can). `/relay-doctor` reports
this and prints `chmod 600 ~/.claude/.credentials.json`; relay never modifies files outside
its own state directory.
