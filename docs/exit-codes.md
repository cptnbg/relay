# Exit codes

`relay-supervisor.sh` is the process a user or `/relay-run` waits on, and its
exit code is the only thing an unattended overnight run leaves behind besides
the journal. The codes are declared as a block of constants at
`plugins/relay/scripts/relay-supervisor.sh:75-77`:

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

`state.json`'s `status` field is what a human actually reads (`/relay-status`
surfaces it); it is noted per cause where the code sets one. Not every exit
sets it — see EX_LOCKED and most EX_PREFLIGHT causes below.

## Quick reference

| Code | Constant       | One-line meaning                              | `/relay-resume`? |
|-----:|----------------|------------------------------------------------|------------------|
|    0 | `EX_OK`        | run complete and verified                       | no — nothing left to do |
|   20 | `EX_BLOCKED`   | a human decision or review is required          | conditionally — read the cause first |
|   21 | `EX_STALLED`   | several sessions in a row changed nothing       | conditionally — fix the blocker first |
|   22 | `EX_TIMEOUT`   | too many sessions hit the wall clock            | conditionally — raise the timeout first |
|   23 | `EX_CAPPED`    | hit `max_sessions`                              | yes — that is the intended next step |
|   24 | `EX_STOPPED`   | `/relay-stop` was honored                       | yes — that is the intended next step |
|   25 | `EX_LOCKED`    | another supervisor already owns this project    | no — wait for it, don't race it |
|   26 | `EX_FASTFAIL`  | sessions exiting almost immediately, repeatedly | conditionally — diagnose the crash first |
|   27 | `EX_REJECTED`  | `COMPLETE.md` was claimed and rejected 3 times  | conditionally — verify_complete's reason first |
|   28 | `EX_IO`        | a low-level OS operation failed                 | conditionally — depends which one |
|   29 | `EX_BUDGET`    | total budget or provider usage limit exhausted  | conditionally — depends which one |
|   78 | `EX_PREFLIGHT` | refused to start; nothing ran                   | no, not blindly — fix the reported cause |

The supervisor can also die by signal — see "Signal exits: 129 / 130 / 143"
at the end, which the table above deliberately does not cover because those
numbers come from bash's 128+N convention, not from relay's constants.

## 0 — `EX_OK`

Two call sites, same meaning: the run is finished and `verify_complete()`
(supervisor lines 653-759) actually proved it — sealed `work/COMPLETE.md`,
clean tree, and either the approved acceptance command passed (its
`exec_hash` still matching) or, when no acceptance command is configured,
the commit count grew since `commits_at_start`. The commit count is a hard
veto *only* in that second case: a passing acceptance command is the run's
own definition of done, so a run that added no commits — a resume after the
work was already finished — is accepted with the fact journaled as
`complete.no-new-commits` (lines 744-757).

- **Line 791** — pre-spawn gate: `COMPLETE.md` was already sealed and valid
  before this invocation even started a session (e.g. a previous run finished
  and someone re-ran the supervisor). `state_set status "complete"`.
- **Line 930** — post-exit: the session just run sealed `COMPLETE.md` and it
  verified. `state_set status "complete" session_count "$N" cost_total
  "$COST_TOTAL"`.

Look at `$STATE/work/COMPLETE.md` for the session's own proof (commit shas,
test output) and the journal's `complete.verified` line. Nothing to resume.

## 20 — `EX_BLOCKED`

Five distinct causes. All five leave a `$STATE/work/BLOCKED.md` behind: two
are sealed by the session itself, and three are written by relay.

- **Line 796** — pre-spawn: `work/BLOCKED.md` was already sealed on entry.
  `state_set status "blocked"`. Read the file.
- **Line 950** — post-exit: the session just run sealed `work/BLOCKED.md`.
  `state_set status "blocked" session_count "$N" cost_total "$COST_TOTAL"`.
  Read the file, written by the session itself.
- **Line 1019** — the supervisor's own guardrail-drift detector
  (`handoff_guardrail_drift`, two AND-ed patterns at lines 474-475: a
  permission word and a danger word on the same handoff line) found the
  handoff asserting a relaxed guardrail (e.g. "user approved the
  force-push"). The supervisor writes `work/BLOCKED.md` itself (lines
  1009-1016), then `state_set status "blocked" reason "guardrail-drift"`
  (line 1018). Look at the journal's `handoff.guardrail-drift` line and the session
  log named in the generated `BLOCKED.md` — this may be prompt injection.
