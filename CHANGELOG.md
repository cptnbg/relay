# Changelog

Keep-a-Changelog format. Versions follow SemVer, with one addition: a change
that relaxes any commitment in `SECURITY.md` is a MAJOR bump and invalidates
recorded user consent.

## [Unreleased]

### Added
- Supervisor chain loop: predicate-driven session chaining that never trusts
  `claude`'s exit code.
- Context guard delivered per-invocation via `--settings`; relay registers no
  global hooks.
- OS sandbox enabled by default with `failIfUnavailable`, proven enforced by an
  acceptance probe before every run.
- Filtered git staging with staged-diff secret scanning; halts rather than
  committing a detected credential.
- Three-tier model ladder (sonnet subagents, opus orchestrator, fable
  escalation) with automatic escalation before the circuit breaker.
- Structured `continue.json` handoffs with schema validation, nonce fencing,
  injection filtering, and a guardrail-drift halt.
- `relay doctor` preflight gate.
- Zero-API-cost test harness: mock `claude`, runner, 27 hook tests, git and
  primitive suites.
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

### Fixed
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
