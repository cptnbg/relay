# Phase 5 — publish prep

The remaining work before `cptnbg/relay` can be published. Derived from the
approved plan's *Packaging*, *Supply chain* and *Build order Phase 5* sections;
this file is the canonical task list for the run that does it.

Everything here is documentation and repository metadata. **No behavioural
change to any script is in scope** — see the guardrail note at the end, which
is not stylistic advice but a mechanical hazard.

## 1. `docs/architecture.md`

How relay actually works, for someone deciding whether to trust it.

- The chain loop: what happens between `relay run` and the first session, and
  between one session ending and the next starting.
- **Why the exit code of `claude` is never trusted**, and what is trusted
  instead: sealed sentinels, commit counts, tree cleanliness, handoff hash.
  Name the two observed cases — exiting 0 after killing background subagents,
  and exiting 0 having done nothing.
- The post-exit predicate order, as it is in `relay-supervisor.sh`, and why
  guardrail drift is checked before anything else.
- State layout under `~/.local/state/relay/projects/<hash>/`: what each file is
  and which of them a human is ever expected to read.
- The handoff: the `continue.json` schema, how it is rendered into the next
  prompt, and why it is structured rather than prose.
- The model ladder and the escalation rules, including the one-shot return to
  the default tier.
- Where the context guard sits, what it reads, and what it emits at each level.

Diagrams are welcome but must be ASCII, and must match the code.

## 2. `docs/exit-codes.md`

One table, every exit code the supervisor can produce, taken from the `EX_*`
constants in `relay-supervisor.sh` — verify each against the source rather than
copying the README. For each: what it means, what the user should look at
first, and whether `relay resume` is the right next step.

## 3. `docs/portability.md`

The dependency policy and the reasons behind it.

- Hard dependencies and their minimum versions.
- The deliberately-excluded list (node, python3, perl, `flock`, `timeout`,
  `setsid`, `shasum`, `bc`, `realpath`, `readlink -f`, `stat`, `grep -P`,
  `sed -i`, `date -d`) and, for each of the interesting ones, the portability
  fact that excluded it.
- The bash 3.2 constraints: no associative arrays, no `mapfile`, no `${v^^}`,
  and the `set -u` + empty-array trap this codebase hit.
- Why `set -e` and `trap ... ERR` are banned here specifically, not as a general
  style preference.
- How `test/lint/no-bash4.sh` and `test/lint/no-deps.sh` enforce all of it, and
  what a contributor sees when they trip one.

## 4. `docs/troubleshooting.md`

Symptom-first. Each entry: what the user sees, what it actually means, what to
run next. Cover at minimum:

- "It refuses to start" — the preflight failures: window below the floor, a
  non-argv `acceptance_cmd`, doctor failing, the sandbox probe failing.
- "The sandbox probe failed" — what that proves, and why relay will not run
  anyway.
- "Every session hands off immediately" — the context window is at or below the
  session's baseline context.
- "A session ended after a few minutes with `rc=1`" — how to read
  `session.reason` in the journal, and that a budget cap is not a crash.
- "It says BLOCKED and I do not know why" — where `BLOCKED.md` is, and the
  guardrail-drift case specifically.
- "It committed something I did not expect" — relay stages untracked
  non-ignored files; gitignore other tools' scratch.
- "Nothing is happening" — where the journal, the session logs and `ctx.log`
  are, and what a healthy `ctx.log` line looks like.
- **The self-hosting hazard**, see below.

## 5. `CONTRIBUTING.md`

- 2FA required, protected default branch, no force-push.
- **Any diff touching `plugins/relay/hooks/` or `plugins/relay/scripts/`
  requires a second maintainer.** State that this is enforced by branch
  protection, not by convention.
- How to run the suites, and that `test/run.sh` must make zero API calls.
- The paid probes under `test/lint/probe0-*.sh`: what they cost, when to re-run
  them (any CLI version change), and that a claim about CLI behaviour is not
  accepted without one.
- The rule that a change relaxing any commitment in `SECURITY.md` is a MAJOR
  version bump and invalidates recorded user consent.

## 6. `RELEASING.md`

The release procedure, written so it can be followed exactly.

- Version bump in both manifests, in lockstep, kebab-case names matching.
- `claude plugin validate --strict` on both manifests.
- Full suite plus both linters plus shellcheck at CI severity.
- Tag, **signed**, and the `git verify-tag` command a user runs to check it.
- Producing the release archive and its sha256, and where that sha256 goes in
  the marketplace entry — an archive source pinned by hash, never a bare GitHub
  source tracking a mutable branch.
- The statement that relay never auto-updates and users should read the diff.

## 7. README additions

- Keep the honest-limitations section **above** the install instructions. Do not
  move, soften, or summarise it.
- Add the maintainer key fingerprint as a clearly-marked placeholder for the
  owner to fill in, and the `git verify-tag` invocation.
- Link the four new docs and `RELEASING.md`.

## Acceptance criteria

`bash test/publish-check.sh` exits 0. It asserts every file above exists with
real content, that the README limitations section still precedes install, and
that both plugin manifests pass `claude plugin validate --strict`.

Beyond that gate, and provable only by reading:

- Every factual claim in `exit-codes.md` and `portability.md` matches the
  source. Check them against the code, not against the README.
- No file under `plugins/relay/scripts/`, `plugins/relay/hooks/` or
  `test/bin/` was modified.

## The guardrail that is a mechanical hazard, not a preference

This run is relay building relay. **bash reads a script incrementally while
executing it**, so editing `relay-supervisor.sh`, `relay-lib.sh`,
`relay-git.sh`, `relay-settings.sh` or `relay-ctx.sh` while the supervisor is
running them can make the running process execute garbage — a corrupted
overnight run whose journal will not explain itself.

So: this run does not modify any executable file. If a session finds a genuine
bug in one, it records it in `HUMAN-TASKS.md` with the evidence and keeps going
on documentation. That is a real finding worth having, and it is worth nothing
if it takes the run down with it.