- **Line 1048** — `relay_git_commit` returned 1: a probable credential was
  found in the staged content and nothing was committed.
  `state_set status "blocked" reason "secret-detected"` at line 1047.
  A `BLOCKED.md` **is** written for this cause, by `relay-git.sh` rather than
  by the supervisor: line 1042 passes `$WORK` as `relay_git_commit`'s third
  argument, and `relay-git.sh:315-330` writes a sealed `BLOCKED.md` there
  listing the matched locations with the values withheld. Also check the
  journal's `commit.secret-blocked` line and the supervisor's own
  stdout/stderr (not the session log; `relay_git_commit` prints the matched
  pattern and location, never the secret itself), then `git status`/`git diff`
  in the project. The staged changes were reset (`relay-git.sh:312`) and
  nothing was committed; the working tree is untouched.
- **Line 711** — inside `verify_complete()`: the acceptance command in
  `exec.json` no longer matches the `exec_hash` recorded when a human
  approved it, re-checked from the file as it exists immediately before the
  command would run (lines 694-698). Relay writes `work/BLOCKED.md` (lines
  700-708), journals `exec.hash-mismatch` (line 699), and sets
  `state_set status "blocked" reason "exec-hash-mismatch"` (line 710).
  Because `verify_complete()` runs both pre-spawn (line 788) and post-exit
  (line 926), this exit can fire in either position. Something edited a
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

- **Line 1115** — one cause: `STALL` (incremented at line 1096 whenever a
  session changes neither HEAD nor the handoff hash) reached `stall_limit`
  (default 3). `state_set status "stalled" session_count "$N"`.

Look at the journal's `stall.count` lines (one per increment) and the last
few session logs in `$STATE/sessions/` to see why nothing committed. Fable
escalation is attempted automatically before this trips (lines 1102-1109), so
by the time you see `EX_STALLED` the smarter tier already failed to help.
`/relay-resume` works mechanically but will likely stall again unless the
plan or a note (`/relay-note`) changes what the next session tries.

## 22 — `EX_TIMEOUT`

