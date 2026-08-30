# Exit codes

`relay-supervisor.sh` is the process a user or `/relay-run` waits on, and its
exit code is the only thing an unattended overnight run leaves behind besides
the journal. The codes are declared as one block of constants, `EX_OK` through
`EX_PREFLIGHT`, at `plugins/relay/scripts/relay-supervisor.sh:82-84`:

```
EX_OK=0 EX_BLOCKED=20 EX_STALLED=21 EX_TIMEOUT=22 EX_CAPPED=23
EX_STOPPED=24 EX_LOCKED=25 EX_FASTFAIL=26 EX_REJECTED=27 EX_IO=28
EX_BUDGET=29 EX_PREFLIGHT=78
```

Everything below was read out of `exit "$EX_*"` call sites in that file, not
copied from `README.md`. Several codes exit from more than one place for
different reasons; each cause is listed separately with its own line number,
because collapsing them loses information a human needs at 3am. Two `exit 78`s
(lines 38 and 44) are literal rather than `$EX_PREFLIGHT` because they run
before the constants exist; they are listed under 78 all the same.

<!-- citations-default: plugins/relay/scripts/relay-supervisor.sh -->

Unqualified line references below — the **Line NNN** bullets, and prose of the
form (lines N-M) — are lines of
`plugins/relay/scripts/relay-supervisor.sh`. Anything in another file names it.
The machine-readable form of that sentence is the `citations-default` comment
above, which is what `test/lint/citations.sh` binds them to.

`state.json`'s `status` field is what a human actually reads (`/relay-status`
surfaces it); it is noted per cause where the code sets one. Not every exit
sets it — see EX_LOCKED and most EX_PREFLIGHT causes below.

## Quick reference

| Code | Constant       | One-line meaning                              | `/relay-resume`? |
|-----:|----------------|------------------------------------------------|------------------|
|    0 | `EX_OK`        | run complete and verified                       | no — nothing left to do |
| 20 | `EX_BLOCKED`   | a human decision or review is required          | conditionally — read the cause first |
| 21 | `EX_STALLED`   | several sessions in a row changed nothing       | conditionally — fix the blocker first |
| 22 | `EX_TIMEOUT`   | too many sessions hit the wall clock            | conditionally — raise the timeout first |
| 23 | `EX_CAPPED`    | hit `max_sessions` or `max_wall_secs`           | yes — that is the intended next step |
| 24 | `EX_STOPPED`   | `/relay-stop` was honored                       | yes — that is the intended next step |
| 25 | `EX_LOCKED`    | another supervisor already owns this project    | no — wait for it, don't race it |
| 26 | `EX_FASTFAIL`  | sessions exiting almost immediately, repeatedly | conditionally — diagnose the crash first |
| 27 | `EX_REJECTED`  | `COMPLETE.md` was claimed and rejected 3 times  | conditionally — verify_complete's reason first |
| 28 | `EX_IO`        | a low-level OS operation failed                 | conditionally — depends which one |
| 29 | `EX_BUDGET`    | total budget or provider usage limit exhausted  | conditionally — depends which one |
| 78 | `EX_PREFLIGHT` | refused to start; nothing ran                   | no, not blindly — fix the reported cause |

The supervisor can also die by signal — see "Signal exits: 129 / 130 / 143"
at the end, which the table above deliberately does not cover because those
numbers come from bash's 128+N convention, not from relay's constants.

## 0 — `EX_OK`

Two call sites, same meaning: the run is finished and `verify_complete()`
(lines 1241-1352) actually proved it — sealed `work/COMPLETE.md`,
clean tree, and either the approved acceptance command passed (its
`exec_hash` still matching) or, when no acceptance command is configured,
the commit count grew since `commits_at_start`. The commit count is a hard
veto *only* in that second case: a passing acceptance command is the run's
own definition of done, so a run that added no commits — a resume after the
work was already finished — is accepted with the fact journaled as
`complete.no-new-commits` (lines 1337-1350).

- **Line 1389** — pre-spawn gate: `COMPLETE.md` was already sealed and valid
  before this invocation even started a session (e.g. a previous run finished
  and someone re-ran the supervisor). `state_set status "complete"`.
