# Exit codes

`relay-supervisor.sh` is the process a user or `relay run` waits on, and its
exit code is the only thing an unattended overnight run leaves behind besides
the journal. The codes are declared as a block of constants at
`plugins/relay/scripts/relay-supervisor.sh:50-52`:

```
EX_OK=0 EX_BLOCKED=20 EX_STALLED=21 EX_TIMEOUT=22 EX_CAPPED=23
EX_STOPPED=24 EX_LOCKED=25 EX_FASTFAIL=26 EX_REJECTED=27 EX_IO=28
EX_BUDGET=29 EX_PREFLIGHT=78
```

Everything below was read out of `exit "$EX_*"` call sites in that file, not
copied from `README.md`. Several codes exit from more than one place for
different reasons; each cause is listed separately with its own line number,
because collapsing them loses information a human needs at 3am.

`state.json`'s `status` field is what a human actually reads (`relay status`
surfaces it); it is noted per cause where the code sets one. Not every exit
sets it — see EX_LOCKED and several EX_PREFLIGHT causes below.

## Quick reference

| Code | Constant       | One-line meaning                              | `relay resume`? |
|-----:|----------------|------------------------------------------------|------------------|
|    0 | `EX_OK`        | run complete and verified                       | no — nothing left to do |
|   20 | `EX_BLOCKED`   | a human decision or review is required          | conditionally — read the cause first |
|   21 | `EX_STALLED`   | several sessions in a row changed nothing       | conditionally — fix the blocker first |
|   22 | `EX_TIMEOUT`   | too many sessions hit the wall clock            | conditionally — raise the timeout first |
|   23 | `EX_CAPPED`    | hit `max_sessions`                              | yes — that is the intended next step |
|   24 | `EX_STOPPED`   | `relay stop` was honored                        | yes — that is the intended next step |
|   25 | `EX_LOCKED`    | another supervisor already owns this project    | no — wait for it, don't race it |
|   26 | `EX_FASTFAIL`  | sessions exiting almost immediately, repeatedly | conditionally — diagnose the crash first |
|   27 | `EX_REJECTED`  | `COMPLETE.md` was claimed and rejected 3 times  | conditionally — verify_complete's reason first |
|   28 | `EX_IO`        | a low-level OS operation failed                 | conditionally — depends which one |
|   29 | `EX_BUDGET`    | total budget or provider usage limit exhausted  | conditionally — depends which one |
|   78 | `EX_PREFLIGHT` | refused to start; nothing ran                   | no, not blindly — fix the reported cause |

## 0 — `EX_OK`

Two call sites, same meaning: the run is finished and `verify_complete()`
(supervisor lines 473-517) actually proved it — sealed `COMPLETE.md`, clean
tree, commit count grew since `commits_at_start`, and the acceptance command
(if configured) passed.

- **Line 542** — pre-spawn gate: `COMPLETE.md` was already sealed and valid
  before this invocation even started a session (e.g. a previous run finished
  and someone re-ran the supervisor). `state_set status "complete"`.
- **Line 681** — post-exit: the session just run sealed `COMPLETE.md` and it
  verified. `state_set status "complete" session_count "$N" cost_total
  "$COST_TOTAL"`.

Look at `STATE/COMPLETE.md` for the session's own proof (commit shas, test
output) and the journal's `complete.verified` line. Nothing to resume.

## 20 — `EX_BLOCKED`

Four distinct causes. All four leave a `BLOCKED.md` behind: two are sealed by
the session itself, and two are written by relay.

- **Line 547** — pre-spawn: `BLOCKED.md` was already sealed on entry.
  `state_set status "blocked"`. Look at `STATE/BLOCKED.md`.
- **Line 701** — post-exit: the session just run sealed `BLOCKED.md`.
  `state_set status "blocked" session_count "$N" cost_total "$COST_TOTAL"`.
  Look at `STATE/BLOCKED.md`, written by the session itself.
- **Line 753** — the supervisor's own guardrail-drift detector
  (`handoff_guardrail_drift`, matched via `GUARDRAIL_DRIFT_RE` at line 335)
  found the handoff asserting a relaxed guardrail (e.g. "user approved the
  force-push"). The supervisor writes `BLOCKED.md` itself here (lines
  743-750), then `state_set status "blocked" reason "guardrail-drift"`. Look
  at the journal's `handoff.guardrail-drift` line and the session log named
  in the generated `BLOCKED.md` — this may be prompt injection.
