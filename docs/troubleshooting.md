# Troubleshooting

Symptom-first: match what you actually see against a heading below, then
follow "what to run next." For the full meaning of every exit code, see
`docs/exit-codes.md`; for why the checks run in the order they do, see
`docs/architecture.md`. This document does not duplicate either table — it
links to them.

## It refuses to start

Every cause below ends the process before a single Claude Code session
runs, with exit code 78 (`EX_PREFLIGHT`). `docs/exit-codes.md`'s EX_PREFLIGHT
table lists every cause with its line number; the short answer for all of
them is the same: `relay resume` is never the right first move, because
nothing ran — fix the specific thing reported first. The order these run in
is in `docs/architecture.md` §1a.

- **A configured context window is too small.** Every `window_<tier>` must
  clear 100,000 tokens (`RELAY_MIN_WINDOW`, `relay-supervisor.sh:113`);
  below that, `relay-supervisor.sh:117-123` refuses to start rather than run
  a session that reports "critical" context pressure on its very first tool
  call, forever.
- **`exec.json`'s `acceptance_cmd` is not a plain argv array.** Relay
  requires a JSON array of 1-32 non-empty strings, each at most 512
  characters — never a shell string (`relay-supervisor.sh:76-85`). Use
  `/relay approve` to set it correctly.
- **`relay-doctor.sh` failed a hard check.** The supervisor runs it as a
  subprocess before anything else and treats any non-zero exit as cause to
  refuse (`relay-supervisor.sh:173-177`). Run it directly for the full
  report — `bash plugins/relay/scripts/relay-doctor.sh <project> <state>`,
  or `/relay doctor` (`SKILL.md:193-200`). It prints `FAIL` lines with a
  `fix:` line under each, and never modifies anything itself.
- **The sandbox probe failed.** See the next entry.

Two rarer preflight causes: a window that clears the 100,000 floor can
still be refused once a project has a measured baseline, if it does not
leave enough room above that baseline (`relay-supervisor.sh:179-199` — see
"Every session hands off immediately" below), and a malformed
`allow_domains` value in `config.json` is rejected as a hostname list
(`relay-supervisor.sh:216-225`).

## The sandbox probe failed

What it actually checks: `relay_settings_probe()`
(`relay-settings.sh:289-336`) appends a relay-owned canary file to the
session's `sandbox.filesystem.denyRead` list, asks a cheap `haiku` session
to `cat` it, and requires two things: the canary's value never appears in
that session's JSON output or stderr (`relay-settings.sh:322-326`), and the
probe session itself completed cleanly — `.is_error == false`
(`relay-settings.sh:330-333`). If either fails, relay refuses to start at
all (`relay-supervisor.sh:241-246`, exit 78, `state_set status
"preflight-failed" reason "sandbox-not-enforced"`).

Be precise about what that does and does not prove, because the code's own
comment overstates it: `relay-settings.sh:278-280` claims the probe
confirms both a blocked read and blocked egress, but the probe makes **no
network call at all**. It proves `denyRead` is enforced and that a session
under this payload runs cleanly; it says nothing about whether network
egress is actually restricted at runtime. `docs/architecture.md` §1a makes
the same correction. Relay refuses to run either way — a probe failure
means the whole basis for trusting the sandbox this run is unproven, not
just the network half.