- **Line 1650** — post-exit: the session just run sealed `COMPLETE.md`, it
  verified, and the supervisor exits `EX_OK`. `state_set status "complete"
  session_count "$N" cost_total "$COST_TOTAL"` records it first.

Look at `$STATE/work/COMPLETE.md` for the session's own proof (commit shas,
test output) and the journal's `complete.verified` line. Nothing to resume.

## 20 — `EX_BLOCKED`

Five distinct causes. All five leave a `$STATE/work/BLOCKED.md` behind: two
are sealed by the session itself, and three are written by relay.

- **Line 1394** — pre-spawn: `work/BLOCKED.md` was already sealed on entry.
  `state_set status "blocked"`. Read the file.
- **Line 1670** — post-exit: the session just run sealed `work/BLOCKED.md`.
  `state_set status "blocked" session_count "$N" cost_total "$COST_TOTAL"`.
  Read the file, written by the session itself.
- **Line 1744** — the supervisor's own guardrail-drift detector
  (`handoff_guardrail_drift`, two AND-ed patterns at lines 851-852: a
  permission word and a danger word on the same handoff line) found the
  handoff asserting a relaxed guardrail (e.g. "user approved the
  force-push"). The supervisor writes `work/BLOCKED.md` itself (lines
  1037-1044), then `state_set status "blocked" reason "guardrail-drift"`
  (line 1743). Look at the journal's `handoff.guardrail-drift` line and the session
  log named in the generated `BLOCKED.md` — this may be prompt injection.
- **Line 1853** — `relay_git_commit` returned 1: a probable credential was
  found in the staged content and nothing was committed.
  `state_set status "blocked" reason "secret-detected"` at line 1852.
  A `BLOCKED.md` **is** written for this cause, by `relay-git.sh` rather than
  by the supervisor: line 1847 passes `$WORK` as `relay_git_commit`'s third
  argument, and `relay-git.sh:315-330` writes a sealed `BLOCKED.md` there
  listing the matched locations with the values withheld. Also check the
  journal's `commit.secret-blocked` line and the supervisor's own
  stdout/stderr (not the session log; `relay_git_commit` prints the matched
  pattern and location, never the secret itself), then `git status`/`git diff`
  in the project. The staged changes were reset with `relay_git reset` (`relay-git.sh:311-312`) and
  nothing was committed; the working tree is untouched.
- **Line 1327** — the `EX_BLOCKED` exit inside `verify_complete()`: the acceptance command in
  `exec.json` no longer matches the `exec_hash` recorded when a human
  approved it, re-checked from the file as it exists immediately before the
  command would run (lines 1310-1314). Relay writes `work/BLOCKED.md` (lines
  728-736), journals `exec.hash-mismatch` (line 1315), and sets
  `state_set status "blocked" reason "exec-hash-mismatch"` (line 1326).
  Because `verify_complete()` runs both pre-spawn (line 1386) and post-exit
  (line 1646), this exit can fire in either position. Something edited a
  command relay was about to execute — treat it as tampering until shown
  otherwise, then re-approve with `/relay-approve`.

`/relay-resume` is conditional in every case: for the two session-sealed
causes, resuming without addressing what the file asks for reproduces the
same block next loop. For guardrail-drift, resume only after a human has
actually read the flagged handoff lines. For secret-detected, resume will
keep failing identically until the offending file is removed from the working
tree or the false positive is worked around. For exec-hash-mismatch, resume
only after inspecting `exec.json` and re-approving.

## 21 — `EX_STALLED`

- **Line 1937** — one cause: `STALL` (incremented at line 1918 whenever a
  session changes neither HEAD nor the handoff hash) reached `stall_limit`
  (default 3). `state_set status "stalled" session_count "$N"`.

Look at the journal's `stall.count` lines (one per increment) and the last
few session logs in `$STATE/sessions/` to see why nothing committed. Fable
escalation is attempted automatically before this trips (lines 1924-1931), so
by the time you see `EX_STALLED` the smarter tier already failed to help.
`/relay-resume` works mechanically but will likely stall again unless the
plan or a note (`/relay-note`) changes what the next session tries.

## 22 — `EX_TIMEOUT`