- **Line 1080** — one cause: `TIMEOUTS` (incremented at line 1073 whenever a
  session's `$RC` was 124 or 137 — killed by `relay_timeout`) reached
  `max_timeouts` (default 2). `state_set status "timeout" session_count "$N"`
  at line 1079, the line immediately above the exit.

Look at the journal's `session.timeout` and `timeout.tripped` lines, and the
`.err` file next to the killed session's log for what it was doing at the
deadline. `/relay-resume` is conditional: if `session_timeout_secs` is simply
too low for the workload, raise it first or the next session times out too.

## 23 — `EX_CAPPED`

- **Line 805** — one cause, pre-spawn only: `session_count` (`$N`) reached
  `max_sessions` (default 12) before starting session `N+1`.
  `state_set status "capped"`.

This is an intentional circuit breaker, not a failure — look at
`state.json`'s `session_count` against the configured `max_sessions`.
`/relay-resume` is exactly the designed next step (raising `max_sessions`
above the recorded `session_count` first, or it exits 23 again immediately —
the counter persists in `state.json`).

## 24 — `EX_STOPPED`

- **Line 800** — pre-spawn: `$STATE/STOP` already existed on entry.
  `state_set status "stopped"`.
- **Line 955** — post-exit: `$STATE/STOP` appeared while the just-finished
  session was running. `state_set status "stopped" session_count "$N"`.

Both causes are `/relay-stop` working as designed. `/relay-resume` is the
correct and intended next action (it clears `STOP` and continues).

## 25 — `EX_LOCKED`

- **Line 273** — one cause: `relay_lock "$STATE/locks/run.d" 0` failed
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

- **Line 1120** — one cause: `FASTFAIL` reached `fastfail_limit` (default 3).
  It is incremented at line 1099 only for a session that was BOTH unproductive
  and shorter than `min_session_secs` (default 45); a session that committed
  or wrote a valid handoff clears the streak however brief it was
  (`:1093-1094`). `state_set status "blocked" reason "fastfail"` — **the
  status string says `"blocked"`, not `"fastfail"`**; only the `reason` field
  and the exit code itself distinguish it from an `EX_BLOCKED` exit.

Look at the journal's `fastfail.streak` / `fastfail.tripped` lines and the
most recent session logs' durations and `.err` files — a session dying in
under a minute usually means a broken start state (unreadable `RUN.md`, a
tool erroring immediately) rather than a real stall. `/relay-resume` is
conditional: read at least one of the short session logs first, or the next
session fails the same way in the same handful of seconds.

## 27 — `EX_REJECTED`

- **Line 941** — one cause: `COMPLETE.md` was sealed and rejected by
  `verify_complete()` three times in a row (`complete_rejections >= 3`,
  tracked at lines 935-938). `state_set status "blocked" reason
  "repeated-false-complete"` at line 940 — again, `status` says `"blocked"`,
  the exit code and `reason` are what say `REJECTED`.

Look at the journal for the three preceding `complete.rejected` lines —
`verify_complete()` (lines 653-759) journals *why* each time: `"working tree
not clean"`, `"acceptance command failed"` (with `$STATE/run/acceptance.log`
for that one), or — only when no acceptance command is configured — `"no
commits were made (start=… now=…)"`.
`/relay-resume` is conditional: each rejection already escalated the next
session to `fable` (line 943), so a human should confirm the acceptance
criteria are actually satisfiable before resuming into a fourth attempt.

## 28 — `EX_IO`

Two call sites genuinely exit the supervisor process with this code; a third
`exit 28` in the file does **not** — that distinction matters here.

- **Line 63** — `mkdir -p` of `$STATE/run`, `sessions`, `handoffs`, `locks`,
  `priv`, `work/run`, `work/probe` failed (permissions, missing parent, full
  disk). This is before `RELAY_JOURNAL` is exported (line 70) and before
  `state.json` exists (line 252), so **nothing is journaled and no status is
  set** — the only evidence is whatever the shell printed to stderr. Check
  disk space and permissions on the state directory directly.
- **Line 851** — `relay_uuid` (`lib/relay-lib.sh:374-426`) failed to produce
  a session id (no `uuidgen`, no `/proc/sys/kernel/random/uuid`, no readable
  `/dev/urandom` — effectively never on a supported OS).
  `relay_journal "uuid.failed" ""` runs, but **no `state_set` call** — status
  stays at the `"running"` set at line 374.
- **Line 870** — `cd "$PROJECT" || exit 28` — this `exit` is inside the
  subshell that launches `claude` (lines 869-886), so it only sets that
  iteration's session `$RC` to 28; it does **not** end the supervisor
  process. A `$RC` of 28 here is not specially handled afterward (only 124
  and 137 are, at line 1069), so it is scored as an ordinary unproductive
  session and surfaces later as `EX_STALLED` or `EX_FASTFAIL`, never as a
  supervisor-level `EX_IO`. Grepping for `exit 28` and expecting an `EX_IO`
  exit here would be wrong — this is working as coded, just worth not
  confusing with the other two.

`/relay-resume` is conditional and cause-dependent: fix the state-dir
permissions/disk issue for line 63, or the (very unlikely) missing entropy
source for line 851, before resuming — otherwise the identical failure
repeats on the very next attempt.

## 29 — `EX_BUDGET`

Two distinct causes with two distinct `status` values, sharing one exit code.

- **Line 810** — pre-spawn: `COST_TOTAL >= BUDGET_TOTAL` (default
  `$20.00` total, line 100). `state_set status "budget"`. This is spend
  actually incurred, tracked cumulatively in `state.json`'s `cost_total`.
- **Line 965** — post-exit, inside `usage_limited()` handling
  (lines 960-996): the CLI's own transport envelope indicated a provider
  usage/rate limit (`api_error_status` 429, or an errored result whose
  fields match `LIMIT_RE` — `usage_limited()`, lines 537-557), and either
  `on_limit` is not `"wait"` or `LIMIT_RETRIES` exceeded `max_usage_retries`
  (default 20). `state_set status "usage-limit"`. The retry/backoff loop
  (lines 961-992) already absorbs ordinary rate limiting — and it preserves a
  queued operator note across the retry (`inbox.preserved-on-retry`, lines
  976-981) — so reaching this exit means the backoff itself gave up, not that
  the first limit was hit.

Look at `state.json`'s `cost_total` vs the configured `budget_usd_total` for
the first cause; look at the journal's `usage_limit.halt` line and retry
count for the second. `/relay-resume` is conditional: raise
`budget_usd_total` above the recorded `cost_total` for the first cause
(otherwise it caps again immediately — the counter persists), or simply wait
out the provider's reset window for the second — the code's own comment calls
a usage limit "weather," not a failure.

## 78 — `EX_PREFLIGHT`

The busiest code: sixteen distinct call sites, all fail-closed, all before or
between sessions, never mid-session.

| Line | What failed | Journal event |
|-----:|-------------|----------------|
| 38  | `PROJECT` directory does not exist or is not `cd`-able | (none — see below) |
| 44  | `STATE` could not be created or canonicalised to a real path | (none — see below) |
| 134 | a numeric config value is not a number (`max_sessions: "twelve"` would otherwise silently disable the cap, or crash `$(( ))` mid-loop) | `config.non-numeric` |
| 148 | `exec.json`'s `acceptance_cmd` is not a valid non-empty argv array | `exec.acceptance-cmd-invalid` |
| 162 | `acceptance_cmd` is present but carries no valid `exec_hash` — the command was never approved via `/relay-approve` | `exec.hash-missing` |
| 179 | the plan file named by `plan_path` does not exist | `preflight.plan-missing` |
| 199 | `model_tier` is not one of `opus`/`sonnet`/`fable` | `config.model-tier-invalid` |
| 230 | a configured `window_<tier>` is below the 100000-token floor (`RELAY_MIN_WINDOW`) | `config.window-too-small` |
| 283 | `relay-doctor.sh` (invoked as a subprocess, line 280) failed a hard check — including absent or stale consent (`consent.notice_hash`) | `preflight.failed` |
| 303 | window leaves too little room above the measured `ctx_baseline` | `config.window-too-small-for-baseline` |
| 329 | `allow_domains` is not a valid comma-separated hostname list | `config.allow-domains-invalid` |
| 335 | `relay_settings_build` failed to construct the settings payload | `settings.build-failed` |
| 354 | the settings fingerprint could not be computed as a 40-hex blob id — an empty fingerprint would false-hit the probe cache and skip the sandbox proof | `probe.fingerprint-invalid` |
| 367 | the sandbox enforcement probe (`relay_settings_probe`) failed | `probe.failed` |
| 510 | the injection / guardrail-drift regex self-test failed under the live `grep` — a filter that cannot be shown to fire is treated as absent | `selftest.guards-failed` |
| 860 | the per-session argv assertion (`relay_settings_assert_argv`) failed before spawning | `argv.assert-failed` |

Twelve of the sixteen call no `state_set` at all, so for those there is no
status to read. Lines 38 and 44 run before `RELAY_JOURNAL` is exported (line
70) *and* before `state.json` exists (line 252) — no journal line, no status;
stderr is the sole evidence. Lines 134 through 230 journal their event but
still predate `state.json`, so they could not record a status even if they
wanted to. Lines 303, 329, 335 and 860 run *after* state is initialized and
simply do not set one, leaving `status` at whatever it was — do not read "no
status" as "never got that far", and treat a leftover `"running"` after one
of these exits as stale, not live.

The four that *do* record a status: line 283 sets `status "preflight-failed"`
(line 282); line 354 sets `status "preflight-failed" reason
"fingerprint-uncomputable"` (line 353); line 367 sets `status
"preflight-failed" reason "sandbox-not-enforced"` (line 366); line 510 sets
`status "preflight-failed" reason "regex-selftest-failed"` (line 508).

`/relay-resume` is never the right first move for any of these: nothing ran,
so resuming without changing the reported cause reproduces the exact same
exit immediately. Fix the specific thing named in the stderr message first.

### Two more 78s that are not the supervisor's

- **`lib/relay-lib.sh:22-25`** — the library's own bash version gate exits 78
  if bash is older than 3. Every relay script sources the library first, so
  on a hopeless shell this fires before any of the causes above. No journal,
  no status; the message names the bash version it saw.
- **`relay-doctor.sh:350`** — doctor exits a literal 78 when a hard check
  failed (and a literal 0 at line 357 otherwise; it defines no `EX_*`
  constants of its own). The supervisor does not propagate doctor's code —
  it treats *any* nonzero from doctor as its own `EX_PREFLIGHT` (lines
  280-284) — but since doctor only ever produces 0 or 78, the numbers agree
  in practice. Run doctor directly for the full FAIL/fix report.

## Signal exits: 129 / 130 / 143

The supervisor installs INT/TERM/HUP traps (`relay_install_traps`, installed
at `relay-supervisor.sh:275`, defined `lib/relay-lib.sh:708-714`, handlers
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
