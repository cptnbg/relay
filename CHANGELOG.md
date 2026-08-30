# Changelog

Keep-a-Changelog format. Versions follow SemVer, with one addition: a change
that relaxes any commitment in `SECURITY.md` is a MAJOR bump and invalidates
recorded user consent.

## [Unreleased]

## [1.2.0] - 2026-08-30

Subscription-aware budgeting. relay's budgets were API-shaped — dollars in the
interview, dollars in the caps — while a Pro/Max operator does not spend
dollars: they spend a share of a usage window, and the envelope's
`total_cost_usd` is a notional API-equivalent their plan covers. This release
lets the operator budget in the units they actually spend, without relay ever
fabricating plan limits Anthropic does not publish. **No commitment relaxed,
consent notice unchanged, enforced payload untouched.**

### Added
- **`billing`** (config, `api` default | `subscription`): vocabulary, never
  mechanics — it drives how `/relay-init` frames budget questions and what
  doctor advises; every gate works in both modes. Journal `billing.mode`.
- **Token accounting, always on**: each session's envelope usage (input +
  cache_creation + cache_read + output — relay's own documented metric) is
  journaled as `session.tokens` and accumulated as `tokens_total` in
  state.json.
- **`budget_tokens_total`** (0 = off): the run-level budget in tokens — the
  twin of `budget_usd_total`. Pre-spawn gate; exit 29 with
  `reason: "tokens"`.
- **`budget_tokens_per_session`** (0 = off): the per-session tripwire.
  Post-hoc by necessity — `--max-budget-usd` is the only mid-session stop
  the CLI offers — so it bounds the NEXT sessions: one breach forces a
  review, a clean session resets the streak, two consecutive breaches exit
  29 with `reason: "session-tokens"`. The streak is per launch, like
  LIMIT_RETRIES: resuming is the operator's decision to continue.
- **`plan_window_tokens`** (0 = unset): the operator's OWN estimate of their
  plan window, the denominator for every percent relay shows or asks. The
  interview points at `/status` or a usage tool to gauge it and never
  supplies a number itself — a fabricated denominator is worse than none.
- The review digest always shows `tokens:` (with budget and percent-of-window
  when configured); `/relay-status` reports `tokens_total` and presents
  `cost_total` as notional under subscription billing.
- Doctor advises a subscription project with no token budget that its only
  run-level rail is the notional USD cap.
- Mock: `RELAY_MOCK_USAGE_IN` (per-invocation input_tokens override) for
  token-budget tests. New cases c272-c274.

### Changed
- The interview asks `billing` first; on `subscription` it asks for percent
  allocations of the stated window and writes the token figures, and reframes
  the USD caps honestly as notional runaway guards (suggesting ≥5.00 per
  session so the guard trips on runaways, not normal work).
- `docs/exit-codes.md` EX_BUDGET now documents four causes split by
  status+reason.

## [1.1.0] - 2026-08-30

Long-run autonomy: zero permission friction in full-trust mode, a run that
carries its own arc, mechanical plan alignment, and machine-run checkpoints —
built for multi-hour, tens-of-sessions builds with the sandbox off. **No
SECURITY.md commitment is relaxed and the consent notice text is unchanged**,
so no project that consented under 1.0.x owes a new acceptance. The enforced
settings payload remains byte-identical to 1.0.0's when the new config keys
are unset.

### Added — permissions and resilience
- **WebFetch and WebSearch are allowed in `disabled` mode** (and only there:
  in `enforced` their in-process egress versus the sandbox allowlist is
  unverified, so they stay denied). In full trust the network was already
  open to curl; the refusal was pure friction, observed as real
  `permission_denials` in run telemetry.
- **`allow_tools_extra`** (config, default empty): extra tool names for the
  disabled-mode allow list — the escape hatch for tools relay has never heard
  of (a `Monitor` call from a newer harness was observed denied mid-run).
  Validated fail-closed in every mode; applied only under `disabled`;
  journaled as `permissions.extra-tools` with the mode, so "configured" and
  "applied" stay distinguishable.
- **Denial telemetry**: the supervisor parses `permission_denials` from each
  session envelope — journal `session.denials n= count= tools=`, running
  `denials_total`/`last_denial_tools` in state.json, one notification per run
  at ≥3 denials in a session. Probe-pinned envelope shape
  (probe0-permission-mode case E). Telemetry only; never touches control
  flow.
- **`max_wall_secs`** (config, default 0 = off): the wall-clock cap the init
  interview used to collect and silently discard now exists. Per launch,
  never persisted (a resume is a fresh window); checked pre-spawn and inside
  the usage-limit backoff sleep; exits 23 with `reason: "wall-clock"`.
