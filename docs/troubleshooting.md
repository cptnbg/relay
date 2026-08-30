# Troubleshooting

Symptom-first: match what you see against a heading, then follow "what to
run next." For full exit-code meanings see `docs/exit-codes.md`; for why
checks run in the order they do, see `docs/architecture.md`. This document
links to both rather than duplicating them.

## It refuses to start

Every cause below exits 78 (`EX_PREFLIGHT`) before a single session runs.
`docs/exit-codes.md`'s EX_PREFLIGHT table has every cause and line number;
the short answer for all of them is the same — `/relay-resume` is never the
right first move, because nothing ran. Fix the reported cause first. The
order these run in is `docs/architecture.md` §1a.

- **A configured context window is too small.** Every `window_<tier>` must
  clear 100,000 tokens (`RELAY_MIN_WINDOW`, `relay-supervisor.sh:402`);
  below that, `relay-supervisor.sh:403-414` refuses to start rather than
  run a session that reports "critical" context pressure on tool call one,
  forever.
- **`exec.json`'s `acceptance_cmd` is not a plain argv array.** Relay
  requires a JSON array of 1-32 non-empty strings, each ≤512 characters —
  never a shell string (`relay-supervisor.sh:238-246`). Use `/relay-approve`
  to set it correctly — approving also records the `exec_hash` without which
  the supervisor refuses at preflight (`relay-supervisor.sh:254-260`).
- **`relay-doctor.sh` failed a hard check.** The supervisor runs it as a
  subprocess first and treats any non-zero exit as cause to refuse
  (`relay-supervisor.sh:436-440`). Run it directly for the full report:
  `bash plugins/relay/scripts/relay-doctor.sh <project> <state>`, or
  `/relay-doctor` (`SKILL.md:485-497`). It prints `FAIL`/`fix:` lines and
  applies none of them: it modifies nothing *outside relay's own state
  directory* (`relay-doctor.sh:11-13`). Inside it, doctor does write — it
  creates `$STATE` and round-trips a `.doctor-probe.$$` file it then
  deletes, which is how it proves atomic rename works there
  (`relay-doctor.sh:316-326`). Your repository and your configuration are
  untouched either way.
- **The sandbox probe failed.** See the next entry.

