---
name: relay
description: Start, monitor, steer, or stop an autonomous multi-session build run. Use for "/relay init <plan>", "/relay run", "/relay status", "/relay stop", "/relay note", "/relay resume", "/relay doctor", or any request to run a long multi-phase plan to completion unattended.
argument-hint: "init <plan-path> | run | status | stop | note <text> | resume | approve | doctor"
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion
---

# relay

Relay runs a long multi-phase plan to completion across automatically chained
Claude Code sessions. Each session works until its context fills, writes a
handoff, and ends; a supervisor verifies what actually happened and launches a
fresh session from that handoff. It keeps going until the plan's acceptance
criteria are proven, a human is genuinely needed, or a safety rail trips.

**You are the front end.** The supervisor is a detached bash process. Your job
is the interview, the consent gate, and the control commands — never to be the
runner yourself. After `run`, your session ends and the build continues without
you.

## Paths

```
PROJECT = the git repository being built (the user's cwd unless stated)
STATE   = ~/.local/state/relay/projects/<git blob hash of PROJECT realpath>
```

State lives **outside the repository** deliberately: the repo is writable by the
agent and by anything a build script runs, so relay's own files must not sit
where they can be replaced with symlinks. The directory name is the 40-hex
SHA-1 git blob hash of the path — `git hash-object`, not `sha256sum`, because
git is already a hard dependency and `sha256sum` is not portable. Compute STATE
with:

```bash
PROJ=$(cd "<project>" && pwd)
H=$(printf '%s' "$PROJ" | git hash-object --stdin)
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/relay/projects/$H"
```

Scripts live at `${CLAUDE_PLUGIN_ROOT}/scripts/`. Always invoke them as
`bash "<path>"` — never rely on the executable bit surviving installation.

---

## `init <plan-path>`

The interview exists so the run does not stall at 3am on a question a human
could have answered in advance.

**1. Read everything first.** The named plan in full, including every amendment
section. Then the project's CLAUDE.md, and any existing `.continue-here.md` or
`.planning/STATE.md`. Do not skim: the quality of the interview depends on
knowing what the plan actually demands.

**2. Hunt for what will need a human.** Specifically look for:
- credentials, accounts, API keys, or access the plan assumes
- irreversible or destructive actions (deploys, migrations, deletions, spend)
- requirements with more than one defensible reading
- external gates (DNS, payments, third-party approval)
- anything the plan explicitly defers "to the owner"

**3. Ask, in batches, with `AskUserQuestion`.** Cover the unknowns you found,
plus: the model tier and its context window, session and total budget caps,
max sessions, wall-clock cap, review cadence, and the acceptance command that
proves the work is done.

Secrets are recorded **by path, never by value**. If the user supplies a secret
inline, write it to their existing secrets location and reference that path.

**4. Write `$STATE/RUN.md`.** This is re-read by every session, so it is the
anti-drift instrument. Sections:

```markdown
# RELAY RUN — <project>
## Mission                  (2-4 sentences; what done looks like)
## Canonical plan           (path; the plan is the source of truth)
## Acceptance criteria      (concrete and checkable; what COMPLETE.md must prove)
## Decisions already made (DO NOT RE-ASK)
## Credentials & access     (paths only, never values)
## Guardrails               (what is out of bounds; relay never pushes)
## Delegation rules         (orchestrator-lean; subagents get paths, not contents)
## Course corrections       (appended by review sessions only)
```

**5. Write `$STATE/config.json`** from `${CLAUDE_PLUGIN_ROOT}/config/defaults.json`
merged with the interview answers. This file may hold **settings only, never
commands**. Commands live in `$STATE/exec.json` (see `approve`).

**6. Consent gate.** Show this and require the user to type the word `relay`:

