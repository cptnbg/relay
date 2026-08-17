# Contributing

This repository has no remote configured yet — `.git/config` in this checkout
has no `[remote ...]` section, so `github.com/cptnbg/relay` does not exist as
a push target here. Everything below is stated as policy for the published
repository, not something already verified against a live GitHub setting.

## Access

- Every account with write access to the published repository requires
  two-factor authentication.
- The default branch is protected. Changes land through a reviewed pull
  request, not a direct push.
- Force-push to the default branch is disabled.

## `plugins/relay/hooks/` and `plugins/relay/scripts/` need a second maintainer

Any diff that touches a file under `plugins/relay/hooks/` or
`plugins/relay/scripts/` requires review and approval from a second maintainer
before it can merge — not the same person who wrote the diff. The reason is
the same one covered in full under "The self-hosting hazard" below: these are
the files relay's own supervisor executes, sometimes while a relay session is
the one proposing the change, and a single missed review here is a corrupted
overnight run, not a filed bug.

This is meant to be enforced by the repository, not by a note in a file that a
reviewer could skip under time pressure. The mechanism on GitHub is a
`CODEOWNERS` entry claiming those two paths, plus branch protection with
*Require review from Code Owners* enabled on the default branch — path-scoped
review is a CODEOWNERS feature, and branch protection alone cannot express it.

**Not yet in force.** At the time of writing this repository has no remote, so
neither file nor setting exists. Until a maintainer creates them, the paragraph
above describes intent rather than enforcement, and a reader should treat it
that way. Setting it up is a release blocker, tracked with the other
publish-time owner tasks.

## Running the suites

Two standalone unit suites:

```
bash test/lib/test-relay-lib.sh
bash test/lib/test-relay-git.sh
```

The hook and supervisor suite, which discovers and runs every file under
`test/cases/` and `test/hook/` (`test/run.sh:61-69`):

```
bash test/run.sh
```

Both static linters:

```
bash test/lint/no-bash4.sh
bash test/lint/no-deps.sh
```

CI (`.github/workflows/ci.yml`) runs all of the above, plus `shellcheck -s
bash -S warning` over the shipped scripts, the test libraries and the mock
(`.github/workflows/ci.yml:14-21`), and reruns `test/run.sh` explicitly under
macOS's own `/bin/bash` 3.2.57 in addition to whatever bash a Linux runner
ships (`.github/workflows/ci.yml:86-88`). Matching that locally before
opening a pull request is cheaper than finding out a bash-3.2-only construct
broke on the runner.

If a suite fails in a way that looks unrelated to what you changed and
you're in a sandboxed or containerized environment, read
`docs/portability.md`'s section "The lock's undeclared exception" before
assuming your change is at fault — it documents a real, environment-dependent
gap in the lock's staleness check that predates any change you're likely
making.

### `test/run.sh` must make zero API calls

This is not a request for restraint; it is mechanically enforced.

`test/run.sh` builds a fresh sandbox per test case (`mktemp -d`,
`test/run.sh:113`) and, inside it, sets `PATH="$ROOT/test/bin:$PATH"`
(`test/run.sh:134`) alongside a sandboxed `HOME` and `CLAUDE_CONFIG_DIR`
(`test/run.sh:128-132`). Every `claude` invocation any script under test
makes therefore resolves to `test/bin/claude`, a bash mock driven entirely
by environment variables such as `RELAY_MOCK_SCRIPT` (`test/bin/claude:1-8`),
never the real network binary. The mock is not just inert stand-in: it
actively refuses to run if it is ever asked to pass
`--dangerously-skip-permissions`, `--bare`, `--no-session-persistence` or
`--safe-mode` (exit 99, `test/bin/claude:66-73`), and refuses to run unless
both `--setting-sources` (it records the value but asserts only presence,
`test/bin/claude:119-120,141-144`) and `--strict-mcp-config` are present in
argv (exit 98, `test/bin/claude:141-148`) — so it also catches a regression of
relay's own settings-trust fix, not only stray API spend.

`test/run.sh` also runs a self-check as its very first case
(`test/run.sh:158-167`): it asserts `command -v claude` resolves to exactly
`$ROOT/test/bin/claude`. If a local `PATH`, a careless test fixture, or a
future change ever let the real CLI shadow the mock, this fails loudly
instead of quietly billing an account.

Keep it that way as a contributor:

- Never invoke `claude` by an absolute or otherwise `PATH`-bypassing path
  inside a test file — that defeats the shadow above.
- Never add a test that needs the real CLI's actual behaviour under
  `test/cases/` or `test/hook/`. Those are the only two directories
  `test/run.sh` discovers (`test/run.sh:61-69`); anything you put there runs
  automatically, on every contributor's machine and in CI, with zero API
  budget available to it.
- If you need to observe the real CLI, write a new `test/lint/probe0-*.sh`
  instead — paid, run by hand, exactly like the five described next.

## The paid probes (`test/lint/probe0-*.sh`)

These make real, billed API calls against the actual Claude Code CLI. They
are deliberately outside `test/run.sh`'s discovery path and CI never runs
them (`probe0-permission-mode.sh` says so of itself,
`probe0-permission-mode.sh:5-8`; `.github/workflows/ci.yml` confirms it by
omission — none of the five `probe0-*.sh` files are referenced anywhere in
that workflow). Each probe caps its own per-invocation spend with
`--max-budget-usd` and defaults to the `haiku` model. What each one
establishes, and the caps recorded in the source:

- **`probe0-settings-trust.sh`** — four invocations, `--max-budget-usd 0.05`
  each (`probe0-settings-trust.sh:52`). Establishes whether a repository's
  own `.claude/settings.json` hooks and `.mcp.json` execute under
  `claude -p`, and whether `--setting-sources user` / `--strict-mcp-config`
  suppress them (`docs/security.md`, finding 1).
- **`probe0-settings-hooks.sh`** — one invocation, `--max-budget-usd 0.10`
  (`probe0-settings-hooks.sh:52`). Establishes that a `SessionStart` and a
  `PostToolUse` hook delivered through an inline `--settings` payload
  actually fire — the entire basis for relay shipping zero global hooks
  (`docs/security.md`, finding 2). It also records the `--output-format
  json` result envelope's top-level keys and usage/cost fields
  (`probe0-settings-hooks.sh:65-72`).
- **`probe0-sandbox.sh`** — three invocations, `--max-budget-usd 0.10` each
  (`probe0-sandbox.sh:53`). Establishes that the OS-level sandbox,
  configured entirely through inline `--settings`, actually blocks a
  credential-file read and actually blocks network egress to a
  non-allowlisted host, with a disabled-sandbox control case so a probe that
  "passes" by failing to observe anything is itself caught
  (`docs/security.md`, finding 3).
- **`probe0-integration.sh`** — one invocation, `--max-budget-usd 0.10`
  (`probe0-integration.sh:74`). Establishes that relay's real settings
  payload, exactly as `relay_settings_build` emits it, is simultaneously
  accepted by `claude -p`, fires relay's context hook in exec form
  (including when the hook path and project path both contain a space), and
  enforces sandbox `denyRead` — together, not as three claims tested in
  isolation (`docs/security.md`, finding 4).
- **`probe0-permission-mode.sh`** — four invocations, `--max-budget-usd 0.15`
  each (`probe0-permission-mode.sh:70`). Establishes what
  `--permission-mode dontAsk` actually permits: a deny-only payload refuses
  a plain project-local `Write` (case A), a broad `allow` list lets that
  same write through (case B), a bare `Read` allow rule reaches outside the
  working directory (case C), and a specific `deny` rule still wins over a
  broad `allow` (case D). This is the probe that found relay's first shipped
  settings payload could not write a single file
  (`docs/security.md:114-118`).

No total dollar cost for a full run of all five is recorded anywhere in this
repository. The figures above are per-invocation caps taken directly from
the scripts, not measured spend — treat them as an upper bound, not a
receipt, and do not read anything more precise into them than that: they
make real, billed API calls.

Re-run all five whenever the Claude Code CLI version changes, not only the
one whose surface you believe you touched. `docs/security.md` states plainly
that every finding in it "was verified empirically against Claude Code
2.1.233" (`docs/security.md:3-4`), and its own standing design rules record
that a version change "forces re-running doctor, because the settings
schema may have moved" (`docs/security.md:151-152`) — the same reasoning
applies to the probes that established those settings behave the way relay
assumes. A claim about CLI behaviour — anything of the shape "Claude Code
does X when given flag Y" — is not accepted into this repository, in
documentation or in code, without a probe run against the version being
claimed. Manual testing during development is not a substitute for a probe;
manual testing is exactly what missed the `--permission-mode dontAsk`
default-deny behaviour the first time (`docs/security.md`, finding 6).

## Relaxing a `SECURITY.md` commitment is a MAJOR version bump

`SECURITY.md` lists six load-bearing commitments and says directly: "These
are load-bearing. A change that relaxes one is a MAJOR version bump and
invalidates recorded consent" (`SECURITY.md:35-36`). `CHANGELOG.md` repeats
the same rule as part of its own versioning policy: Keep-a-Changelog format,
SemVer, "with one addition: a change that relaxes any commitment in
`SECURITY.md` is a MAJOR bump and invalidates recorded user consent"
(`CHANGELOG.md:3-5`).

Concretely: a pull request that makes `--dangerously-skip-permissions`
reachable under any flag or config, lets relay push to a git remote, stops
passing `--setting-sources user` or `--strict-mcp-config` on some code path,
weakens the refusal to run when the sandbox cannot be proven enforced, adds
a global hook, or lets a repository-tracked config cause relay to execute a
command — any of the six commitments in `SECURITY.md` — is not an ordinary
feature or bugfix. It requires a MAJOR version bump on its own, regardless
of what else ships in that release, and it means every user who already
consented to run relay under the old commitments is treated as having
consented to nothing under the new ones. State this explicitly in the pull
request description. Do not leave a reviewer to infer it from the diff.

## The self-hosting hazard

Relay develops relay, and that is not a metaphor: the plan a relay session
is executing and the code its own supervisor is currently running can be the
same five files. `docs/troubleshooting.md`'s "I want to run relay on relay's
own repository" section covers the mechanics in full. The short version for
a contributor: bash reads a script incrementally while executing it, so a
session that edits `relay-supervisor.sh`, `relay-lib.sh`, `relay-git.sh`,
`relay-settings.sh` or `relay-ctx.sh` while the supervisor running that same
session is partway through one of those files can end up executing garbage
mid-function — not a clean crash, a corrupted run whose journal will not
explain itself.

If you are using relay to work on relay, treat those five files as
read-only for that run. If a session finds a genuine bug in one of them,
have it record the bug in a durable note with evidence and keep going on
work that does not touch executables; land the actual fix in a separate,
non-self-hosted change reviewed the normal way — including, per the second
maintainer rule above, by someone other than whoever wrote it.