- **Line 1902** — one cause: `TIMEOUTS` (incremented at line 1895 whenever a
  session's `$RC` was 124 or 137 — killed by `relay_timeout`) reached
  `max_timeouts` (default 2). `state_set status "timeout" session_count "$N"`
  at line 1901, the line immediately above the exit.

Look at the journal's `session.timeout` and `timeout.tripped` lines, and the
`.err` file next to the killed session's log for what it was doing at the
deadline. `/relay-resume` is conditional: if `session_timeout_secs` is simply
too low for the workload, raise it first or the next session times out too.

## 23 — `EX_CAPPED`

Two causes since 1.1.0, both pre-spawn only, split by `state.json`'s `reason`
— the same one-code-two-remedies pattern as EX_BUDGET below.

- **Line 1403** — `session_count` (`$N`) reached `max_sessions` (default 12)
  before starting session `N+1`. `state_set status "capped"` with no reason.
- **Line 1413** — the wall clock: `max_wall_secs` (default 0 = off) elapsed
  since THIS supervisor launch. Journal `wallclock.reached`;
  `state_set status "capped" reason "wall-clock"`. The clock is per
  invocation and never persisted, and the gate runs before each spawn (plus
  inside the usage-limit backoff sleep, so a cap elapsing mid-backoff does
  not oversleep) — a session already in flight is never killed by it, so the
  run can overshoot the cap by up to about one `session_timeout_secs`.

This is an intentional circuit breaker, not a failure. For the session-count
cause: raise `max_sessions` above the recorded `session_count` before
resuming, or it exits 23 again immediately — that counter persists. For the
wall-clock cause: `/relay-resume` alone grants a fresh window; change
`max_wall_secs` only if the cap itself was wrong.

## 24 — `EX_STOPPED`

- **Line 1398** — pre-spawn: `$STATE/STOP` already existed on entry.
  `state_set status "stopped"`.
- **Line 1675** — post-exit: `$STATE/STOP` appeared while the just-finished
  session was running. `state_set status "stopped" session_count "$N"`.

Both causes are `/relay-stop` working as designed. `/relay-resume` is the
correct and intended next action (it clears `STOP` and continues).

## 25 — `EX_LOCKED`

- **Line 429** — one cause: `relay_lock "$STATE/locks/run.d" 0` failed
  (`plugins/relay/scripts/lib/relay-lib.sh:212-251`), meaning a live
  supervisor already holds this project's lock directory. **No `state_set`
  call happens here** — deliberately: this process never held the lock, so
  it must not touch `state.json`, which the actual owner may be writing
  concurrently. `status` therefore still reflects whatever the lock holder
  (or a previous run) last wrote.

Look at the printed message and the journal's `lock.contended` line, both of
which include the contents of `$STATE/locks/run.d/owner`
(`pid|epoch|host|run_id`). `/relay-resume` is the wrong instinct here: it
will hit the same lock again immediately. Either wait for the real owner to
finish, or confirm it is actually dead — `relay_lock` self-breaks a same-host
lock whose pid is verifiably not running, or a lock older than
`RELAY_LOCK_STALE_SECS * 4` (3600s by default) when liveness cannot be
established at all — another host, or a machine where `ps` does not work.
It never breaks a lock merely because `ps` failed.

## 26 — `EX_FASTFAIL`

- **Line 1942** — one cause: `FASTFAIL` reached `fastfail_limit` (default 3).
  It is incremented at line 1921 only for a session that was BOTH unproductive
  and shorter than `min_session_secs` (default 45); a session that committed
  or wrote a valid handoff clears the streak however brief it was
  (`:1915-1916`). `state_set status "blocked" reason "fastfail"` — **the
  status string says `"blocked"`, not `"fastfail"`**; only the `reason` field
  and the exit code itself distinguish it from an `EX_BLOCKED` exit.

Look at the journal's `fastfail.streak` / `fastfail.tripped` lines and the
most recent session logs' durations and `.err` files — a session dying in
under a minute usually means a broken start state (unreadable `RUN.md`, a
tool erroring immediately) rather than a real stall. `/relay-resume` is
conditional: read at least one of the short session logs first, or the next
session fails the same way in the same handful of seconds.

## 27 — `EX_REJECTED`

- **Line 1661** — one cause: `COMPLETE.md` was sealed and rejected by
  `verify_complete()` three times in a row (`complete_rejections >= 3`,
  tracked at lines 1655-1658). `state_set status "blocked" reason
  "repeated-false-complete"` at line 1660 — again, `status` says `"blocked"`,
  the exit code and `reason` are what say `REJECTED`.

Look at the journal for the three preceding `complete.rejected` lines —
`verify_complete()` (lines 1241-1352) journals *why* each time: `"working tree
not clean"`, `"acceptance command failed"` (with `$STATE/run/acceptance.log`
for that one), or — only when no acceptance command is configured — `"no
commits were made (start=… now=…)"`.
`/relay-resume` is conditional: each rejection already escalated the next
session to `fable` (line 1663), so a human should confirm the acceptance
criteria are actually satisfiable before resuming into a fourth attempt.

## 28 — `EX_IO`

Two call sites genuinely exit the supervisor process with this code; a third
`exit 28` in the file does **not** — that distinction matters here.

- **Line 70** — `mkdir -p` of `$STATE/run`, `sessions`, `handoffs`, `locks`,
  `priv`, `work/run`, `work/probe` failed (permissions, missing parent, full
  disk). This is before `RELAY_JOURNAL` is exported (line 77) and before
  `state.json` exists (line 107), so **nothing is journaled and no status is
  set** — the only evidence is whatever the shell printed to stderr. Check
  disk space and permissions on the state directory directly.
- **Line 1481** — `relay_uuid` (`lib/relay-lib.sh:374-426`) failed to produce
  a session id (no `uuidgen`, no `/proc/sys/kernel/random/uuid`, no readable
  `/dev/urandom` — effectively never on a supported OS).
  `relay_journal "uuid.failed" ""` runs, but **no `state_set` call** — status
  stays at the `"running"` set at line 649.
- **Line 1502** — `cd "$PROJECT" || exit 28` — this `exit` is inside the
  subshell that launches `claude` (lines 1501-1518), so it only sets that
  iteration's session `$RC` to 28; it does **not** end the supervisor
  process. A `$RC` of 28 here is not specially handled afterward (only 124
  and 137 are, at line 1891), so it is scored as an ordinary unproductive
  session and surfaces later as `EX_STALLED` or `EX_FASTFAIL`, never as a
  supervisor-level `EX_IO`. Grepping for `exit 28` and expecting an `EX_IO`
  exit here would be wrong — this is working as coded, just worth not
  confusing with the other two.

`/relay-resume` is conditional and cause-dependent: fix the state-dir
permissions/disk issue behind the `mkdir -p` at line 69-70, or the (very unlikely) missing entropy
source — `relay_uuid` — for line 1481, before resuming — otherwise the identical failure
repeats on the very next attempt.

## 29 — `EX_BUDGET`

Four causes across two `status` values, sharing one exit code — the `reason`
field separates the budget flavours.

- **Line 1418** — pre-spawn: `COST_TOTAL >= BUDGET_TOTAL` (default
  `$20.00` total, line 149). `state_set status "budget"`, empty reason. This
  is spend as the envelope reports it — real dollars under `billing: api`,
  NOTIONAL plan-covered API-equivalents under `billing: subscription` (the
  cap still works there; the units are the caveat).
- **Line 1426** — pre-spawn, the token twin exits `$EX_BUDGET`: `tokens_total` reached
  `budget_tokens_total` (default 0 = off). Journal `budget.tokens-exhausted`;
  `state_set status "budget" reason "tokens"`. Tokens are relay's own metric
  — input + cache_creation + cache_read + output, summed per session from the
  envelope (`session.tokens` journal lines) — the units a subscription
  operator actually allocates.
- **Line 1606** — post-exit, the per-session tripwire exits `$EX_BUDGET`: TWO consecutive
  sessions each exceeded `budget_tokens_per_session` (default 0 = off).
  Journal `session.tokens-over ... streak=2`;
  `state_set status "budget" reason "session-tokens"`. Post-hoc by necessity
  (the CLI's only mid-session stop is `--max-budget-usd`); the first breach
  forces a review session instead of halting.
- **Line 1685** — post-exit, inside `usage_limited()` handling
  (lines 1680-1721): the CLI's own transport envelope indicated a provider
  usage/rate limit (`api_error_status` 429, or an errored result whose
  fields match `LIMIT_RE` — `usage_limited()`, lines 937-957), and either
  `on_limit` is not `"wait"` or `LIMIT_RETRIES` exceeded `max_usage_retries`
  (default 20). `state_set status "usage-limit"`. The retry/backoff loop
  (lines 1681-1717) already absorbs ordinary rate limiting — and it preserves a
  queued operator note across the retry (`inbox.preserved-on-retry`, lines
  1004-1009) — so reaching this exit means the backoff itself gave up, not that
  the first limit was hit.

Look at `state.json`'s `cost_total` vs `budget_usd_total` (empty reason),
`tokens_total` vs `budget_tokens_total` (reason `tokens`), the
`session.tokens-over` journal lines (reason `session-tokens`), or the
journal's `usage_limit.halt` line and retry count (status `usage-limit`).
`/relay-resume` is conditional: raise the relevant budget above its recorded
counter for the budget flavours (the counters persist; the per-session
breach STREAK does not — it is per launch), or simply wait
out the provider's reset window for the usage-limit cause — the code's own comment calls
a usage limit "weather," not a failure.

## 78 — `EX_PREFLIGHT`

The busiest code: twenty-one distinct call sites (some causes owning several literal exits), all fail-closed, all before or
between sessions, never mid-session.

| Line | What failed | Journal event |
|-----:|-------------|----------------|
| 38 | `PROJECT` directory does not exist or is not `cd`-able | (none — see below) |
| 44 | `STATE` could not be created or canonicalised to a real path | (none — see below) |
| 190 | a numeric config value is not a number (`max_sessions: "twelve"` would otherwise silently disable the cap, or crash `$(( ))` mid-loop) | `config.non-numeric` |
| 219 | `stall_limit` or `fastfail_limit` is below 1 — at 0 the circuit breaker trips after the first session, productive or not | `config.limit-below-one` |
| 245 | `exec.json`'s `acceptance_cmd` is not a valid non-empty argv array | `exec.acceptance-cmd-invalid` |
| 259 | `acceptance_cmd` is present but carries no valid `exec_hash` — the command was never approved via `/relay-approve` | `exec.hash-missing` |
| 311 | the plan file named by `plan_path` does not exist | `preflight.plan-missing` |
| 327 | `$STATE/work/RUN.md` does not exist — no mission, no acceptance criteria, no guardrails for any session to read | `preflight.run-md-missing` |
| 381 | `model_tier` is not one of `opus`/`sonnet`/`fable` | `config.model-tier-invalid` |
| 412 | a configured `window_<tier>` is below the 100000-token floor (`RELAY_MIN_WINDOW`) | `config.window-too-small` |
| 439 | `relay-doctor.sh` (invoked as a `bash` subprocess, line 436) failed a hard check — including absent or stale consent (`consent.notice_hash`) | `preflight.failed` |
| 459 | window leaves too little room above the measured `ctx_baseline` | `config.window-too-small-for-baseline` |
| 485 | `allow_domains` is not a valid comma-separated hostname list | `config.allow-domains-invalid` |
| 504 | `sandbox_mode` is neither `enforced` nor `disabled` | `config.sandbox-mode-invalid` |
| 521 | `allow_tools_extra` is malformed (charset, a segment not starting with a letter, >16 entries, or an entry >64 chars — four exits, lines 521-546, one cause) | `config.allow-tools-extra-invalid` |
| 285 | `exec.json`'s `phase_gates` is not a usable gate list (shape, duplicate ids, or oversize) | `exec.gates-invalid` |
| 285 | `phase_gates` present but `gates_hash` missing or not matching — the gates were never approved via `/relay-approve` | `exec.gates-hash-missing` |
| 360 | the RUN.md integrity guard could not arm (protected region unhashable) — a guard that cannot arm is a preflight failure | `runmd.guard-unarmed` |
| 564 | `relay_settings_build` failed to construct the settings payload | `settings.build-failed` |
| 584 | the settings fingerprint could not be computed as a 40-hex blob id — an empty fingerprint would false-hit the probe cache and skip the sandbox proof | `probe.fingerprint-invalid` |
| 642 | the acceptance probe (`relay_settings_probe`) failed — in `enforced` mode the sandbox could not be proven to confine, in `disabled` mode the payload could not be proven accepted | `probe.failed` |
| 910 | the injection / guardrail-drift regex self-test failed under the live `grep` — a filter that cannot be shown to fire is treated as absent | `selftest.guards-failed` |
| 1492 | the per-session argv assertion (`relay_settings_assert_argv`) failed before spawning | `argv.assert-failed` |

Most of these call `state_set status` not at all, so for those there
is no status to read. Lines 38 and 44 run before `RELAY_JOURNAL` is exported
(line 77) *and* before `state.json` is created (line 107) — no journal line, no
status; stderr is the sole evidence. Lines 183 through 327 do journal their
event, and since 1.0.2 they also run after `state.json` exists, so `status` is
whatever the previous run left — `sandbox_mode` and `reason` are cleared for the
new invocation (line 131) but `status` is not. Lines 374, 400, 419, 438 and 1025
run after state is initialized and simply do not set one either. Do not read
"no status" as "never got that far", and treat a leftover `"running"` after one
of these exits as stale, not live.

The four that *do* record a status: line 439 sets `status "preflight-failed"`
(line 438); line 603 sets `status "preflight-failed" reason
"fingerprint-uncomputable"` (line 602); line 642 sets `status
"preflight-failed" reason "sandbox-not-enforced"` (enforced mode) or
`"settings-not-accepted"` (disabled mode) at line 641; line 910 sets
`status "preflight-failed" reason "regex-selftest-failed"` (line 908).

`/relay-resume` is never the right first move for any of these: nothing ran,
so resuming without changing the reported cause reproduces the exact same
exit immediately. Fix the specific thing named in the stderr message first.

### Two more 78s that are not the supervisor's

- **`lib/relay-lib.sh:22-25`** — the library's own bash version gate exits 78
  if bash is older than 3. Every relay script sources the library first, so
  on a hopeless shell this fires before any of the causes above. No journal,
  no status; the message names the bash version it saw.
- **`relay-doctor.sh:450-452`** — doctor's `HARD_FAIL` branch exits a literal
  78 when a hard check failed, and a literal 0 when `HARD_FAIL` is zero
  (`relay-doctor.sh:450-459`); it defines no `EX_*` constants of its own. The supervisor does not propagate doctor's code —
  it treats *any* nonzero from doctor as its own `EX_PREFLIGHT` (lines
  280-284) — but since doctor only ever produces 0 or 78, the numbers agree
  in practice. Run doctor directly for the full FAIL/fix report.

## Signal exits: 129 / 130 / 143

The supervisor installs INT/TERM/HUP traps (`relay_install_traps`, installed
at `relay-supervisor.sh:431`, defined `lib/relay-lib.sh:708-714`, handlers
`lib/relay-lib.sh:678-694`, cleanup `lib/relay-lib.sh:641-676`). On a signal
the handler tears down the running session's process group (TERM, then a
grace period, then KILL), reaps it, releases the lock, journals
`signal_cleanup code=<n>` — and then **re-raises the signal** so the shell
dies by it. What a waiting parent observes is therefore bash's 128+N
convention:

| Observed | Signal | Typical source |
|-----:|--------|----------------|
| 129 | HUP  | the terminal or session that launched the supervisor went away |
| 130 | INT  | Ctrl-C |
| 143 | TERM | `kill <pid>`, service managers, `/relay-stop` is *not* this — STOP exits 24 |

The literal `exit 129/130/143` in the handlers is only the fallback for the
degenerate case where the re-raise `kill` itself fails. No `status` is set on
a signal exit beyond what the run had already written; the journal's
`signal_cleanup` line is the marker. Note the traps are deferred while a
session is in flight — bash runs a trap only after the current foreground
command returns — so a TERM during a session takes effect when that session
ends; `docs/troubleshooting.md`'s "How do I stop a run right now?" covers
the fast path.

Session-level `$RC` values 124 and 137 (deadline TERM / escalated KILL from
`relay_timeout`, `lib/relay-lib.sh:108-109`) are **not** supervisor exit
codes: they are per-session results that feed the timeout counter and surface
as `EX_TIMEOUT` (22) at `max_timeouts`.
