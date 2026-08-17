# Troubleshooting

Symptom-first: match what you see against a heading, then follow "what to
run next." For full exit-code meanings see `docs/exit-codes.md`; for why
checks run in the order they do, see `docs/architecture.md`. This document
links to both rather than duplicating them.

## It refuses to start

Every cause below exits 78 (`EX_PREFLIGHT`) before a single session runs.
`docs/exit-codes.md`'s EX_PREFLIGHT table has every cause and line number;
the short answer for all of them is the same — `relay resume` is never the
right first move, because nothing ran. Fix the reported cause first. The
order these run in is `docs/architecture.md` §1a.

- **A configured context window is too small.** Every `window_<tier>` must
  clear 100,000 tokens (`RELAY_MIN_WINDOW`, `relay-supervisor.sh:113`);
  below that, `relay-supervisor.sh:117-123` refuses to start rather than
  run a session that reports "critical" context pressure on tool call one,
  forever.
- **`exec.json`'s `acceptance_cmd` is not a plain argv array.** Relay
  requires a JSON array of 1-32 non-empty strings, each ≤512 characters —
  never a shell string (`relay-supervisor.sh:76-85`). Use `/relay approve`
  to set it correctly.
- **`relay-doctor.sh` failed a hard check.** The supervisor runs it as a
  subprocess first and treats any non-zero exit as cause to refuse
  (`relay-supervisor.sh:173-177`). Run it directly for the full report:
  `bash plugins/relay/scripts/relay-doctor.sh <project> <state>`, or
  `/relay doctor` (`SKILL.md:193-200`). It prints `FAIL`/`fix:` lines and
  never modifies anything itself.
- **The sandbox probe failed.** See the next entry.

