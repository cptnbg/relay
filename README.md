# relay

Run a long multi-phase build to completion across automatically chained Claude
Code sessions.

A session works until its context fills, writes a structured handoff, and ends.
A supervisor verifies what actually happened — sealed sentinels, commit counts,
a clean tree — and launches a *fresh* session from that handoff. It keeps going
until the plan's acceptance criteria are proven, a human is genuinely needed, or
a safety rail trips.

The problem it solves is mundane and constant: past roughly 70% context, model
quality degrades. The usual fix is to ask for a handoff prompt, `/clear`, paste
it back, and continue. Relay is the thing that types `/clear` and pastes the
handoff, so a build advances while you are asleep.

---

## Read this before you run it

**Relay runs Claude Code unattended, in a loop, with permission prompts
suppressed.** That is the point, and it is also the risk. Be honest with
yourself about the repository you point it at.

**Your build and test commands execute arbitrary repository code with your full
privileges.** A `package.json` `pretest` script, a `conftest.py`, a `build.rs`,
a `Makefile` recipe — any of them can read your credentials. Relay's permission
deny-list cannot see inside them: to the permission layer, `npm test` is one
approved command.

**The deny-list is not a security boundary.** It blocks `sudo`, `git push`,
`docker`, cloud CLIs, and credential reads, which meaningfully reduces the blast
radius of the agent's own mistakes. But anyone who controls repository content
works around command-pattern matching trivially — absolute paths, other
binaries, language runtimes, DNS, `git ls-remote` with a secret in the URL.
Treat it as a seatbelt, not a vault door.

**The sandbox is the real control.** Relay enables Claude Code's built-in
OS-level sandbox on every session: filesystem reads are confined and network
egress is restricted to an allowlist, enforced below the shell, so it covers
code relay never sees. **If the sandbox cannot start, relay refuses to run.**
Relay also proves enforcement before each run rather than assuming it, because
`claude -p` silently ignores a settings payload that fails validation. That
proof has one honest asymmetry: the read-denial canary must pass outright,
while the egress check can come back *inconclusive* on a machine without
`curl` — that case is journaled as `probe.egress inconclusive` and the run
proceeds on the canary's proof alone, because "we could not tell" is not the
same claim as "blocked".

**Relay never pushes.** It commits — with an explicit filtered pathspec, never
`git add -A`, refusing credential-shaped filenames and scanning the full
content of every staged file for secrets (content, not diff, so an in-tree
`.gitattributes` cannot hide a file from the scan). On a hit it halts instead
of committing. This is best-effort:
**review `git log -p` before you push.**

**Logs contain what the agent read, unredacted.** They are kept outside your
repository at `~/.local/state/relay/`, mode 0600, and pruned on a retention
schedule you control (`keep_sessions`/`keep_days`) — but relay does not redact
them. Separately, Claude Code writes its own complete, unredacted transcript
to `~/.claude/projects/` — relay does not control that file and cannot redact
it.

**A repository can never make relay run a command.** Commands live in your user
configuration outside any repo and require explicit approval. The approval
records a hash of the exact command (`exec_hash`); the supervisor verifies it
at preflight and again immediately before executing the command, and halts
BLOCKED on any mismatch — so a command changed after approval never runs.

Only point relay at a repository you would `npm install && npm test` in without
thinking about it. Relay's session sandbox does not extend to relay's own
supervisor.

---

## Requirements

`bash` 3.2+ (macOS system bash is fine), `git` 2.20+, `jq` 1.6+, Claude Code
2.1+. Deliberately **not** required: node, python, coreutils, `flock`,
`timeout`. Relay ships no globally-registered hooks — its context guard is
delivered per-invocation, so nothing relay installs runs in your other sessions.

## Install

```
/plugin marketplace add cptnbg/relay
/plugin install relay@relay
```

## Verify what you installed

Release tags are signed. Before you trust one:

```
git verify-tag vX.Y.Z
```

Then check the reported signing key against the maintainer's fingerprint:

```
9B62 EB00 8531 00CB FA92  AD72 C12C DEF0 D3BF 983C
```

**Compare it, do not skip it.** `git verify-tag` on its own tells you only that
*some* key signed the tag — it says nothing about whose. A signature you cannot
compare against a known fingerprint proves nothing, so treating "any valid
signature" as verification defeats the point of signing at all.

`RELEASING.md` is the procedure that produces those tags, including why the
marketplace entry pins a release archive by sha256 instead of tracking a
mutable branch, and the rule that relay never auto-updates: upgrading is
something you do deliberately, after reading the diff.

## Use

```
/relay-doctor                     # can relay safely run here?
/relay-init  path/to/PLAN.md      # interview, consent, configuration
/relay-approve                    # review + approve the acceptance command
/relay-run                        # launch; this session then ends
/relay-status                     # what is it doing?
/relay-note  "prefer sqlite here" # steer it without stopping it
/relay-stop                       # stop cleanly at the next safe point
/relay-resume                     # continue after a stop or a block
```

`init` interviews you first — credentials, irreversible actions, ambiguous
requirements, anything the plan defers to an owner — so the run does not stall
at 3am on a question you could have answered up front. Answers are recorded as
decisions no later session may re-ask.

## How it works

```
supervisor
  ├─ preflight: doctor, then PROVE the sandbox is enforced (else refuse)
  └─ loop
       spawn claude -p  --setting-sources user --strict-mcp-config
                        --settings '<sandbox + deny + relay's own hook>'
       │   60% used → "land your current step, then hand off"
       │   75% used → "hand off now"
       │   88% used → "write the handoff even if incomplete"
       │   opus orchestrator delegates to parallel sonnet subagents
       └─ verify: sealed COMPLETE + clean tree + approved acceptance cmd
                  passes (with no acceptance cmd: commit count must grow)
                  BLOCKED → halt   STOP → halt   usage limit → wait, resume
                  invalid handoff / compaction → next session runs in recovery
                  no progress → escalate to fable, then trip the breaker
```