- **A prompt rule that refusals are policy**: never retry the identical
  call, never write BLOCKED.md over a denial, route around it (curl for
  WebFetch, `git config --get remote.origin.url` for remotes).
- **Doctor warnings**: user-scope PreToolUse/PostToolUse hooks (they run
  inside relay sessions; a text-matching guard can deny mid-run); a project
  located under a deny-write or denyRead directory; full-trust + opus with
  `budget_usd_per_session` under 5 (a budget-capped session dies without
  writing a handoff).
- **A `long-haul` interview profile** in `/relay-init` that suggests sizing
  for tens-of-sessions runs — including saying the total dollar figure out
  loud.

### Added — context and alignment
- **The run ledger** (`$STATE/ledger.md`): one supervisor-written line per
  surviving session (mode, tier, productive, commits, step, sanitized
  done[0] note), rendered as the last 25 rows into every later prompt in a
  fence that names the rows unverified self-reports. Session 30 now knows
  how it got there without re-deriving the story from git log. Lives at the
  supervisor-only state root; re-filtered at render time.
- **The PLAN-INDEX protocol**: for large plans, init writes
  `$STATE/work/PLAN-INDEX.md` (ordered step ids, byte-exact plan headings,
  one-line acceptance) and sessions read the index plus ONLY their current
  step's plan section — recovering tens of thousands of tokens per session
  on large plans — with the full plan explicitly canonical on any conflict.
  A mid-run plan change now forces a review session (`index.stale`), which
  regenerates the index.
- **`plan_step` in the handoff schema** (optional, ≤64 chars, strict when
  present): the run's position becomes mechanical. Journaled per session,
  rendered under `PLAN STEP:`, preserved by normalization, EXCLUDED from the
  guardrail-drift scan on the same label-not-claim ground as files_touched
  (a phase named "enable token auth" must not halt the run every session).
- **Drift detection**: a plan_step going backward in index order forces one
  review session (never a halt), with a cooldown so one incident cannot
  cascade. Free-text steps opt out by construction (`drift.step-unknown`).
- **A mechanical review digest**: review sessions get supervisor-computed
  counters (sessions and commits since last review, breaker states, cost,
  gates, last step) and rewritten duties — verify the claimed position
  against git, spot-check done claims behaviourally, regenerate a stale
  index, append Course corrections only.
- **Phase gates** (`exec.json` `phase_gates`, opt-in, ≤8): human-approved
  argv checkpoints run mechanically when the reported step crosses each
  gate's `after_step`, and — for any gate still unpassed — at COMPLETE
  verification, before the acceptance command. One `gates_hash` over the
  canonical array (gates interact; changing any re-approves the set), the
  same dual in-memory anchor as the acceptance command, output captured to
  `run/gate-<id>.log`. First failure forces a review with the gate output
  injected as fenced data; a second failure of the same gate halts the run
  BLOCKED (`gate-failed`) — the owner-chosen boundary where autonomy ends.
- **The RUN.md integrity guard**: the region above `## Course corrections`
  (mission, guardrails, settled decisions) is hashed at launch — in memory,
  where no session can reach in either mode — and any change halts the run
  BLOCKED (`run-md-tampered`) with a bounded diff, before COMPLETE is even
  considered. Course-corrections appends never trip it; the legit-edit path
  is stop → edit → resume (a fresh supervisor re-baselines). A RUN.md
  without the marker is protected whole, loudly (`runmd.no-marker`).
- **Context-guard dead-band fix**: throttle bands retuned (30/50 instead of
  40/55) plus an unconditional rescan every 8th call, so a single-call
  context jump is seen within at most seven calls whatever the stale
  percentage claimed.

### Changed
- The broad `Bash(git remote:*)` deny is **gone from disabled mode** — and
  not narrowed, dropped, on probe evidence: a three-word deny prefix
  (`Bash(git remote set-url:*)`) never fires on Claude Code 2.1.251, so the
  planned mutator-only narrowing would have been decorative. `git push`
  (two-word, provably matched) still holds commitment 2; the
  rewrite-origin residual is documented in docs/security.md's full-trust
  cost list. Enforced mode keeps the broad deny unchanged.
- The acceptance command's argv loader is factored into
  `relay_exec_argv_json`, shared with the gate runner — one copy of the
  quoting-and-newline-safe code instead of two.
- `probe0-sandbox-off.sh` gains case 4 (the real 1.1.0 disabled payload);
  `probe0-permission-mode.sh` gains case E (the refusal shape under
  `dontAsk`). Both re-run against Claude Code 2.1.251, results recorded in
  docs/security.md.