Two rarer causes: a window that clears the 100,000 floor can still be
refused once a project has a measured baseline, if it leaves too little
room above it (`relay-supervisor.sh:179-199` — see "Every session hands
off immediately"); a malformed `allow_domains` in `config.json` is
rejected as a hostname list (`relay-supervisor.sh:216-225`).

## The sandbox probe failed

What it checks: `relay_settings_probe()` (`relay-settings.sh:289-336`)
appends a relay-owned canary file to the session's
`sandbox.filesystem.denyRead`, asks a cheap `haiku` session to `cat` it,
and requires the canary's value to never appear in that session's JSON
output or stderr (`relay-settings.sh:322-326`), and the probe session to
have completed cleanly — `.is_error == false`
(`relay-settings.sh:330-333`). Either failure refuses to start
(`relay-supervisor.sh:241-246`, exit 78, `reason
"sandbox-not-enforced"`).

Be precise about what it proves: the code's own comment
(`relay-settings.sh:278-280`) claims the probe confirms both a blocked
read and blocked egress, but the probe makes **no network call at all**.
It proves `denyRead` is enforced and the session ran cleanly; it proves
nothing about egress restriction at runtime (`docs/architecture.md` §1a
makes the same correction). Relay refuses to run either way — a failure
means the whole sandbox basis is unproven, not just the network half.

What to run next: read `$STATE/run/probe-*.json` and
`$STATE/run/probe-*.err`, the probe's own scratch. The result is cached by
a fingerprint of the settings payload plus `claude --version`
(`relay-settings.sh:344-348`, `run/probe.ok`), so a CLI upgrade forces a
fresh proof automatically. A probe that keeps failing after that is a real
sandbox regression in this CLI build, not something to retry past.

## Every session hands off immediately

What you see: every session ends within a handful of tool calls, the
handoff gets rewritten almost right away, and little work lands between
handoffs.

What it means: the context guard (`plugins/relay/hooks/relay-ctx.sh`)
tracks what fraction of the tier's window is used and tells the model to
land the session once that crosses the soft threshold, 60% by default
(`relay-ctx.sh:123`, `SOFT`). A session does not start from zero — system
prompt, tool definitions, and `CLAUDE.md` are already loaded before the
first tool call: 48,070 tokens on one project, ~69,000 on another
(`relay-supervisor.sh:102-103,179-184`). A small window relative to that
baseline reaches 60% almost immediately, so every session hands off having
done almost nothing.

Relay guards the worst case automatically: any `window_<tier>` under the
100,000-token floor is refused at startup (`relay-supervisor.sh:113-126`,
see "It refuses to start"), and once a project has a measured baseline, a
second gate refuses a window that does not clear `baseline * 2.5`
(`relay-supervisor.sh:179-199`).

What to run: compare `state.json`'s `ctx_baseline` against `window_<tier>`
in `config.json`, and check `run/ctx.log` for actual `pct=`/`used=` values
(format under "Nothing is happening"). If the window is not obviously too
small, raise it further — `docs/architecture.md` §6 has the model-ladder
and threshold picture.

## A session ended after a few minutes with rc=1

Do not read a short `rc=1` as a crash by itself. The supervisor's own
journal comment records exactly this from relay's first real run:
`session.exit n=1 rc=1 dur=295s` looked like a crash and was in fact a
budget cap — the session had committed two phases and written a valid
handoff before `--max-budget-usd` cut it off, envelope reporting
`is_error true`, `subtype error_max_budget_usd`, `terminal_reason
budget_exhausted` (`test/cases/c107_budget_cap_is_not_a_usage_limit.sh:4-
6`, which exercises exactly this).

What to read: the journal's `session.reason` line for that session
number, extracted from the session's JSON envelope, never from `$RC`
(`relay-supervisor.sh:642-650`). `rc=1` alone tells you nothing;
`session.reason n=<N> ... budget_exhausted` tells you `budget_usd_per_
session` did its job, not that anything failed. A genuine crash instead
shows up as an unproductive session advancing `stall_count` or
`fastfail_streak`, with no budget reason logged.

What to run next: raise `budget_usd_per_session` in `config.json` if work
genuinely needs more than the $2.00 default (`relay-supervisor.sh:64`), or
plan for sessions that commit sooner. This is not a circuit breaker — the
run continues into the next session on its own; nothing to resume by hand
unless total budget is also exhausted (`EX_BUDGET`, `docs/exit-codes.md`).

## It says BLOCKED and I do not know why

Read `$STATE/BLOCKED.md` first — every cause writes one, sealed with
`<!-- relay:sealed -->` (`relay-supervisor.sh:471`), before exiting 20
(`EX_BLOCKED`). `docs/exit-codes.md`'s EX_BLOCKED section lists all four
causes; the one worth understanding on its own is guardrail drift, because
it is the one relay writes about the *previous session's own words*.

`handoff_guardrail_drift()` (`relay-supervisor.sh:337-340`) scans the
handoff's `done`/`next`/`open_questions` arrays for text matching
`GUARDRAIL_DRIFT_RE` (`relay-supervisor.sh:335`) — permission language
(`allow`, `approved`, `ok`) near something relay would never grant on its
own: force-push, `sudo`, skipping tests, disabling the sandbox. On a
match, the supervisor writes `BLOCKED.md` itself
(`relay-supervisor.sh:743-750`) and halts *before* the handoff is archived
and *before* anything from the session is committed
(`relay-supervisor.sh:739-740`) — ahead of every other content-based
check, because a handoff claiming a relaxed guardrail is the highest-value
thing an injection could write.

What to do: read the flagged lines in `BLOCKED.md` and the session log it
names. If a session genuinely absorbed repository content claiming a
guardrail was relaxed, treat it as a real security event, not a false
alarm. If it is a false positive, fix the handoff by hand and run `relay
resume`; do not disable the check.

## It committed something I did not expect

Relay commits only through `relay_git_commit()`
(`relay-git.sh:218-294`) and never runs `git add -A` or `git add .`
(`relay-git.sh:6-10`). It stages modified/deleted tracked files plus
**untracked files your `.gitignore` does not cover**
(`relay_git_collect_paths`, `relay-git.sh:161-203`: `git diff --name-only
--diff-filter=ACMRTD` plus `git ls-files -o --exclude-standard`,
`relay-git.sh:167-168`). If another tool drops scratch into the working
tree — a formatter's backup file, a script's output — and `.gitignore`
does not name it, relay commits it exactly like any file a session created
on purpose.

A narrower filter runs first: `relay_git_path_is_forbidden()`
(`relay-git.sh:90-104`) refuses credential-shaped paths (`.env*`, `*.pem`,
`id_rsa*`, `.ssh/*`) regardless of `.gitignore`, and a high-confidence
secret scan runs on the staged diff before commit
(`relay-git.sh:109-124,264-285`) — a match resets the stage and blocks
with `BLOCKED.md` (see above). Neither substitutes for `.gitignore`. What
to run: add the offending path to `.gitignore` (or your global
`excludesFile`), then `git rm --cached` it if already committed.

## Nothing is happening

Three places to look, in order of how often they update:

- **`$STATE/journal.log`** — tab-separated `epoch  event  detail` per
  event (`relay_journal`, `lib/relay-lib.sh:43-50`); `tail -f
  $STATE/journal.log` is the documented way to watch a run
  (`SKILL.md:127`). Not growing at all? Check `$STATE/supervisor.out` and
  whether the process is still alive.
- **`$STATE/sessions/<NNN>-<uuid>.log` and `.log.err`** — the current
  session's output. A working session still has a live `claude -p`
  process — check `ps aux | grep 'claude -p'`.
- **`$STATE/run/ctx.log`** — one line per context-guard call
  (`relay-ctx.sh:253-256`). A healthy line looks like:

  ```
  1737091200 pct=42 used=84210 level=0 calls=6
  ```

  (`epoch pct=<%window> used=<tokens> level=<0-3> calls=<count>`). Not
  growing for a while? Check `$STATE/run/hook.alive`, touched on every
  live hook call whether or not it emits a message
  (`relay-ctx.sh:178,182`).

If nothing is updating and the supervisor is gone, the reason should be in
`state.json`'s `status` and the journal's last few lines.

## I want to run relay on relay's own repository

This works, with one mechanical hazard, not a style preference: **bash
reads a script incrementally while executing it.** If a session edits
`relay-supervisor.sh`, `relay-lib.sh`, `relay-git.sh`, `relay-settings.sh`
or `relay-ctx.sh` while the supervisor running that session is partway
through executing one of those files, the process can end up executing
garbage mid-function — not a clean crash, but a corrupted run whose
journal will not explain itself (`docs/phase5-publish-plan.md`, "The
guardrail that is a mechanical hazard, not a preference"). This is exactly
what relay building relay looks like: the plan a session follows and the
code the supervisor is currently running can be the same five files.

The mitigation is procedural: a run whose plan touches relay's own
executables should treat those files as read-only and record any genuine
bug found in them, with evidence, rather than editing them live — land the
fix in a separate, non-self-hosted run. State this in `RUN.md`'s
guardrails section; nothing in relay's preflight or sandbox detects "the
target repository is the one currently running me."

## How do I stop a run right now?

`touch "$STATE/STOP"` — what `/relay stop` does (`SKILL.md:150`) — and
`kill -TERM` on the supervisor both look instant but are not. Neither
interrupts a session already in flight.

Why: for a session's entire duration the supervisor is blocked in a
synchronous, foreground subshell around `relay_timeout`
(`relay-supervisor.sh:620-637`) — not backgrounded, so the shell waits on
that child directly. `STOP` is checked only between sessions: pre-spawn
(`relay-supervisor.sh:549-552`) and post-exit
(`relay-supervisor.sh:704-707`) — never mid-session. The `INT`/`TERM`/
`HUP` traps (`relay_install_traps`, `relay-supervisor.sh:168`, defined
`lib/relay-lib.sh:682-688`, handlers `lib/relay-lib.sh:652-668`, cleanup
`lib/relay-lib.sh:615-650`) genuinely work, but bash defers running a trap
until the current foreground command finishes — while blocked in that
subshell, the signal is queued, not acted on, until the session ends on
its own.

What actually stops it now: kill the `claude -p` child first — find it
with `ps aux | grep 'claude -p'` (or `pgrep -f 'claude -p'`) and `kill`
that pid. That unblocks `relay_timeout`'s `wait`
(`lib/relay-lib.sh:181`) immediately, the supervisor's subshell returns,
and it reaches the post-exit predicates within one poll interval. Only
then does a previously-touched `STOP` or a `kill -TERM` on the supervisor
take effect. Kill the `claude -p` child first, then the supervisor (or
leave `STOP` in place) — that stops a run now, not at the end of whatever
the current session is doing.

## Relay says a run made no progress but it clearly did

What you see: a session commits real work — `git log` shows it — but the
journal records `complete.rejected  no commits were made`, or the run
just carries on into another session instead of accepting `COMPLETE.md`.

What it means: `verify_complete()` compares the live commit count against
`commits_at_start`, captured once when the supervisor starts, from `git
rev-list --count HEAD` (`relay-supervisor.sh:532-533`). The comparison is
`[ -n "$_start" ] && [ "${_now:-0}" -le "$_start" ]`
(`relay-supervisor.sh:480`). Note what that guard does: it does not give
`$_start` a safe numeric default when empty — it skips the whole
comparison. This is a recorded open item, not fixed here: if
`commits_at_start` was ever recorded empty (e.g. `git rev-list --count
HEAD` produced nothing at startup), the no-commits safety check silently
stops applying for the rest of that run, rather than failing toward the
safer answer — and it is the code path a spurious "no progress" report
needs to be diagnosed against.

What to run: compare `state.json`'s `commits_at_start` against `git
rev-list --count HEAD` in the project; a mismatch against what the run
actually did is what this item concerns. Known open defect for the
maintainer — do not hand-edit `relay-supervisor.sh` to work around it.

## Relay gave up with EX_FASTFAIL after some short but productive sessions

What you see: exit 26, `state.json` status `blocked` reason `fastfail`
(`docs/exit-codes.md`'s EX_FASTFAIL entry), even though the sessions
before it clearly committed work.

What it means: the fastfail streak resets only when a session is BOTH
productive AND at least `min_session_secs` long — `[ "$PRODUCTIVE" -eq 1
] && [ "$DUR" -ge "$MIN_SESSION_SECS" ]` (`relay-supervisor.sh:810`).
Anything not satisfying both falls to the `else` branch, where a session
under `min_session_secs` increments `FASTFAIL`
(`relay-supervisor.sh:813-816`) regardless of `$PRODUCTIVE`. A session
that commits real work faster than `min_session_secs` — 45s by default
(`relay-supervisor.sh:63`) — still counts toward the streak; nothing
exempts it for having done something. Recorded open defect, not fixed
here: the reset and increment conditions are not each other's mirror
image.

How to tell this from a real crash loop: read `$STATE/sessions/` logs for
the sessions that tripped it (`journal.log`'s `fastfail.streak` lines name
durations). A real crash loop shows sessions that errored, wrote nothing,
and left no commits. This defect looks different: `git log` shows real
commits landing every few sessions, each just under
`min_session_secs`. If so, raising `min_session_secs` is a workable
mitigation; fixing the streak logic is a maintainer item.

## I have two supervisors running against the same project

What you see: two `relay-supervisor.sh` processes alive for the same
project, each launching its own `claude -p` sessions against the same
tree — or, running relay's own suite, `bash test/run.sh` failing
`c140_lock_contention` and `test/lib/test-relay-lib.sh` failing
`lock_second_fails`.

What it means: the single-instance lock (`relay-supervisor.sh:162-167`,
`relay_lock` in `lib/relay-lib.sh:212-251`) decides whether a lock
directory is stale by asking if its owner pid is alive, inside
`_relay_lock_try_break()` (`lib/relay-lib.sh:255-316`). On the same host,
liveness is `ps -p "$_rlb_pid" >/dev/null 2>&1`
(`lib/relay-lib.sh:279`); if that `ps` call cannot run at all — blocked by
a sandbox, or unavailable — its non-zero exit reads exactly like "that pid
is not running," and `_rlb_stale` is set to 1
(`lib/relay-lib.sh:280`), breaking a lock that may still have a live
owner. Recorded open item, not fixed here.

What to check: from the same environment relay runs in — the same
sandbox, if any — run `ps -p $$`. Exit 127 instead of your own shell's
pid means you have this problem: any lock a supervisor started from that
environment holds can be broken out from under it. `c140_lock_contention`
and `lock_second_fails` are the two tests that would start failing.
