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
`claude -p` silently ignores a settings payload that fails validation.

**Relay never pushes.** It commits — with an explicit filtered pathspec, never
`git add -A`, refusing credential-shaped filenames and scanning the staged diff
for secrets. On a hit it halts instead of committing. This is best-effort:
**review `git log -p` before you push.**

**Logs contain what the agent read.** They are kept outside your repository at
`~/.local/state/relay/`, mode 0600, and pruned. Redaction is pattern-based and
will miss things. Separately, Claude Code writes its own complete, unredacted
transcript to `~/.claude/projects/` — relay does not control that file and
cannot redact it.

**A repository can never make relay run a command.** Commands live in your user
configuration outside any repo and require explicit approval, re-confirmed
whenever they change.

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

## Use

```
/relay-doctor                     # can relay safely run here?
/relay-init  path/to/PLAN.md      # interview, consent, configuration
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
       └─ verify: sealed COMPLETE + acceptance + clean tree + commits grew
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
before its first tool call; 48k when this was measured. Setting a small window
to "make handoffs fire quickly" makes them fire *immediately and always*, so
the run produces handoffs and never work. Relay refuses to start below 100k.

**Untracked files.** Relay stages modified tracked files plus untracked files
that `.gitignore` does not exclude. Anything else writing into the working tree
while a session runs — another agent's scratch directory, editor droppings —
gets committed with the work. Gitignore that scratch before pointing relay at
the repository.

## When it stops

| Exit | Meaning |
|---|---|
| 0 | complete, and verified |
| 20 | blocked — a human is needed; see `BLOCKED.md` |
| 21 / 26 | no progress across several sessions / sessions exiting immediately |
| 22 / 23 / 24 | repeated timeouts / session cap / you asked it to stop |
| 25 | another supervisor holds this project |
| 27 / 29 | repeated false completion claims / budget or usage limit |
| 78 | preflight failed — relay never started |

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