More refusals, all fail-closed, all listed with line numbers in
`docs/exit-codes.md`'s EX_PREFLIGHT table: a window that clears the 100,000
floor can still be refused once a project has a measured baseline, if it
leaves too little room above it (`relay-supervisor.sh:442-462` — see "Every
session hands off immediately"); a malformed `allow_domains` in `config.json`
is rejected as a hostname list (`relay-supervisor.sh:479-488`); a non-numeric
value in any numeric config key refuses rather than silently disabling a cap
(`relay-supervisor.sh:170-191`); a `plan_path` that does not resolve to an
existing file refuses (`relay-supervisor.sh:303-328`); a `model_tier` outside
`opus|sonnet|fable` refuses (`relay-supervisor.sh:375-382`); missing or stale
consent (`consent.notice_hash`) fails doctor's hard check
(`relay-doctor.sh:338-371`); and the injection / guardrail-drift filters are
self-tested against the live `grep` at startup — if either cannot be shown to
fire (ugrep rejects complex patterns with exit 2 and no output), relay
refuses rather than run with a silently disabled defence
(`relay-supervisor.sh:823-846`).

## The sandbox probe failed

What it checks: `relay_settings_probe()` (`relay-settings.sh:538-637`)
appends a relay-owned canary file to the session's
`sandbox.filesystem.denyRead` and asks one cheap `haiku` session to do two
things — `cat` the canary with the output redirected into a proof file, and
`curl` a host that is not in `network.allowedDomains`, writing `code=`/`rc=`
marker lines. Both commands leave their evidence in files the supervisor
reads; the verdict never depends on the model's own summary. It refuses to
start if the canary's value appears in `$_readproof`, the session's JSON
output, or stderr (`relay-settings.sh:630-634`), if the session did not
complete cleanly — `.is_error == false` (`:577-580`) — or if the host
answered (`:582-590`). Any of those refuses the run
(`relay-supervisor.sh:612-617`, exit 78, `reason "sandbox-not-enforced"`).

Be precise about what the egress half proves.
`relay_settings_egress_verdict()` (`relay-settings.sh:468-536`) reads
curl's own status code and exit code out of
`$STATE/work/probe/probe-egress.txt` — by the `code=`/`rc=` markers, never
"the first digits in the file" — and reports `reachable`, `blocked`, or
`inconclusive`. Only `reachable`
refuses the run. `inconclusive` — no `curl` on the box, or a session that
never finished the command — is journaled as `probe.egress inconclusive`
and the run proceeds on the canary's proof, because `curl` is not one of
relay's dependencies. If that line is in your journal, egress restriction
was configured but not demonstrated on this machine; `test/lint/probe0-sandbox.sh`
is the paid probe that demonstrates it outright.

What to run next: read `$STATE/work/probe/probe-read.json` and
`$STATE/work/probe/probe-read.err`, the probe's own scratch. The result is
cached by a fingerprint of the settings payload plus `claude --version`
(`relay-settings.sh:767-771`, stored supervisor-side at
`$STATE/run/probe.ok`); the fingerprint itself must be a real 40-hex blob id
or relay refuses outright (`relay-supervisor.sh:596-604`) — an empty one used
to read as a cache hit and skip the proof. A CLI upgrade forces a
fresh proof automatically. A probe that keeps failing after that is a real
sandbox regression in this CLI build, not something to retry past.

Note `RELAY_SKIP_PROBE=1` exists for relay's own test suite and skips the proof
entirely, in either mode. It is not a fix and not a supported way to run: it
gets you a session whose settings were never demonstrated to take effect.

`RELAY_SKIP_SELFTEST=1` is the second of exactly two such hatches, and until now
it was written down nowhere. It skips `relay_selftest_guards`, the check that
proves the injection and guardrail-drift filters actually fire under whatever
`grep` is on this PATH — the check that exists because ugrep rejects an
over-complex pattern with exit 2 and no output, turning a security filter into a
healthy-looking no-op. Same standing as the first: the suite's, not yours, and a
run started with it set has filters nobody demonstrated. Neither variable is
read from `config.json` and neither can be set by a repository.

## The probe failed in full-trust mode

With `sandbox_mode: "disabled"` the probe is a different function,
`relay_settings_probe_disabled()` (`relay-settings.sh:663-765`), and it refuses
for different reasons — both reported as exit 78 with
`reason "settings-not-accepted"` rather than `"sandbox-not-enforced"`. There is
no sandbox to prove, so what it proves is that the payload was accepted at all.

- **`probe.hook missing`, stderr says "SETTINGS PAYLOAD NOT PROVABLY ACCEPTED".**
  Relay's inline hook never ran, which is what a payload the CLI parsed and
  discarded looks like. That would mean a run with no context guard and no deny
  list while the journal claimed otherwise, so relay stops. Check
  `$STATE/work/probe/probe-read.json` and `probe-read.err`, and confirm
  `plugins/relay/hooks/relay-ctx.sh` exists and is readable — `/relay-doctor`'s
  "relay components" section checks exactly that. A CLI upgrade that changed the
  settings schema is the other candidate.

  There is a third cause that is not relay's fault at all: **the probe session
  refused the prompt.** The marker only appears after a tool call, so a model
  that declines to run any command leaves exactly the same evidence as a dropped
  payload. Read `$STATE/work/probe/probe-read.json`'s `result` field — a refusal
  says so in plain prose, and `permission_denials` will be `0` because nothing
  was ever attempted. This was observed for real while building the probe
  (`docs/security.md`, finding 7): scratch filenames that read as bait invite it.
  Relay's own probe scratch is deliberately mundane, so if you see this on an
  unmodified relay, re-run once before digging further.
- **`probe.trust-canary unreadable`, stderr says "reads are still confined".**
  The payload was accepted (the hook fired) but a file relay could read outside
  the sandbox was still unreadable inside the probe session, so
  `sandbox.enabled: false` did not take effect as configured. Relay refuses
  rather than run something that is neither mode: you asked for full trust and
  would silently get confinement.

`probe.egress` is journaled in this mode and never refuses. Seeing
`blocked mode=disabled` on a machine with no network is expected and means
nothing about the mode.

If you did not intend full trust, the fix is `sandbox_mode` in
`$STATE/config.json` — check it, set it back to `enforced`, and resume. Config
is read once at supervisor startup, so an edit mid-run does nothing until the
next launch.

## A full-trust run halted on guardrail-drift

What you see: exit 20, `reason "guardrail-drift"`, and the flagged handoff line
is about the sandbox being off — which is true and was your decision.

Relay does not weaken that filter in full-trust mode, deliberately: with the
sandbox gone it is one of the few rails left, and a filter that switches off in
the highest-blast-radius mode is worth very little. The detector needs a
permission word and a danger word on the same line, so a session that writes
"the user approved disabling the sandbox" trips it while "this run is full-trust
mode" does not.

The fix is vocabulary, not configuration. `/relay-init` writes the phrase
"full-trust mode" into RUN.md's Guardrails section precisely so sessions echo
something accurate that does not match; if your RUN.md predates that, reword it
there. Read the flagged handoff first — the halt is cheap and the alternative
failure mode (a real relaxation slipping through) is not.

## Every session hands off immediately

What you see: every session ends within a handful of tool calls, the
handoff gets rewritten almost right away, and little work lands between
handoffs.

What it means: the context guard (`plugins/relay/hooks/relay-ctx.sh`)
tracks what fraction of the tier's window is used and tells the model to
land the session once that crosses the soft threshold, 60% by default
(`relay-ctx.sh:128`, `SOFT`). A session does not start from zero — system
prompt, tool definitions, and `CLAUDE.md` are already loaded before the
first tool call: 48,070 tokens on one project, ~69,000 on another
(`relay-supervisor.sh:391-398, 442-447`). A small window relative to that
baseline reaches 60% almost immediately, so every session hands off having
done almost nothing.

Relay guards the worst case automatically: any `window_<tier>` under the
100,000-token floor is refused at startup (`relay-supervisor.sh:402-414`,
see "It refuses to start"), and once a project has a measured baseline, a
second gate refuses a window that does not clear `baseline * 2.5`
(`relay-supervisor.sh:442-462`).

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
(`relay-supervisor.sh:1416-1432`). `rc=1` alone tells you nothing;
`session.reason n=<N> ... budget_exhausted` tells you `budget_usd_per_
session` did its job, not that anything failed. A genuine crash instead
shows up as an unproductive session advancing `stall_count` or
`fastfail_streak`, with no budget reason logged.

What to run next: raise `budget_usd_per_session` in `config.json` if work
genuinely needs more than the $2.00 default (`relay-supervisor.sh:148`), or
plan for sessions that commit sooner. This is not a circuit breaker — the
run continues into the next session on its own; nothing to resume by hand
unless total budget is also exhausted (`EX_BUDGET`, `docs/exit-codes.md`).

## It says BLOCKED and I do not know why

Read `$STATE/work/BLOCKED.md` first — every cause writes one, sealed with
`<!-- relay:sealed -->` (`sealed()`, `relay-supervisor.sh:1239`), before
exiting 20 (`EX_BLOCKED`). `docs/exit-codes.md`'s EX_BLOCKED section lists
all five causes; the one worth understanding on its own is guardrail drift,
because it is the one relay writes about the *previous session's own words*.

`handoff_guardrail_drift()` (`relay-supervisor.sh:705-709`) scans the
handoff's `done`/`next`/`open_questions` arrays with two AND-ed patterns on
the same line — a permission word (`GUARDRAIL_PERM_RE`: `allow`, `approved`,
`ok`, …) and a danger word (`GUARDRAIL_DANGER_RE`: force-push, `sudo`,
skipping tests, disabling the sandbox; `relay-supervisor.sh:699-700`).
Two simple patterns rather than one big regex, because the old single
pattern exceeded ugrep's complexity limits and silently never fired — and a
startup self-test now refuses to run at all if the filters cannot be shown
to fire under the live `grep` (`relay-supervisor.sh:717-742`). On a
match, the supervisor writes `work/BLOCKED.md` itself
(`relay-supervisor.sh:1734-1741`) and halts *before* the handoff is archived
and *before* anything from the session is committed
(`relay-supervisor.sh:1730-1731`) — ahead of every other content-based
check, because a handoff claiming a relaxed guardrail is the highest-value
thing an injection could write.

What to do: read the flagged lines in `BLOCKED.md` and the session log it
names. If a session genuinely absorbed repository content claiming a
guardrail was relaxed, treat it as a real security event, not a false
alarm. If it is a false positive, fix the handoff by hand and run
`/relay-resume`; do not disable the check.

## It committed something I did not expect

Relay commits only through `relay_git_commit()`
(`relay-git.sh:241-341`) and never runs `git add -A` or `git add .`
(`relay-git.sh:6-10`). It stages modified/deleted tracked files plus
**untracked files your `.gitignore` does not cover**
(`relay_git_collect_paths`, `relay-git.sh:184-226`: `git diff --name-only
--diff-filter=ACMRTD` plus `git ls-files -o --exclude-standard`,
`relay-git.sh:190-191`, staged with `--literal-pathspecs` so a file named
`*` stages as one file, never as a glob over the whole repo,
`relay-git.sh:67-72`). If another tool drops scratch into the working
tree — a formatter's backup file, a script's output — and `.gitignore`
does not name it, relay commits it exactly like any file a session created
on purpose.

A narrower filter runs first: `relay_git_path_is_forbidden()`
(`relay-git.sh:113-127`) refuses credential-shaped paths (`.env*`, `*.pem`,
`id_rsa*`, `.ssh/*`) regardless of `.gitignore`, and a high-confidence
secret scan runs before commit on the raw content of every staged blob —
`git cat-file`, not `git diff`, because an in-tree `.gitattributes` marking
a path `-diff` makes the diff silently empty for exactly the file an
attacker would hide a credential in (`relay-git.sh:291-332`, against the
patterns at `relay-git.sh:132-147`) — a
match resets the stage and blocks with `BLOCKED.md` (see above). Neither substitutes for `.gitignore`. What
to run: add the offending path to `.gitignore` (or your global
`excludesFile`), then `git rm --cached` it if already committed.

## Nothing is happening

Three places to look, in order of how often they update:

- **`$STATE/journal.log`** — tab-separated `epoch  event  detail` per
  event (`relay_journal`, `lib/relay-lib.sh:43-50`); `tail -f
  $STATE/journal.log` is the documented way to watch a run
  (`SKILL.md:374`). Not growing at all? Check `$STATE/supervisor.out` and
  whether the process is still alive.
- **`$STATE/sessions/<NNN>-<uuid>.log` and `.log.err`** — the current
  session's output. A working session still has a live `claude -p`
  process — check `ps aux | grep 'claude -p'`.
- **`$STATE/work/run/ctx.log`** — one line per context-guard call that
  actually samples the transcript (`relay-ctx.sh:268-271`). That is *not*
  every tool call: the guard throttles itself against the age of its last
  sample, skipping the whole active path — including this log — when the
  previous one is under 30 seconds old below 40% context, or under 15
  seconds old from 40% (`relay-ctx.sh:153-179`). From 55% the interval is
  0, so every call samples. A healthy line looks like:

  ```
  1737091200 pct=42 used=84210 level=0 calls=6
  ```

  (`epoch pct=<%window> used=<tokens> level=<0-3> calls=<count>`). A gap
  between lines is normal at low context — that is the throttle, not a
  stall. `calls=` is incremented on *every* invocation, before the
  throttle (`relay-ctx.sh:147`), so `calls=` jumping by more than one
  between consecutive lines is the guard working as designed, not lost
  events. Not growing at all for a while? Check
  `$STATE/work/run/hook.alive`, touched by every call that gets past the
  throttle whether or not it emits a message (`relay-ctx.sh:193, 197`).

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
fix in a separate, non-self-hosted run. State the read-only rule in
`RUN.md`'s guardrails section, but route each finding to
`$STATE/work/HUMAN-TASKS.md` — that is where relay's own session prompt
tells a session to put anything only a human can act on
(`relay-supervisor.sh:1012-1013`), and it is the convention this repository's
own plan uses (`docs/phase5-publish-plan.md:132-134`). Appending findings
to `RUN.md` instead buries them inside the mission text that every later
session re-reads as instructions. Nothing in relay's preflight or sandbox
detects "the target repository is the one currently running me."

## How do I stop a run right now?

`touch "$STATE/STOP"` — what `/relay-stop` does (`SKILL.md:375`) — and
`kill -TERM` on the supervisor both look instant but are not. Neither
interrupts a session already in flight.

Why: for a session's entire duration the supervisor is blocked in a
synchronous, foreground subshell around `relay_timeout`
(`relay-supervisor.sh:1384-1401`) — not backgrounded, so the shell waits on
that child directly. `STOP` is checked only between sessions: pre-spawn
(`relay-supervisor.sh:1396-1399`) and post-exit
(`relay-supervisor.sh:1673-1676`) — never mid-session. The `INT`/`TERM`/
`HUP` traps (`relay_install_traps`, `relay-supervisor.sh:431`, defined
`lib/relay-lib.sh:708-714`, handlers `lib/relay-lib.sh:678-694`, cleanup
`lib/relay-lib.sh:641-676`) genuinely work, but bash defers running a trap
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
rev-list --count HEAD` (`relay-supervisor.sh:1307-1315`). Both sides are
normalised to a number before the comparison, and an unreadable count
becomes `0` (`relay-supervisor.sh:1007-1010`).

First check which rule you are under. The commit count is a **hard veto
only when no acceptance command is configured** (`relay-supervisor.sh:
753-757`): with one configured, a passing acceptance command accepts the
COMPLETE even with zero new commits — the case of resuming after the work
was already finished — and journals `complete.no-new-commits`
(`relay-supervisor.sh:1249-1256`). That change came from a live run that was
rejected three times for `no commits were made (start=8 now=8)` while its
acceptance command passed the entire time. If you see this symptom *and*
you have an acceptance command, you are on a build from before that fix.

On the no-acceptance path, the normalisation is deliberately asymmetric,
and it is what produces this symptom. If the `rev-list` reading the
*current* count fails or prints nothing — a git error inside `$PROJECT`, a
stale index lock, a detached or unborn `HEAD` — it becomes `0`, which is
`-le` any real `commits_at_start`, so `COMPLETE.md` is rejected with `no
commits were made` even though the commits are in `git log`. The journal
line carries both numbers (`start=… now=…`), which tells you immediately
whether this is what happened.

Failing that way round is the intended trade: a wrongly rejected
`COMPLETE.md` costs one more session, while a wrongly accepted one ends
the run on work that was never done. Relay used to fail the other way —
an empty `commits_at_start` skipped the check entirely, so a run on a
repository with no commits yet could seal `COMPLETE.md` having committed
nothing at all.

What to run: in `$PROJECT`, run `git rev-list --count HEAD` yourself and
check it both succeeds and prints a number, then compare it against
`state.json`'s `commits_at_start`. If the command works by hand, look for
what made it fail under the supervisor — most often a stale
`.git/index.lock` left by another tool. Do not hand-edit
`relay-supervisor.sh` to work around it.

## Relay gave up with EX_FASTFAIL

What you see: exit 26, `state.json` status `blocked` reason `fastfail`
(`docs/exit-codes.md`'s EX_FASTFAIL entry).

What it means: `fastfail_limit` consecutive sessions (default 3) both
produced nothing and ended in under `min_session_secs` (default 45s,
`relay-supervisor.sh:147`). Both conditions are required — a session that
committed or wrote a valid handoff clears the streak however brief it was
(`relay-supervisor.sh:1735-1736`). So this is a genuine crash loop: sessions
are dying before they can do anything, not working quickly.

What to check: read `$STATE/sessions/` for the sessions that tripped it
(`journal.log`'s `fastfail.streak` lines name their durations). The usual
causes are an auth failure, a rejected `--session-id`, or a settings
payload the CLI refuses — all of which produce a session that starts and
stops with nothing in between. The session log's `result` envelope names
the reason; `session.reason` in the journal carries the short form.

Historical note, in case you meet an older report of this: until the
counters were separated, a session that committed real work *faster* than
`min_session_secs` also counted toward the streak, so three quick correct
steps could trip the breaker on a healthy run. If you see that symptom,
you are running a build from before that fix. `c141` covers it.

## I have two supervisors running against the same project

What you see: two `relay-supervisor.sh` processes alive for the same
project, each launching its own `claude -p` sessions against the same
tree.

What it means: the single-instance lock (`relay-supervisor.sh:425-430`,
`relay_lock` in `lib/relay-lib.sh:212-251`) decides whether a lock
directory is stale inside `_relay_lock_try_break()`
(`lib/relay-lib.sh:255-342`). On the same host it asks whether the owner
pid is alive with `ps`; if `ps` itself cannot run — blocked by a sandbox,
or absent — liveness is *unknowable*, and relay falls back to breaking the
lock only on age, exactly as it does for a lock owned by another host
(`lib/relay-lib.sh:305-320`).

That fallback exists because `ps -p <pid>` fails identically when the
process is gone and when `ps` cannot run at all. Relay used to read both as
"the owner is dead," which broke live locks: inside relay's own sandbox
`ps` exits 127, so *every* liveness check failed. A supervisor could then
delete a running supervisor's lock and start beside it. The tell was
`bash test/run.sh` failing `c140_lock_contention` and
`test/lib/test-relay-lib.sh` failing `lock_second_fails`, but only when the
suite ran from inside a session.

What to check: from the same environment relay runs in, run `ps -p $$`.
Exit 127 instead of your own pid means liveness cannot be established
there, so relay is using the age rule: `journal.log` carries a
`lock.ps-unusable` line each time, and a lock is then only broken once it
is older than four times `RELAY_LOCK_STALE_SECS` (3600s by default,
`lib/relay-lib.sh:37`). A crashed supervisor's lock therefore clears in an
hour rather than instantly. If you need it gone sooner, remove the lock
directory yourself after confirming no supervisor is running:
`pgrep -f relay-supervisor.sh` first, then `rm -rf "$STATE/locks/run.d"`.

If you genuinely see two supervisors on one project and `ps` works fine,
that is not this: check whether the two are pointed at the same state
directory at all (`/relay-status` prints it), because the lock is per state
directory, not per repository path.

## Sessions keep getting tool calls denied

Since 1.1.0 the journal says so: `session.denials n=N count=X tools=...`
(parsed from the envelope's `permission_denials`, which carries tool names but
no rule attribution), with running totals in `state.json`'s `denials_total` /
`last_denial_tools` and a one-per-run notification at ≥3 denials in one
session. Three causes, in likelihood order: a user-scope PreToolUse hook
(doctor warns about these — they run inside relay sessions and a text-matching
guard can veto commands that merely CONTAIN a dangerous-looking string); a
tool relay's allow list has never heard of, which in full-trust mode you fix
with `allow_tools_extra` in `config.json`; or the deny list doing its job.
The prompt already tells sessions a refusal is policy — route around it, never
retry it — so denials cost turns, not runs.

## A review session appeared off-cadence

Forced reviews are a 1.1.0 mechanism, journaled with their trigger:
`drift.suspected` (the handoff's `plan_step` went BACKWARD in PLAN-INDEX
order — the review's first duty is to verify the position against git),
`index.stale` (the plan file's hash changed while a PLAN-INDEX exists — the
review regenerates the index), or `gate.fail` (a phase gate failed once — the
review gets the gate output injected as data; a second failure of the same
gate halts the run BLOCKED instead). A forced review records itself as the
last review, so the regular cadence does not double up right after one.

## BLOCKED: RUN.md protected region changed

The supervisor hashes everything in `RUN.md` above the first
`## Course corrections` heading at launch and halts the run if a session
changes it (`runmd.tampered` in the journal, `reason: run-md-tampered`) — the
mission, guardrails and settled decisions are not a session's to edit, and
this may be prompt injection, so read the session log named in BLOCKED.md
before trusting the run. If YOU edited RUN.md mid-run, that is the guard
working as documented: the supported path is `/relay-stop`, edit,
`/relay-resume` — a fresh supervisor baselines whatever RUN.md says at
launch. A RUN.md with no `## Course corrections` marker is protected WHOLE
(`runmd.no-marker` warns at start), which turns even a review session's
legitimate append into a halt — add the marker.