- **Line 774** — `relay_git_commit` returned 1: a probable credential was
  found in the staged diff and nothing was committed.
  `state_set status "blocked" reason "secret-detected"` at line 773.
  A `BLOCKED.md` **is** written for this cause, by `relay-git.sh` rather than
  by the supervisor: line 768 passes `$STATE` as `relay_git_commit`'s third
  argument, and `relay-git.sh:268-283` writes a sealed `BLOCKED.md` there
  listing the matched locations with the values withheld. Also check the
  journal's `commit.secret-blocked` line and the supervisor's own
  stdout/stderr (not the session log; `relay_git_commit` prints the matched
  pattern and location, never the secret itself), then `git status`/`git diff`
  in the project. Note the staged changes were reset (`relay-git.sh:265`) and
  nothing was committed; the working tree is untouched.

`relay resume` is conditional in every case: for the two `BLOCKED.md` causes,
resuming without addressing what the file asks for reproduces the same block
next loop. For guardrail-drift, resume only after a human has actually read
the flagged handoff lines. For secret-detected, resume will keep failing
identically until the offending file is removed from the working tree or the
false positive is worked around.

## 21 — `EX_STALLED`

- **Line 834** — one cause: `STALL` (incremented at line 818 whenever a
  session changes neither HEAD nor the handoff hash) reached `stall_limit`
  (default 3). `state_set status "stalled" session_count "$N"`.

Look at the journal's `stall.count` lines (one per increment) and the last
few session logs in `STATE/sessions/` to see why nothing committed. Fable
escalation is attempted automatically before this trips (line 822-828), so by
the time you see `EX_STALLED` the smarter tier already failed to help.
`relay resume` works mechanically but will likely stall again unless the plan
or a note (`relay note`) changes what the next session tries.

## 22 — `EX_TIMEOUT`