**Why fresh sessions beat compaction.** Compaction summarises a degraded
context. A handoff is written deliberately, while the model is still sharp,
against a schema that forces it to state position, next action, and proof.

**Orchestrator-lean.** Each session delegates heavy work to subagents that
receive file *paths*, not pasted contents, and read for themselves. Their
context dies with them, so the orchestrator's grows slowly and a session lasts
far longer before it has to hand off.

**Model ladder.** Sonnet subagents execute; an opus orchestrator decides,
reviews, and commits; fable is the escalation tier. Two unproductive sessions
escalate to fable *before* the circuit breaker fires — a smarter model beats a
halt — then de-escalate once productive, capped so one hard step cannot pin the
whole run to the expensive tier.

**Handoffs are structured, not prose.** `continue.json` is schema-validated,
size-capped, rendered into the next prompt inside a nonce fence, and explicitly
subordinated to RUN.md. Free-form prose is where prompt injection lives; a
handoff that claims a guardrail was relaxed halts the run for a human.

## Two settings that bite

**Context window.** The thresholds are percentages of `window_<tier>`, so that
number has to be the model's real window. A session already holds tens of
thousands of tokens — system prompt, tool definitions, your `CLAUDE.md` —
before its first tool call, and **that number is a property of your project,
not a constant**: measured at 48k on a small repository and 69k on a large one
with substantial project instructions. Setting a small window to "make handoffs
fire quickly" makes them fire *immediately and always*, so the run produces
handoffs and never work.

Relay refuses to start below 100k, and after its first session it knows your
project's real figure — it records the baseline and will refuse a window that
does not clear it with room to work in, telling you what to set. If in doubt,
use the model's actual context window.

**Untracked files.** Relay stages modified tracked files plus untracked files
that `.gitignore` does not exclude. Anything else writing into the working tree
while a session runs — another agent's scratch directory, editor droppings —
gets committed with the work. Gitignore that scratch before pointing relay at
the repository.

## Other knobs worth knowing

- **`allow_domains`** (`config.json`) — extra sandbox egress, as a
  comma-separated hostname list. The default allowlist is `api.anthropic.com`
  and nothing else, so `npm ci` fails inside the sandbox until the registry is
  listed here. Validated as hostnames at preflight; a malformed value refuses
  to start rather than silently never matching.
- **`keep_sessions` / `keep_days`** (`config.json`, defaults 5 and 7) — how
  many session logs survive pruning, and for how many days. Session logs hold
  whatever the agent read; this is the retention control.
- **`RELAY_NOTIFY_CMD`** (environment variable) — how a run reaches your
  phone. If set, relay invokes it as `"$RELAY_NOTIFY_CMD" <title> <message>`
  — argv only, never a shell string, sanitized arguments, 5-second timeout —
  on every notable event: complete, blocked, budget or session cap, usage
  limit, escalation. Point it at any two-argument forwarder (ntfy, Pushover,
  Telegram bot). Without it, relay falls back to `terminal-notifier`, then
  `osascript`, then `notify-send`, whichever exists; `RELAY_NOTIFY=0`
  disables notifications entirely.

## When it stops

| Exit | Meaning |
|---|---|
| 0 | complete, and verified |
| 20 | blocked — a human is needed; see `work/BLOCKED.md` in the state dir |
| 21 / 26 | no progress across several sessions / sessions exiting immediately |
| 22 / 23 / 24 | repeated timeouts / session cap / you asked it to stop |
| 25 | another supervisor holds this project |
| 27 | repeated false completion claims |
| 28 | relay could not create or write its own state directory |
| 29 | your total budget is spent, **or** the provider's usage limit outlasted relay's retries |
| 78 | preflight failed — relay never started |

Those last two are one exit code with two opposite remedies: `state.json`'s
`status` is `budget` when your configured spend is exhausted (raise it or stop)
and `usage-limit` when the provider throttled you and relay gave up waiting
(wait, then `/relay-resume`). `docs/exit-codes.md` has the full table, one row
per code, each checked against the line that returns it.

## Documentation

- [`docs/architecture.md`](docs/architecture.md) — how the chain loop actually
  works: why `claude`'s exit code is never trusted, what is checked instead and
  in what order, the state layout, the handoff schema, the model ladder, and
  where the context guard sits.
- [`docs/exit-codes.md`](docs/exit-codes.md) — every code the supervisor can
  return, what to look at first, and whether `/relay-resume` is the right move.
- [`docs/troubleshooting.md`](docs/troubleshooting.md) — symptom first. Start
  here when something looks wrong.
- [`docs/portability.md`](docs/portability.md) — the dependency policy, the
  bash 3.2 constraints, and what the two linters refuse.
- [`docs/security.md`](docs/security.md) — the Claude Code behaviours relay
  depends on, each verified empirically rather than assumed.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — how to run the suites, what the paid
  probes are for, and which changes need a second maintainer.
- [`RELEASING.md`](RELEASING.md) — the release procedure, written to be
  followed exactly.

## Testing

The whole supervisor and hook are exercised against a mock `claude` with **zero
API calls**:

```
bash test/run.sh
```

## Security

`docs/security.md` records what was verified empirically against Claude Code
2.1.233, including the finding that a repository's `.claude/settings.json`
executes under `claude -p` unless `--setting-sources user` is passed — which
applies to any unattended `claude -p` wrapper, not just relay.

Report vulnerabilities privately; see `SECURITY.md`.

## License

MIT.