What to run next: the probe's own scratch lives under `$STATE/run/probe-*
.json` and `$STATE/run/probe-*.err` — read those for what the probe
session actually did. A probe result is cached by a fingerprint of the
settings payload plus `claude --version`
(`relay-settings.sh:344-348`, cached at `run/probe.ok`), so a CLI upgrade
forces a fresh proof automatically. If the probe keeps failing after that,
treat it as a real sandbox regression in this Claude Code build, not
something to retry past.

## Every session hands off immediately

What you see: every session ends within a handful of tool calls,
`continue.json` gets rewritten almost right away each time, and little or
no real work lands between handoffs.

What it means: the context guard (`plugins/relay/hooks/relay-ctx.sh`)
computes what fraction of the tier's context window is already used, and
starts telling the model to land the session once that crosses the soft
threshold — 60% by default (`relay-ctx.sh:123`, `SOFT`). A session does not
start from zero: its system prompt, tool definitions, and the project's
`CLAUDE.md` are already loaded before the first tool call, measured at
48,070 tokens on one project and around 69,000 on another
(`relay-supervisor.sh:102-103,179-184`). If the configured window is small
relative to that baseline, 60% of the window is reached almost immediately,
and every session hands off having done almost nothing.

Relay guards the worst case automatically: any `window_<tier>` under the
100,000-token floor is refused at startup (`relay-supervisor.sh:113-126`,
see "It refuses to start"), and once a project has completed one session
and relay has measured its actual baseline cost, a second gate refuses to
restart with a window that does not clear `baseline * 2.5`, leaving the 60%
soft threshold real room above it (`relay-supervisor.sh:179-199`).

What to run: compare `state.json`'s `ctx_baseline` against the configured
`window_<tier>` in `config.json`, and check `run/ctx.log` for the actual
`pct=`/`used=` values a recent session reported (line format under "Nothing
is happening" below). If the window is not obviously too small and this
still happens, raise it further — `docs/architecture.md` §6 has the full
model-ladder and threshold picture.

## A session ended after a few minutes with rc=1

Do not read a short `rc=1` as a crash by itself. The supervisor's own
journal comment records exactly this from relay's first real run:
`session.exit n=1 rc=1 dur=295s` looked like a crash and was in fact a
budget cap — the session had committed two phases and written a valid
handoff before `--max-budget-usd` cut it off, with the CLI's own envelope
reporting `is_error true`, `subtype error_max_budget_usd`, `terminal_reason
budget_exhausted`
(`test/cases/c107_budget_cap_is_not_a_usage_limit.sh:4-6`, which exercises
exactly this case).

What to read: the journal's `session.reason` line for that session number.
The supervisor extracts it from the session's own JSON envelope, never from
`$RC` (`relay-supervisor.sh:642-650`) — `rc=1` alone tells you nothing;
`session.reason n=<N> ... budget_exhausted` tells you it was
`budget_usd_per_session` doing its job, not a failure. A genuine crash
looks different: it shows up as an unproductive session that advances
`stall_count` or `fastfail_streak` instead of reporting a budget reason.

What to run next: raise `budget_usd_per_session` in `config.json` if the
work genuinely needs more per session than the default $2.00
(`relay-supervisor.sh:64`), or plan for a session that checkpoints and
commits sooner. This counter advances the run normally — it is not a
circuit breaker, and there is nothing to resume by hand unless the total
budget is also exhausted (`EX_BUDGET`, see `docs/exit-codes.md`).

## It says BLOCKED and I do not know why

Read `$STATE/BLOCKED.md` first — every cause writes one, sealed with
`<!-- relay:sealed -->` (`relay-supervisor.sh:471`), before the run exits
20 (`EX_BLOCKED`). `docs/exit-codes.md`'s EX_BLOCKED section lists all four
causes with their line numbers; the one worth understanding on its own is
guardrail drift, because it is the one relay writes about the *previous
session's own words*.

`handoff_guardrail_drift()` (`relay-supervisor.sh:337-340`) scans the
handoff's `done`, `next` and `open_questions` arrays for text matching
`GUARDRAIL_DRIFT_RE` (`relay-supervisor.sh:335`) — permission language
(`allow`, `approved`, `ok`) sitting near something relay would never grant
on its own: a force-push, `sudo`, skipping tests, disabling the sandbox. On
a match, the supervisor writes `BLOCKED.md` itself
(`relay-supervisor.sh:743-750`) and halts *before* that handoff is archived
and *before* anything from the session is committed
(`relay-supervisor.sh:739-740`). This runs ahead of every check that would
otherwise act on a session's content, specifically because a handoff
claiming a relaxed guardrail is the highest-value thing a prompt injection
could write.

What to do: read the flagged lines in `BLOCKED.md` and the session log it
names. If a previous session genuinely absorbed repository content telling
it a guardrail had been relaxed, treat that as a real security event, not a
false alarm — it is prompt injection working exactly as the mitigation
expects. If it is a false positive (the phrase merely matched), fix the
handoff by hand and run `relay resume`; do not disable the check itself.

## It committed something I did not expect

Relay only ever commits through `relay_git_commit()` (`relay-git.sh:218-
294`), and it never runs `git add -A` or `git add .`
(`relay-git.sh:6-10`). What it stages instead is the union of
modified/deleted tracked files plus **untracked files your `.gitignore`
does not cover** (`relay_git_collect_paths`, `relay-git.sh:161-203`: `git
diff --name-only --diff-filter=ACMRTD` plus `git ls-files -o
--exclude-standard`, `relay-git.sh:167-168`). If some other tool in your
workflow drops scratch files into the working tree — a formatter's backup
file, a local script's output — and your `.gitignore` does not name it,
relay picks it up and commits it exactly like any file a session created on
purpose.

A narrower filter runs before staging: `relay_git_path_is_forbidden()`
(`relay-git.sh:90-104`) refuses credential-shaped paths by name (`.env*`,
`*.pem`, `id_rsa*`, `.ssh/*`, and similar) regardless of `.gitignore`, and a
high-confidence secret scan runs on the staged diff before the commit lands
(`relay-git.sh:109-124,264-285`) — a match resets the stage and blocks with
`BLOCKED.md` instead of committing (see "It says BLOCKED" above). Neither
is a substitute for `.gitignore`; they catch credential shapes, not general
scratch. What to run: add the offending path to the project's `.gitignore`
(or your global `excludesFile`) so future sessions never see it as
untracked, then `git rm --cached` it if it is already committed.

## Nothing is happening

Three places to look, in order of how often they update:

- **`$STATE/journal.log`** — a tab-separated `epoch  event  detail` line
  per event (`relay_journal`, `lib/relay-lib.sh:43-50`); `tail -f
  $STATE/journal.log` is the documented way to watch a live run
  (`SKILL.md:127`). If this file is not growing at all, the supervisor
  process may have died — check `$STATE/supervisor.out` for what it
  printed before it stopped.
- **`$STATE/sessions/<NNN>-<uuid>.log` and `.log.err`** — the current
  session's own output. A session that is genuinely working still has a
  live `claude -p` process — check `ps aux | grep 'claude -p'`.
- **`$STATE/run/ctx.log`** — one line per context-guard call, appended by
  `relay-ctx.sh:253-256`. A healthy line looks like:

  ```
  1737091200 pct=42 used=84210 level=0 calls=6
  ```

  (`epoch pct=<percent-of-window> used=<tokens> level=<0-3>
  calls=<count>`). If this file exists but has not grown in a while, check
  `$STATE/run/hook.alive`, touched on every live hook invocation
  regardless of whether it emits a message (`relay-ctx.sh:178,182`).

If none of these are updating and the supervisor process is gone, the run
stopped for a reason that should be in `state.json`'s `status` and
`journal.log`'s last few lines — check those before assuming a hang.

## I want to run relay on relay's own repository

This works, with one hazard that is mechanical, not a style preference:
**bash reads a script incrementally while executing it.** If a session
edits `relay-supervisor.sh`, `relay-lib.sh`, `relay-git.sh`,
`relay-settings.sh` or `relay-ctx.sh` while the very supervisor process
running that session is partway through executing one of those files, the
running process can end up executing garbage mid-function — not a clean
crash, but a corrupted run whose journal will not explain itself
(`docs/phase5-publish-plan.md`, "The guardrail that is a mechanical hazard,
not a preference"). This is exactly what relay building relay looks like:
the plan text a session is following and the code the supervisor overseeing
it is currently running can be the same five files.

The mitigation is procedural, not something relay enforces in code: a run
whose plan touches relay's own executables should treat those files as
read-only and record any genuine bug found in them, with evidence, rather
than editing them live — land the actual fix in a separate, non-self-
hosted run afterward. If you are directing such a run, say so in `RUN.md`'s
guardrails section explicitly; nothing in relay's preflight or sandbox
detects "the target repository is the one currently running me."

## How do I stop a run right now?

`touch "$STATE/STOP"` — what `/relay stop` does (`SKILL.md:150`) — and
sending `kill -TERM` to the supervisor process both look instant but are
not. Neither interrupts a session already in flight.

Why: for the entire duration of a session, the supervisor is blocked in a
synchronous, foreground subshell around `relay_timeout`
(`relay-supervisor.sh:620-637`) — it is not backgrounded, so the shell is
waiting on that child directly. `STOP` is only ever checked between
sessions: at the pre-spawn gate (`relay-supervisor.sh:549-552`) and the
post-exit gate (`relay-supervisor.sh:704-707`) — there is no check while a
session is running. The `INT`/`TERM`/`HUP` traps installed by
`relay_install_traps` (`relay-supervisor.sh:168`, defined at
`lib/relay-lib.sh:682-688`, handlers at `lib/relay-lib.sh:652-668`,
cleanup logic at `lib/relay-lib.sh:615-650`) genuinely do work, but bash
defers running a trap until the current foreground command finishes; while
blocked in that subshell, the signal is queued, not acted on, and is only
handled once the session ends on its own.

What actually stops it now: kill the `claude -p` child process first — find
it with `ps aux | grep 'claude -p'` (or `pgrep -f 'claude -p'`) and `kill`
that pid. That unblocks `relay_timeout`'s `wait` (`lib/relay-lib.sh:181`)
immediately, the foreground subshell in the supervisor returns, and the
supervisor reaches its post-exit predicates within one poll interval. Only
then — with the session actually over — does a previously-touched `STOP`
file or a `kill -TERM` sent to the supervisor take effect. Kill the `claude
-p` child first, then the supervisor (or leave `STOP` in place); that is
the reliable way to stop a run right now rather than at the end of whatever
the current session happens to be doing.

## Relay says a run made no progress but it clearly did

What you see: a session commits real work — `git log` shows it — but the
journal records `complete.rejected  no commits were made`, or the run
simply carries on into another session instead of accepting `COMPLETE.md`,
which reads as relay claiming nothing happened.

What it actually means: `verify_complete()` decides this by comparing the
live commit count against `commits_at_start`, a value captured exactly
once, when the supervisor starts, from `git rev-list --count HEAD`
(`relay-supervisor.sh:532-533`). The comparison itself is `[ -n "$_start"
] && [ "${_now:-0}" -le "$_start" ]` (`relay-supervisor.sh:480`). Note what
that guard actually does: it does not give `$_start` a safe numeric default
when it is empty — it skips the whole comparison instead. This is a
recorded open item, not fixed here: if `commits_at_start` was ever recorded
empty (for instance if `git rev-list --count HEAD` produced nothing at
supervisor startup), the no-commits safety check silently stops applying
for the rest of that run rather than failing toward the safer answer. It is
also exactly the code path a report of a spurious "no progress" rejection
needs to be diagnosed against.

What to run: compare `state.json`'s `commits_at_start` field against `git
rev-list --count HEAD` in the project yourself; a mismatch against what the
run actually did is what this item concerns. This is a known open defect
for the maintainer to fix — do not attempt a workaround by hand-editing
`relay-supervisor.sh`.

## Relay gave up with EX_FASTFAIL after some short but productive sessions

What you see: exit code 26, `state.json` status `blocked` reason
`fastfail` (see `docs/exit-codes.md`'s EX_FASTFAIL entry), even though the
last handful of sessions before it clearly committed work.

What it actually means: the fastfail streak only resets when a session is
BOTH productive AND at least `min_session_secs` long — `[ "$PRODUCTIVE" -eq
1 ] && [ "$DUR" -ge "$MIN_SESSION_SECS" ]` (`relay-supervisor.sh:810`).
Everything that does not satisfy both falls into the `else` branch, and a
session under `min_session_secs` increments `FASTFAIL` there
(`relay-supervisor.sh:813-816`) regardless of whether `$PRODUCTIVE` was 1.
So a session that commits real work quickly — faster than
`min_session_secs`, 45 seconds by default (`relay-supervisor.sh:63`) —
still counts toward the fastfail streak; nothing exempts it just because it
did something. This is a recorded open defect, not fixed here: the reset
condition and the increment condition are not the mirror image of each
other that they should be.

How to tell this from a real crash loop: read the session logs in
`$STATE/sessions/` for the sessions that tripped it — `journal.log`'s
`fastfail.streak` lines name the durations. A real crash loop shows
sessions that errored out, wrote nothing, and left no new commits. This
defect looks different: `git log` shows real commits landing every few
sessions, each one just faster than `min_session_secs`. If that is what you
see, raising `min_session_secs` is a workable mitigation; fixing the streak
logic itself is a maintainer item.

## I have two supervisors running against the same project

What you see: two `relay-supervisor.sh` processes alive for the same
project at once, each launching its own `claude -p` sessions against the
same working tree — or, if you are running relay's own test suite, `bash
test/run.sh` failing case `c140_lock_contention` and
`test/lib/test-relay-lib.sh` failing its `lock_second_fails` case.

What it actually means: the single-instance lock
(`relay-supervisor.sh:162-167`, `relay_lock` in
`lib/relay-lib.sh:212-251`) decides whether an existing lock directory is
stale by asking whether its recorded owner pid is still alive, inside
`_relay_lock_try_break()` (`lib/relay-lib.sh:255-316`). On the same host,
liveness is decided by `ps -p "$_rlb_pid" >/dev/null 2>&1`
(`lib/relay-lib.sh:279`); if that `ps` call itself cannot run — blocked by
a sandbox, or simply unavailable — its non-zero exit is read exactly the
same as "that pid is not running," and `_rlb_stale` is set to 1
(`lib/relay-lib.sh:280`), which breaks a lock that may still have a live
owner. This is a recorded open item, not fixed here.

What to check: from the same environment relay itself runs in — the same
sandbox, if any — run `ps -p $$`. If that exits 127 instead of reporting
your own shell's pid, you have this problem: any lock a `relay-supervisor.sh`
started from that environment holds can be broken out from under it by a
second run. `c140_lock_contention` and `lock_second_fails` are the two
tests that would start failing.