- **Line 804** — one cause: `TIMEOUTS` (incremented at line 797 whenever a
  session's `$RC` was 124 or 137 — killed by `relay_timeout`) reached
  `max_timeouts` (default 2). `state_set status "timeout" session_count "$N"`
  at line 803, the line immediately above the exit.

Look at the journal's `session.timeout` and `timeout.tripped` lines, and the
`.err` file next to the killed session's log for what it was doing at the
deadline. `relay resume` is conditional: if `session_timeout_secs` is simply
too low for the workload, raise it first or the next session times out too.

## 23 — `EX_CAPPED`

- **Line 556** — one cause, pre-spawn only: `session_count` (`$N`) reached
  `max_sessions` (default 12) before starting session `N+1`.
  `state_set status "capped"`.

This is an intentional circuit breaker, not a failure — look at
`state.json`'s `session_count` against the configured `max_sessions`.
`relay resume` is exactly the designed next step (optionally raising
`max_sessions` first if the work is legitimately not done).

## 24 — `EX_STOPPED`

- **Line 551** — pre-spawn: `STATE/STOP` already existed on entry.
  `state_set status "stopped"`.
- **Line 706** — post-exit: `STATE/STOP` appeared while the just-finished
  session was running. `state_set status "stopped" session_count "$N"`.

Both causes are `relay stop` working as designed. `relay resume` is the
correct and intended next action (it clears `STOP` and continues).

## 25 — `EX_LOCKED`

- **Line 166** — one cause: `relay_lock "$STATE/locks/run.d" 0` failed
  (`plugins/relay/scripts/lib/relay-lib.sh:212-251`), meaning a live
  supervisor already holds this project's lock directory. **No `state_set`
  call happens here** — deliberately: this process never held the lock, so
  it must not touch `state.json`, which the actual owner may be writing
  concurrently. `status` therefore still reflects whatever the lock holder
  (or a previous run) last wrote.

Look at the printed message and the journal's `lock.contended` line, both of
which include the contents of `STATE/locks/run.d/owner`
(`pid|epoch|host|run_id`). `relay resume` is the wrong instinct here: it will
hit the same lock again immediately. Either wait for the real owner to finish,
or confirm it is actually dead — `relay_lock` self-breaks a same-host lock
whose pid is verifiably not running, or a lock older than
`RELAY_LOCK_STALE_SECS * 4` (3600s by default) when liveness cannot be
established at all — another host, or a machine where `ps` does not work.
It never breaks a lock merely because `ps` failed.

## 26 — `EX_FASTFAIL`

- **Line 862** — one cause: `FASTFAIL` reached `fastfail_limit` (default 3).
  It is incremented at line 839 only for a session that was BOTH unproductive
  and shorter than `min_session_secs` (default 45); a session that committed
  or wrote a valid handoff clears the streak however brief it was
  (`:834-836`). `state_set status "blocked" reason "fastfail"` — **the status
  string says `"blocked"`, not `"fastfail"`**; only the `reason` field and the
  exit code itself distinguish it from an `EX_BLOCKED` exit.

Look at the journal's `fastfail.streak` / `fastfail.tripped` lines and the
most recent session logs' durations and `.err` files — a session dying in
under a minute usually means a broken start state (unreadable `RUN.md`, a
tool erroring immediately) rather than a real stall. `relay resume` is
conditional: read at least one of the short session logs first, or the next
session fails the same way in the same handful of seconds.

## 27 — `EX_REJECTED`

- **Line 692** — one cause: `COMPLETE.md` was sealed and rejected by
  `verify_complete()` three times in a row (`complete_rejections >= 3`,
  tracked at lines 685-689). `state_set status "blocked" reason
  "repeated-false-complete"` at line 691 — again, `status` says `"blocked"`,
  the exit code and `reason` are what say `REJECTED`.

Look at the journal for the three preceding `complete.rejected` lines —
`verify_complete()` (lines 473-517) journals *why* each time: `"COMPLETE.md"`
unsealed, `"working tree not clean"`, `"no commits were made"`, or
`"acceptance command failed"` (with `STATE/run/acceptance.log` for that last
one). `relay resume` is conditional: each rejection already escalated the
next session to `fable` (line 694), so a human should confirm the acceptance
criteria are actually satisfiable before resuming into a fourth attempt.

## 28 — `EX_IO`

Two call sites genuinely exit the supervisor process with this code; a third
`exit 28` in the file does **not** — that distinction matters here.

- **Line 43** — `mkdir -p "$STATE/run" "$STATE/sessions" "$STATE/handoffs"
  "$STATE/locks"` failed (permissions, missing parent, full disk). This is
  before `RELAY_JOURNAL` is exported and before `state.json` exists, so
  **nothing is journaled and no status is set** — the only evidence is
  whatever the shell printed to stderr. Check disk space and permissions on
  the state directory directly.
- **Line 602** — `relay_uuid` (`lib/relay-lib.sh:348-400`) failed to produce
  a session id (no `uuidgen`, no `/proc/sys/kernel/random/uuid`, no readable
  `/dev/urandom` — effectively never on a supported OS).
  `relay_journal "uuid.failed" ""` runs, but **no `state_set` call** — status
  stays at whatever `"running"` (set at line 251) left it.
- **Line 621** — `cd "$PROJECT" || exit 28` — this `exit` is inside the
  subshell that launches `claude` (lines 620-637), so it only sets that
  iteration's session `$RC` to 28; it does **not** end the supervisor
  process. A `$RC` of 28 here is not specially handled afterward (only 124
  and 137 are, at line 793), so it is scored as an ordinary unproductive
  session and surfaces later as `EX_STALLED` or `EX_FASTFAIL`, never as a
  supervisor-level `EX_IO`. Grepping for `exit 28` and expecting an `EX_IO`
  exit here would be wrong — see "genuine bug" note below is not this; this
  is working as coded, just worth not confusing with the other two.

`relay resume` is conditional and cause-dependent: fix the state-dir
permissions/disk issue for line 43, or the (very unlikely) missing entropy
source for line 602, before resuming — otherwise the identical failure
repeats on the very next attempt.

## 29 — `EX_BUDGET`

Two distinct causes with two distinct `status` values, sharing one exit code.

- **Line 561** — pre-spawn: `COST_TOTAL >= BUDGET_TOTAL` (default
  `$20.00` total). `state_set status "budget"`. This is spend actually
  incurred, tracked cumulatively in `state.json`'s `cost_total`.
- **Line 716** — post-exit, inside `usage_limited()` handling
  (lines 709-731): the CLI's own transport envelope indicated a provider
  usage/rate limit (`api_error_status 429`, or an errored result whose
  fields match `LIMIT_RE`), and either `on_limit` is not `"wait"` or
  `LIMIT_RETRIES` exceeded `max_usage_retries` (default 20).
  `state_set status "usage-limit"`. Note the retry/backoff loop (lines
  712-730) already absorbs ordinary rate limiting — reaching this exit means
  the backoff itself gave up, not that the first limit was hit.

Look at `state.json`'s `cost_total` vs the configured `budget_usd_total` for
the first cause; look at the journal's `usage_limit.halt` line and retry
count for the second. `relay resume` is conditional: raise
`budget_usd_total` for the first cause (otherwise it caps again
immediately), or simply wait out the provider's reset window for the second —
the code's own comment calls a usage limit "weather," not a failure.

## 78 — `EX_PREFLIGHT`

The busiest code: nine distinct call sites, all fail-closed, all before or
between sessions, never mid-session.

| Line | What failed | Journal event |
|-----:|-------------|----------------|
| 38  | `PROJECT` directory does not exist or is not `cd`-able | (none — see below) |
| 83  | `exec.json`'s `acceptance_cmd` is not a valid non-empty argv array | `exec.acceptance-cmd-invalid` |
| 123 | a configured `window_<tier>` is below the 100000-token floor (`RELAY_MIN_WINDOW`) | `config.window-too-small` |
| 176 | `relay-doctor.sh` (invoked as a subprocess, line 173) failed a hard check | `preflight.failed` |
| 196 | window leaves too little room above the measured `ctx_baseline` | `config.window-too-small-for-baseline` |
| 222 | `allow_domains` is not a valid comma-separated hostname list | `config.allow-domains-invalid` |
| 228 | `relay_settings_build` failed to construct the settings payload | `settings.build-failed` |
| 245 | the sandbox enforcement probe (`relay_settings_probe`) failed | `probe.failed` |
| 611 | the per-session argv assertion (`relay_settings_assert_argv`) failed before spawning | `argv.assert-failed` |

Seven of the nine call no `state_set` at all, so for those there is no status
to read. Three of them — lines 38, 83 and 123 — run **before `state.json`
exists**: the file is created at line 145 and the first `state_set` runs at
line 150, so they could not record a status even if they wanted to. The other
four — 196, 222, 228 and 611 — run *after* state is initialized and simply do
not set one, leaving `status` at whatever it was. Do not read "no status" as
"never got that far". Line 38 is also the
only cause with no journal line at all: it predates `RELAY_JOURNAL` being
exported (line 45) and the code path itself has no `relay_journal` call, so
stderr is the sole evidence. The other eight (83, 123, 176, 196, 222, 228,
245, 611) all journal a distinct event named in the table's row above.

The two that *do* record a status are line 176 — `state_set status
"preflight-failed"` (line 175) — and line 245 — `state_set status
"preflight-failed" reason "sandbox-not-enforced"` (line 244). For every other
cause, a `status` of `"running"` in `state.json` after an `EX_IO` exit is
stale, not a live run.

`relay resume` is never the right first move for any of these: nothing ran,
so resuming without changing the reported cause reproduces the exact same
exit immediately. Fix the specific thing named in the stderr message first.

### Reconciling `relay-doctor.sh`'s own "`EX_CONFIG`"

`relay-doctor.sh:6` documents its own `exit 78` in a header comment as
`(EX_CONFIG)`. That name does not exist anywhere as an actual shell variable
— `relay-doctor.sh` never defines any `EX_*` constant; it only ever exits
literal `0` (line 291) or literal `78` (line 284, "a hard check failed").
The only real, defined constant for the number 78 anywhere in this codebase
is `EX_PREFLIGHT`, in `relay-supervisor.sh:52`. When the supervisor invokes
doctor as a subprocess (`relay-supervisor.sh:173`), it does not propagate
doctor's exit code — `if ! bash ".../relay-doctor.sh" ...; then ... exit
"$EX_PREFLIGHT"; fi` (lines 173-177) treats *any* nonzero from doctor as
cause to exit its own `EX_PREFLIGHT`. In practice doctor only ever produces
0 or 78, so the numbers happen to agree, but the names do not: what is
true is that 78 means "preflight refused to start" everywhere in this
codebase, the supervisor's name for that is `EX_PREFLIGHT`, and doctor's
`EX_CONFIG` is stale/unused comment text, not a second real constant.
