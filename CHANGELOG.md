# Changelog

Keep-a-Changelog format. Versions follow SemVer, with one addition: a change
that relaxes any commitment in `SECURITY.md` is a MAJOR bump and invalidates
recorded user consent.

## [Unreleased]

## [1.0.0] - 2026-08-26

MAJOR because it relaxes a `SECURITY.md` design commitment (#4). Recorded
consent is invalidated: the consent notice changed, so `/relay-doctor` refuses
every existing project until `/relay-init` is re-run and the current notice
re-accepted. That is the mechanism working as designed, not a regression.

### Added
- `sandbox_mode` (`config.json`, default `enforced`). `disabled` is a per-project,
  consented, full-trust opt-in that turns the OS sandbox **off**, so sessions can
  SSH to hosts, reach any network, and read anything the user can read. It exists
  because relay was unusable for work that legitimately needs live hosts —
  deploying, operating a server, probing infrastructure — where the sandbox is
  not a nuisance to work around but a hard stop.
- A full-trust acceptance probe, `relay_settings_probe_disabled()`. With no
  sandbox, "canary readable and host reachable" describes both a healthy run and
  a payload the CLI silently discarded, so the discriminator is relay's own
  inline hook: the probe supplies the environment the hook needs and requires
  `run/hook.alive` to appear, plus a readable canary proving the sandbox really
  is off. Egress becomes journal-only there and never refuses.
- `sandbox_mode` recorded in `state.json`, announced as the first line of
  `/relay-status`, and warned about by `/relay-doctor` on every run.
- Seven test cases (`c230`-`c236`) covering payload shape, preflight refusal of
  an unknown mode, healthy full-trust end to end, both new probe refusals,
  probe-cache invalidation on a mode switch, and guardrail-drift still arming in
  full-trust mode. Three new mock probe modes (`open`, `dropped`, `confined`).

### Changed
- `SECURITY.md` commitment 4 now states the invariant relay actually enforces:
  it refuses to run unless it can prove the settings payload was accepted. The
  sandbox is that proof in `enforced` mode; the sandbox is switched off only by
  explicit operator opt-in, never inferred and never as a fallback.
- The consent notice describes full-trust mode plainly, including that the
  remaining deny-list entries stop accidents rather than intent once the sandbox
  is gone.
- In `disabled` mode the deny list keeps only the never-push entries and the
  write-persistence guards; operational commands, credential reads and the web
  tools are all permitted.

### Unchanged, deliberately
- The `enforced` payload is byte-for-byte identical, so existing probe caches
  stay valid and every prior guarantee holds for projects that do not opt in.
- `--dangerously-skip-permissions` remains forbidden in both modes; relay still
  never pushes; `--setting-sources user` and `--strict-mcp-config` are still
  always passed.
- The guardrail-drift filter is not weakened in full-trust mode. RUN.md instead
  gives sessions the phrase "full-trust mode", which is accurate and does not
  trip it.

## [0.1.0] - 2026-08-18

### Added
- Supervisor chain loop: predicate-driven session chaining that never trusts
  `claude`'s exit code.
- Context guard delivered per-invocation via `--settings`; relay registers no
  global hooks.
- OS sandbox enabled by default with `failIfUnavailable`, proven enforced by an
  acceptance probe before every run.
- Filtered git staging with a secret scan over the full staged content;
  halts rather than committing a detected credential.
- Three-tier model ladder (sonnet subagents, opus orchestrator, fable
  escalation) with automatic escalation before the circuit breaker.
- Structured `continue.json` handoffs with schema validation, nonce fencing,
  injection filtering, and a guardrail-drift halt.
- `/relay-doctor` preflight gate.
- Zero-API-cost test harness: mock `claude`, a plain-shell runner, and the
  hook, supervisor, git and primitive suites.
- `permissions.allow` in the settings payload. Under `--permission-mode dontAsk`
  anything not explicitly allowed is refused, so a deny-only payload produced
  sessions that could not write a file.
- Preflight refusal for a context window below 100k, with the reason: a session
  holds tens of thousands of tokens before its first tool call, so a smaller
  window makes the guard fire critical immediately and forever.
- `test/lint/probe0-permission-mode.sh`, the paid probe recording the above
  against the real CLI, including that `deny` still beats a broad `allow`.

- `allow_domains` in config, so the sandbox egress allowlist can include the
  package registries a project actually needs.
- Per-session context-baseline measurement, journaled and recorded, plus a
  preflight refusal when the configured window does not clear it.
- Session-log pruning (`relay_prune_sessions`), which the README already
  promised.
- `plan_path` recorded by `init` into `config.json`, with a preflight refusal
  when the plan file does not exist — a run pointed at a nonexistent plan used
  to build silently from nothing but RUN.md and the previous handoff.
- `exec.json` written by `init` (or an explicit, warned waiver recorded), so
  acceptance verification is no longer silently skipped when the interview
  configured one; doctor warns when no acceptance command is configured.
- `model_tier` validated at preflight against `opus|sonnet|fable`; a junk
  value used to silently become `window_opus` and be passed to `--model`.
- `defaults.json` completed with the four keys `cfg()` reads that it never
  carried (`plan_path`, `allow_domains`, `keep_sessions`, `keep_days`), with a
  plugin-layer lint that fails if the two ever diverge again.
- `status` now reads the run lock's owner pid and reports a live supervisor
  apart from a stale `state.json` that still says `running`; `resume`
  documents that config is re-read on relaunch while the counters in
  `state.json` persist, and triages the security-event BLOCKED variants apart
  from ordinary blockers.
- A "Resolve the plugin root" section in SKILL.md, used by every command:
  `${CLAUDE_PLUGIN_ROOT}` is not set in the Bash tool environment, so every
  `bash "${CLAUDE_PLUGIN_ROOT}/scripts/..."` invocation failed — invisibly in
  `run`, behind `nohup`, while the user was told a build was in progress. The
  resolver falls back to a bounded search of the plugin cache and fails
  loudly instead of guessing; `run` now also proves the supervisor started by
  checking the lock owner's pid.

### Fixed
- `verify_complete()` conflated "this run made no commits" with "no work was
  done": a resume after the work was already finished was rejected three
  times for `no commits were made` — while the acceptance command passed the
  entire time — and burned three sessions to reach exit 27. When an
  acceptance command is configured it now runs first and, if it passes, a
  no-new-commit COMPLETE is accepted and journaled
  (`complete.no-new-commits`); with no acceptance command the commit count
  remains a hard veto.
- A handoff with the right structure but over-long entries was discarded whole,
  losing the session's position and forcing a recovery session. Entries are now
  truncated to the cap and used; genuinely malformed handoffs are still dropped.
- Review cadence was `N % review_every`, which could schedule a review
  immediately after a review. It is now measured from the last review.
- The extra-domains argument to the settings builder was never passed, and the
  code behind it concatenated command substitutions — so the first extra domain
  would have been glued onto `api.anthropic.com`, destroying both.
- Usage-limit detection read the whole session log, so any log containing the
  digits `429` — a session uuid was enough — was discarded and re-run. It now
  reads the result envelope, and a successful result is never a usage limit
  whatever its prose says.
- The acceptance command was re-quoted into a string and `eval`'d, which gave a
  shell to any element containing a quote. Elements now load into positional
  parameters and execute directly.
- **The single-instance lock failed open when `ps` was unusable.**
  `_relay_lock_try_break()` read any non-zero `ps -p <pid>` as "the owner is
  dead", but `ps` returns non-zero both when a process is gone and when it
  cannot run at all — inside relay's own sandbox it exits 127. A live
  supervisor's lock could therefore be deleted by a second supervisor, which
  then ran beside it on the same repository. Liveness is now established
  separately (`ps -p $$`), and when it cannot be established relay falls back
  to breaking only on age, as it already did for locks owned by another host.
- **`verify_complete()` skipped its "no commits were made" check entirely** when
  `commits_at_start` was empty, which is what `git rev-list --count HEAD` yields
  on a repository with no commits yet. A run could seal `COMPLETE.md` having
  committed nothing. Both counts are now normalised, and an unreadable count
  rejects rather than accepts.
- **The fast-fail circuit breaker counted productive sessions.** The streak
  incremented on wall-clock duration alone, so three sessions that each
  committed real work in under `min_session_secs` halted a healthy run with
  `EX_FASTFAIL`. Both counters now require the session to have produced
  nothing.
- **The acceptance probe never tested network egress**, while its own comment
  and `docs/security.md`'s standing rule 1 both said it did. It now attempts a
  connection to a host outside `network.allowedDomains` and refuses to start if
  that host answers. A result it cannot interpret is journaled as
  `probe.egress inconclusive` rather than being reported as blocked.
- **Compaction was sticky.** The supervisor cleared only `compacted.flag`,
  never the append-only `compaction.events`, so a single compaction pinned
  every later session into recovery mode — "reconstruct from git", at full
  cost — for the rest of the run. Both markers are now deleted once consumed.
- **Non-numeric config values failed open or crashed.** `max_sessions:
  "twelve"` made the cap comparison error out false (cap disabled),
  a non-numeric budget made the awk comparison string-compare (budget
  disabled), and any non-numeric inside `$(( ))` crashed exit 127 mid-loop
  under `set -u`. Every numeric config value is now shape-checked at
  preflight and refuses to run.
- **A genuine 429 could be missed.** `usage_limited()` matched the result
  envelope through `jq | head -c 8192 | grep -q` under `pipefail`; on a long
  result, `head` closed the pipe early, `jq` died on EPIPE, the pipeline went
  non-zero, and a real usage limit was scored as an ordinary failed session.
  The envelope is captured to a variable (jq applies the cap) and matched
  without a pipe.
- **A failed commit was invisible.** `relay_git_commit`'s operational-failure
  return (unmerged paths, `git add`/`commit` errors) was ignored, so real
  work sat uncommitted while the run drifted to `EX_STALLED` with nothing in
  the journal explaining why. It is journaled as `commit.failed` now.
- **A usage-limit retry destroyed the operator's note.** The note was consumed
  at the top of the iteration and truncated by the next before any session
  read it. It is prepended back to `INBOX.md` on retry
  (`inbox.preserved-on-retry`), and the backoff sleep step is adaptive so
  short backoffs are not rounded up and `STOP` is polled promptly.

### Security
- `.github/CODEOWNERS` added, claiming `plugins/relay/scripts/` and
  `plugins/relay/hooks/` — the enforcement half of CONTRIBUTING.md's
  second-maintainer rule (the branch-protection setting that gives it teeth
  still requires a published repository).
- **The session sandbox could reach relay's own control plane.** The
  sandbox's `allowWrite` included the whole state directory and `$TMPDIR`, so
  a prompt-injected session could rewrite `state.json` (forging a COMPLETE
  via `commits_at_start`), truncate `journal.log`, delete the run lock, or
  plant a git `post-commit` hook at the fixed scratch path that relay's next
  commit — outside the sandbox — would execute. State is now split into two
  trust zones: `$STATE/work/` is the only session-writable area (the sole
  `allowWrite` entry besides the project and `$TMPDIR`), everything
  supervisor-only stays at the state root out of reach, and relay's git
  scratch moved to per-process `mktemp` dirs under supervisor-only
  `$STATE/priv/`.
- **A file named `*` staged the whole repository.** `git add` interprets
  collected filenames as pathspecs; an untracked file literally named `*`
  matched everything — `.env`, keys, exactly what the filename filter had
  just refused. `relay_git` now passes `--literal-pathspecs` on every call.
- **A hostile `.gitattributes` could hide a secret from the pre-commit
  scan.** Marking a path `-diff`/`binary` makes `git diff --cached` emit
  nothing for it, and neither `--text` nor `core.attributesFile=/dev/null`
  overrides an in-tree attributes file. The scan now reads each staged blob's
  raw content with `git cat-file blob :0:<path>`.
- **The guardrail-drift halt silently never fired under ugrep.** The single
  drift regex exceeded ugrep's complexity limits (exit 2, no output) and was
  order-sensitive elsewhere, so the highest-priority injection halt was a
  no-op on affected machines. Replaced with two simple AND-ed patterns
  (permission word + danger word, order-insensitive), plus a startup
  self-test that refuses to run if either the injection or drift filter
  cannot be shown to fire under the live `grep`.
- **The injection filter filtered nothing while journaling "filtered N".**
  `handoff_render` prefixes each item with a `- ` bullet before the
  `^`-anchored filter ran, so no anchored pattern ever matched the rendered
  lines. The anchors now tolerate the bullet.
- **An uncomputable settings fingerprint skipped the sandbox proof.** If
  `git hash-object` failed, the fingerprint was empty — equal to the empty
  string a missing `probe.ok` yields — so the cache read as a hit and the
  probe was skipped. The fingerprint must now be a 40-hex blob id or relay
  refuses to run.
- **The egress verdict misread curl's error text.** It took the first
  three-digit run anywhere in the evidence file, so "…port 443…" in curl's
  own error message read as an HTTP status and a *blocked* host was reported
  `reachable`. The verdict now reads explicit `code=`/`rc=` markers. The
  probe also shell-quotes its paths (a `$HOME` with a space used to break
  the redirect and report "proven" having proven nothing), and canary-leak
  detection writes proof to a file instead of depending on the model echoing
  a DO-NOT-LEAK string.
- **`denyRead` entries are emitted with `~` expanded to `$HOME`**, so the
  credential deny list cannot go inert if a CLI version stops expanding
  tildes in `sandbox.filesystem.denyRead`.
- **`STATE` is canonicalised (`cd && pwd`)**, so doctor's "state dir outside
  the repository" check cannot be bypassed with a `../` path or a symlink.
- **Consent and command approval are now enforced, not just documented.**
  Doctor recomputes the consent notice's hash from the installed SKILL.md
  and refuses when `consent.notice_hash` is absent or stale — changing the
  terms forces re-consent. `exec.json` carries an `exec_hash` recorded at
  `/relay-approve` time; the supervisor verifies it at preflight and again
  from disk immediately before running the acceptance command, halting
  BLOCKED with reason `exec-hash-mismatch` on any disagreement.

### Changed
- `docs/{architecture,exit-codes,portability,troubleshooting}.md`, `README.md`
  and `docs/security.md` updated to describe the behaviour above. The four
  defects were all found by relay auditing its own source while documenting
  itself, and were reported rather than fixed at the time because that run was
  forbidden to modify executable files.
- Documentation trued up against the state relocation and the fixes above:
  the state layout is documented as two trust zones, the sandbox-probe docs
  describe proof-by-file and the `code=`/`rc=` egress markers, exit-code and
  troubleshooting line citations re-derived from the current source, signal
  exits (129/130/143) and the bash-gate 78 documented, `curl` recorded as the
  probe's optional soft dependency, README documents `allow_domains`,
  `keep_sessions`/`keep_days`, `RELAY_NOTIFY_CMD` and `/relay-approve`, and
  the false claim that relay redacts its logs was removed.