## [1.0.2] - 2026-08-29

Documentation correctness, plus the four small code items deferred out of the
1.0.0 audit. No commitment is relaxed, and **the consent notice text is
unchanged**, so no project that has already consented under 1.0.x owes a new
acceptance.

### Added
- **`test/lint/citations.sh` — every `file:line` in every `.md` is now gated.**
  Relay's documentation cites its own source by line, and those coordinates rot
  on every edit that adds a line above them. The gate that existed covered
  `docs/exit-codes.md` alone, which is exactly why that was the only file in the
  tree without rot: a gate over one document licenses the other six. The new
  linter resolves each citation, checks the range is inside the file, and then
  checks the CLAIM — at least one code token from the phrase the citation is
  attached to has to appear inside the cited lines, so a correct line number on
  a sentence about different code fails too. It runs in CI as its own step and
  inside `publish-check.sh`. 522 citations are verified; **the stale ones it
  found on its first run are fixed in this release**, re-derived from the
  current sources rather than shifted by an offset table.
- A `<!-- citations-default: path -->` marker, so a document whose bare
  `**Line NNN**` references all belong to one file can say so once instead of
  the gate inferring it from whichever file was mentioned last.
- **RUN.md is now a preflight guard.** A run with no `$STATE/work/RUN.md` has no
  mission, no acceptance criteria and no guardrails, and every session is told
  to read it first — so its absence did not fail visibly, it produced a night of
  work against nothing. Symmetric with the existing `plan.md` guard and refused
  the same way (exit 78, `preflight.run-md-missing`). Most of the test suite had
  been seeding RUN.md one level up at `$STATE/RUN.md`, where nothing reads it,
  and passing; the fixture now writes the canonical path.

### Fixed
- **`stall_limit: 0` and `fastfail_limit: 0` bricked a run at session 1.** Both
  are numeric, so both passed validation. Both circuit breakers are tested
  unconditionally rather than only on the unproductive path, so `[ 0 -ge 0 ]`
  was true after the first session however productive it was: the run ended
  `EX_STALLED` with a journal reporting a stall that never happened. Values
  below 1 now refuse at preflight (`config.limit-below-one`). A limit of exactly
  1 is still allowed — it silently removes the escalation that fires one session
  before the breaker, so that is journaled rather than refused.
- **`/relay-status` could announce "FULL-TRUST MODE" for an enforced project
  that was not running.** `state_set` merges, and `sandbox_mode` was written
  only after every preflight exit — so a project that ran once in full trust,
  was set back to `enforced` and then failed preflight kept the old value.
  `sandbox_mode` and `reason` are now written at the top of the run, above every
  config guard, from that invocation's own config. Over-warning only; the
  dangerous direction was refuted.

### Changed — documentation
- **`docs/architecture.md` no longer contradicts `SKILL.md` and
  `docs/security.md` about the trust zones.** It stated as absolutes that a
  session "cannot forge a COMPLETE", "cannot truncate the audit journal",
  "cannot delete the run lock" and "cannot rewrite `exec.json`". All four are
  false under `sandbox_mode: "disabled"`: there is no `allowWrite` there, and the
  deny rules bind the Write/Edit tools while Bash ignores them. §4 now says which
  mode each claim belongs to and adds the four-for-four correction; the
  allowWrite paragraph and the context-guard section are qualified the same way.
- **`--hardened` mode does not exist.** `docs/security.md`'s standing rule 5 said
  `--bare` was used "only in `--hardened` mode" — a phantom, and one that now
  reads as a live exemption for full trust because `sandbox_mode` gives relay a
  real mode axis. Deleted, along with the matching comment in
  `relay-settings.sh`. `--bare` is refused unconditionally, in every mode.
- **The refusal-to-run guarantee is stated with its exceptions.**
  `RELAY_SKIP_PROBE=1` and `RELAY_SKIP_SELFTEST=1` defeat it, and the second was
  documented nowhere. Both are the test suite's, neither is readable from config
  or settable by a repository, and `SECURITY.md`, the README and
  `docs/troubleshooting.md` now say so.
- **Full trust's cost is itemised rather than implied.** `docs/security.md` gains
  a section on what the open deny list actually gives up: the macOS keychain via
  `security`, uncommitted work via git's own destructive commands, persistence
  via `crontab`/`launchctl`, and `~/.zshenv`, which the retained rc guards do not
  cover. These are accepted risks, recorded so the choice is informed.
- **Upgrading no longer costs you RUN.md.** `/relay-init` rewrote
  `$STATE/work/RUN.md` and `config.json`, discarding accumulated "Decisions
  already made (DO NOT RE-ASK)" and review-session "Course corrections" — and
  every existing project has to re-run it for the 1.0.0 consent notice. `init`
  now detects an already-initialised project and, when only the notice changed,
  takes the acceptance and stops.