```
relay runs Claude Code unattended, in a loop, with permission prompts
suppressed. While it runs:

  * It reads, writes, and DELETES files in this project without asking.
  * It creates git commits without asking. It NEVER pushes.
  * It spends money on your account, up to the caps you just set, then stops.
  * A sandbox restricts filesystem reads and network egress. If the sandbox
    cannot start, relay refuses to run.
  * A deny list blocks sudo, push, docker, cloud CLIs and credential reads.
    A deny list is NOT a sandbox.
  * Your build and test commands still execute arbitrary repository code with
    your full privileges. The sandbox confines that; the deny list cannot see
    inside it.

Do not run relay on a repository you would not `npm install && npm test`
without thinking. Do not run it where a mistake is expensive.
```

Record the acceptance in `$STATE/config.json` as `consent` with a timestamp and
a hash of the notice text, so a future change to these terms forces a re-read.

**7. Run doctor** and fix anything it reports before telling the user they are
ready.

---

## `run`

1. Refuse if `$STATE/state.json` reports a run already active — point at `status`.
2. Refuse if `$STATE/config.json` has no recorded consent — point at `init`.
3. Launch detached, and then **end your turn**:

```bash
nohup bash "${CLAUDE_PLUGIN_ROOT}/scripts/relay-supervisor.sh" "$PROJ" "$STATE" \
  >>"$STATE/supervisor.out" 2>&1 & disown
```

4. Tell the user how to watch (`tail -f $STATE/journal.log`), how to steer
   (`/relay note`), and how to stop (`/relay stop`).

Do not stay alive polling the run. The whole point is that it does not need you.

---

## `status`

Read and summarise — no side effects:
- `$STATE/state.json`: status, session count, tier, stall/fastfail counters, cost
- the last ~20 journal lines
- the current position from `$STATE/continue.json` (`next` is the live answer to
  "what is it doing right now")
- open items in `$STATE/HUMAN-TASKS.md`
- whether `BLOCKED.md` or `COMPLETE.md` exists

Present it as prose a person can read on a phone, not a data dump.

---

## `stop`

`touch "$STATE/STOP"`. Explain: the running session finishes its current step
and hands off cleanly, then the supervisor exits. Resume later with
`/relay resume`.

---

## `note <text>`

Append the text to `$STATE/INBOX.md`. The next session reads it and treats it as
operator guidance. This is how the user redirects a running build **without
stopping it** — the main reason relay is steerable from a phone.

---

## `resume`

1. If `$STATE/BLOCKED.md` exists, read it to the user and confirm the blocker is
   actually resolved.
2. Append the resolution to RUN.md under "Decisions already made (DO NOT
   RE-ASK)", so no future session re-raises it.
3. Delete `BLOCKED.md` and any `STOP`.
4. Launch as in `run`. Never re-run the interview.

---

## `approve`

Commands the supervisor executes (the acceptance command, notification hooks)
live in `$STATE/exec.json` as **argv arrays**, never shell strings:

```json
{ "acceptance_cmd": ["npm", "test"] }
```

Show the exact argv and require explicit confirmation. Store a hash alongside;
any later change to a command requires re-approval.

**A repository can never make relay run a command.** `.relay/config.json` in a
repo holds settings only. If you find a command-bearing key in a repo-tracked
config, refuse and tell the user.

---

## `doctor`

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/relay-doctor.sh" "$PROJ" "$STATE"
```

Exit 78 means relay will not start. Relay reports remedies and never applies
them: it does not modify anything outside its own state directory.

---

## Things to get right

- **Never start a run without doctor passing.** It is the gate.
- **Never edit `$STATE/continue.json` by hand** unless recovering a broken run;
  it is the machine handoff and it is schema-validated.
- **Never put a secret in RUN.md, config.json, or a handoff.** Paths only.
- **Never suggest `--dangerously-skip-permissions`.** Relay's sandbox and deny
  list depend on it never being used.
- If the user asks relay to push, explain that it never will, by design, and
  that reviewing `git log -p` before pushing is the intended workflow.