- README and `SECURITY.md` disagreed about how `sandbox_mode` is selected: one
  said it is recorded at `/relay-init`, the other also documented editing
  `config.json` directly, which works and bypasses init. Both now say the same
  thing — it is a config key, and init is where you are asked and the only path
  that records consent.
- `allow_domains` is documented as inert under `disabled`: still validated, so a
  typo still refuses, and still journaled as `sandbox.extra-domains`, which reads
  as "configured", not "applied".
- The README's `jq` snippet wrote its temp file into the caller's working
  directory; `CONTRIBUTING.md` cited the wrong `ci.yml` lines for the bash-3.2
  rerun and described `probe0-sandbox-off.sh` as two invocations when it is
  three; `docs/architecture.md` claimed a supervisor line count that had been
  wrong for two releases.

## [1.0.1] - 2026-08-29

Findings from a three-reviewer audit of 1.0.0. No commitment is relaxed and no
consent is invalidated: the notice text is unchanged, so existing projects are
unaffected beyond the 1.0.0 re-consent they already owe.

### Fixed
- **The guardrail-drift filter halted healthy runs on the word "token".**
  `GUARDRAIL_PERM_RE` carried an unanchored `ok(ay)?`, which matches the
  substring in *token, hook, broken, looked, took, cookie* — and `token` is
  itself a danger word, so one ordinary word satisfied both AND-ed patterns. A
  handoff reading "reduced the token count" ended an unattended run at session 1
  with a BLOCKED.md accusing the model of prompt injection. Relay's own
  vocabulary made it the worst case; relay could not have built itself. `ok` is
  now word-anchored (POSIX-ERE, not `\b`, which BSD and GNU disagree about). The
  other stems stay unanchored so "allowed"/"enabling"/"approves" still match.
  Pre-existing since 0.1.0.
- **A stale hook marker could make the full-trust probe pass on a dropped
  payload.** `relay_settings_probe_disabled` cleared its scratch with an
  unchecked `rm -rf` — the one unchecked call in the function, guarding the one
  assertion the proof rests on. A session could plant `run/hook.alive` and chmod
  its parent 0555: the `rm` then fails while `mkdir -p` and `: >` still return 0,
  so setup looked clean and the next probe read a pre-planted "proof". The
  result was a cached `probe.ok` and an unattended full-trust run with no deny
  list and no context guard, journal reporting the payload proven accepted. The
  removal is now checked and the marker's absence asserted.
- **Five state-dir deny rules had a `Write` rule but no `Edit` twin**
  (`locks/**`, `priv/**`, `run/**`, `sessions/**`, `handoffs/**`), so relay's own
  state — including the probe cache — was reachable with the Edit tool alone in
  full-trust mode. Both halves are now emitted, matching the single-file rules.
- **The probe cache is no longer trusted or written in full-trust mode.**
  `$STATE/run/probe.ok` is session-writable once the sandbox is off, so it is
  dropped on entry and never refreshed; every full-trust start re-proves. See
  `docs/security.md` for the residual this does not close.
- A trailing slash on the work dir aimed the state-file deny rules at the work
  dir itself instead of the state root. Both that and the no-parent case are
  handled before the strip.

### Changed
- The mock CLI now enforces the same preconditions as the real hook before
  writing `hook.alive`, and exits loudly when they are missing. Four separate
  mutations of the full-trust probe previously left the whole suite green while
  making `sandbox_mode: disabled` refuse every run in production.
- `test/lint/probe0-sandbox-off.sh`: fresh session ids per run (hardcoded ones
  made every re-run fail as "already in use", with misleading guidance); a third
  case sending a genuinely invalid payload, which is the inference production
  actually relies on; and `timeout` used only when present, since CI asserts it
  is absent on macOS.

### Added
- `c151` — a benign-prose corpus through the drift filter, plus a real set of
  negative controls in the startup self-test. The previous single control passed
  only by accident of vocabulary.
- `c237` (stale marker refused), `c238` (probe session errored — assertion (a)
  had no coverage), `c239` (`allow_domains` inert but still validated in
  full-trust mode). New mock probe mode `errored`.

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
  write-persistence guards; operational commands and credential reads are
  permitted. `WebFetch`/`WebSearch` are NOT: dropping their deny entry permits
  nothing, because they were never in `permissions.allow` and `dontAsk` refuses
  anything unlisted. (Corrected in 1.0.1 — as written this overstated what the
  release loosened.)

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
