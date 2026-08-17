# Portability

The dependency policy, and why each piece of it exists. Read this next to
`test/lint/no-deps.sh` and `test/lint/no-bash4.sh` — they are the policy in
enforceable form; this document is the reasoning behind their allowlist and
patterns.

## Hard dependencies

Stated in `plugins/relay/scripts/lib/relay-lib.sh:4-9`, the library header
every other script sources:

- **bash 3.2** — the version gate at `relay-lib.sh:22-25` refuses to run
  under `BASH_VERSINFO[0] < 3`; the comment above it names the actual floor,
  bash 3.2.57 (macOS system bash), not bash 3 generically.
  `relay-doctor.sh:85-89` checks the same thing at preflight and calls it out
  by version string in its failure message.
- **git** — checked by `relay-doctor.sh:90` (`check_tool git 2.20
  'git --version'`), so 2.20 is the minimum doctor enforces. `relay-lib.sh:8`
  lists `git` among the allowed externals; `relay_hash()`
  (`relay-lib.sh:408-456`) uses `git hash-object` as its first-choice content
  hash.
- **jq** — checked by `relay-doctor.sh:91` (`check_tool jq 1.6 'jq --version'`).
  Used throughout for config (`cfg()`, `relay-supervisor.sh:54-57`) and for
  the acceptance-command argv validation (`relay-supervisor.sh:76-85`).
- **claude** (Claude Code CLI) — checked by `relay-doctor.sh:95-106`, which
  gives the version probe its own 10-second timeout rather than a minimum
  version string; a broken install or a hung auth refresh must not stall an
  unattended run at the starting line. `README.md:68-69` states a minimum of
  2.1+; that number is not re-asserted anywhere in the code doctor runs, so
  treat the README figure as the stated intent and the timeout-guarded probe
  as what is actually enforced.
- **POSIX utilities already on the box** — `relay-lib.sh:7-9` lists the
  allowed externals beyond the four above: bash builtins, POSIX `awk sed
  grep tail head wc tr od mkdir mv rm rmdir date sleep kill ps mktemp printf
  cut df uname cksum`, plus explicit fallback rungs for `shasum`/`sha256sum`.
  None of these carry a minimum version; the code works around the versions
  actually shipped by macOS and mainstream Linux distributions rather than
  requiring a floor (see the exclusion list below for what that workaround
  looks like in practice).

## Deliberately excluded

`test/lint/no-deps.sh` fails a shipped script that calls any of these
(scanning `plugins/**/*.sh`, ignoring comment-only lines — `no-deps.sh:12-19`).
The excluded set and the specific fact behind each:

- **node, python3/python** — not a portability fact so much as a promise:
  `no-deps.sh:31-32` bans them outright ("relay must not require python" /
  "node"), and `README.md:69` states this as the deliberate policy, not an
  oversight.
- **perl** — not in `no-deps.sh`'s scan list at all, and not named in
  `relay-lib.sh`'s allowed-externals comment either. It is simply never
  reached for; there is no dedicated rule because nothing in the codebase
  tempts a contributor to add it the way `timeout`/`stat`/`sed -i` do.
- **`flock`** — does not exist on macOS (`no-deps.sh:25`). Relay's own
  substitute is `relay_lock()` (`relay-lib.sh:212-251`), an atomic
  `mkdir`-based lock: `mkdir` is atomic-create-or-fail on every POSIX
  filesystem relay targets, where `flock` would need a binary that is
  simply absent on the reference platform.
- **`timeout`** — absent on stock macOS (`no-deps.sh:23`, which also bans
  the Homebrew-coreutils `gtimeout` workaround at `no-deps.sh:24`, since
  requiring Homebrew is itself a dependency relay does not want). The
  substitute is `relay_timeout()` (`relay-lib.sh:111-205`): it backgrounds
  the command in its own process group via `set -m`, runs a sibling timer
  subprocess that escalates TERM then, after `RELAY_KILL_GRACE` (default
  10s), KILL, and reaps with `wait` rather than a `kill -0` poll loop
  because `wait` "cannot be fooled by a zombie that hasn't been reaped yet"
  (`relay-lib.sh:178-180`).
- **`setsid`** — does not exist on macOS (`no-deps.sh:26`). Relay uses
  `set -m` (job control) instead to put a child in its own process group,
  so the whole tree can be signalled via `kill -TERM "-$pgid"`
  (`relay-lib.sh:134-136`).
- **`shasum`** — not itself excluded (it is a real rung in `relay_hash()`,
  `relay-lib.sh:431-441`); what is excluded is treating `sha256sum` as
  available, since it is "not on macOS; use relay_hash" (`no-deps.sh:30`).
  `relay_hash()`'s actual ladder is git hash-object, then `shasum -a 256`,
  then a `cksum`-based weak fallback prefixed `cksum:` so a caller can tell
  it apart from a real hash (`relay-lib.sh:403-456`).
- **`bc`** — not scanned by `no-deps.sh` and not named in the allowed-
  externals comment. All arithmetic in these scripts uses POSIX shell
  `$(( ))`, which is sufficient for the integer math relay needs (percentages,
  epoch differences, counters) and sidesteps a floating-point dependency
  entirely.
- **`realpath`** — not on stock macOS (`no-deps.sh:28`). `relay-doctor.sh`
  resolves at most one level of symlink by hand instead
  (`relay-doctor.sh:64-69`: `readlink` plus a `case` on whether the target
  is absolute).
- **`readlink -f`** — same absence on stock macOS, banned separately
  (`no-deps.sh:29`) because plain `readlink` (no `-f`) is fine and is what
  `relay-doctor.sh:67` actually calls.
- **`stat`** — its flags differ between macOS (BSD) and Linux (GNU)
  (`no-deps.sh:27`). `relay-doctor.sh:248-250` reads a credential file's
  permission bits with `ls -l | cut -c1-10` instead, calling `ls` "portable
  enough for a permission check." `relay_prune_sessions()`'s header makes
  the same point about `find -mtime` versus `stat` (`relay-lib.sh:518-519`).
- **`grep -P`** — unavailable on macOS's BSD grep (`no-deps.sh:33`). Every
  pattern in these scripts is plain ERE (`grep -E`), which macOS grep does
  support.
- **`sed -i`** — the in-place flag differs between BSD and GNU sed, in a way
  that is not just spelling: BSD requires an argument to `-i` (even if
  empty) where GNU treats a bare `-i` as in-place-no-backup
  (`no-deps.sh:34`). Relay never edits a file in place with `sed`; writes go
  through `relay_atomic_write()` (`relay-lib.sh:463-503`) instead — a
  same-directory temp file plus `mv`, which is also how atomic replacement
  is achieved without relying on any editor's in-place semantics.
- **`date -d`** — GNU-only; BSD `date` parses input dates with `-f`
  instead, a different flag with different format syntax (`no-deps.sh:35`,
  and `no-deps.sh:36` separately bans GNU-only `date +%s%N` nanosecond
  precision). Relay only ever needs `date +%s` (epoch seconds, e.g.
  `relay-lib.sh:46,228,284`), which both `date` implementations support
  identically, so the GNU-only forms are simply never needed rather than
  worked around.

## bash 3.2 constraints

macOS ships bash 3.2.57 and relay treats that as the floor
(`no-bash4.sh:2-4`). Concretely, that rules out:

- **Associative arrays** (`declare -A` / `local -A`) — bash 4+
  (`no-bash4.sh:27-28`).
- **`mapfile` / `readarray`** — bash 4+ (`no-bash4.sh:29-30`).
- **`${v^^}` / `${v,,}`** (case-folding expansion) — bash 4+
  (`no-bash4.sh:31-32`). Case folding that is needed (e.g. `relay_uuid()`
  lower-casing a UUID at `relay-lib.sh:352,363`) goes through `tr
  '[:upper:]' '[:lower:]'` instead, which is POSIX `tr`, not a bash
  built-in.
- Also banned for the same bash-4+ reason: `wait -n` (4.3+), `coproc`,
  `&>>`, `;;&` case fallthrough, and `shopt -s globstar`
  (`no-bash4.sh:33-37`).

**The `set -u` + empty-array trap.** Ordinary indexed bash arrays
(`arr=(...)`, `"${arr[@]}"`) are not banned by name in `no-bash4.sh` — they
are bash-2-era syntax, not a bash-4-ism — but this codebase does not use
them anywhere in `plugins/`, and the one place an argv list has to be built
dynamically shows why: `verify_complete()`'s acceptance-command runner
(`relay-supervisor.sh:501-510`) builds its argument list with `set --`
against the positional parameters, not a bash array:

```
set --
while IFS= read -r _line; do
  _el=$(printf '%s' "$_line" | jq -r '. + "x"') || exit 1
  set -- "$@" "${_el%x}"
done
[ "$#" -gt 0 ] || exit 1
```

Every script in the codebase runs under `set -u` (`relay-supervisor.sh:21`,
`relay-lib.sh:14`, `relay-git.sh:20`, `relay-doctor.sh:12`,
`relay-settings.sh:19`). Under bash 3.2, expanding `"${arr[@]}"` on an array
that is empty (as opposed to unset) still trips `set -u`'s "unbound
variable" — that quirk was not fixed until bash 4.4. Positional parameters
do not have this failure mode: `"$@"` on zero arguments is exempt from
`set -u` in every bash version relay targets. Building the list with `set
--`/`"$@"` instead of a real array is a direct, load-bearing workaround for
that gap, which is also why the code adds an explicit `[ "$#" -gt 0 ] ||
exit 1` guard immediately after the accumulation loop — the same place a
`declare -a`-based version would have silently done the wrong thing instead
of erroring.

## Why `set -e` and `trap ... ERR` are banned here

This is not general shell-style advice; every script header in this
codebase states a project-specific reason, and one of them is backed by an
observed incident rather than a hypothetical:

- `relay-lib.sh:11-13`: "every function returns an explicit status and is
  called from if/&&/while, where `set -e` is inert inside functions in bash
  3.2 anyway." That second clause matters: even a contributor who wanted
  `set -e`'s safety net cannot reliably get it inside a bash-3.2 function
  body, so relying on it would be worse than useless — code that looks
  guarded and is not.
- `relay-supervisor.sh:17-19`: "this loop IS a chain of predicates whose
  non-zero results are answers, and a single missed `|| true` would
  silently kill an overnight run." The supervisor's entire control flow —
  `sealed()`, `handoff_valid()`, `usage_limited()`, and every post-exit
  check in the predicate chain — depends on a non-zero return meaning
  "no", not "abort the whole process."
- `relay-ctx.sh:22-23,29-34` gives the concrete case: "deliberately NO
  `trap ... ERR` and NO `set -e`. This script is predicate-heavy: `[ "$PCT"
  -ge "$CRIT" ]` returning 1 is an ANSWER, not an error. An ERR trap turns
  every such answer into a silent exit — which during development made the
  guard emit nothing at 62%, 78% and 92% while looking perfectly healthy."
  That is the reasoning made concrete: an `ERR` trap was tried, it broke
  the context guard at exactly the three threshold percentages that matter,
  and it failed silently — the hook still exited 0 either way, since
  `relay-ctx.sh`'s own contract requires that (`relay-ctx.sh:6-9`), so the
  bug was invisible from the exit code and only showed up as the guard's
  messages never appearing.
- `relay-git.sh:17-18`: "predicates here return non-zero as an answer,"
  the same reasoning applied to `relay_git_*` functions.

The common thread: this codebase's control flow is built from shell
predicates returning 0/1 as data, not as pass/fail on a linear script. An
automatic-abort mechanism triggered by any non-zero return is incompatible
with that shape by construction, not by preference.

## Enforcement: what a contributor actually sees

Both linters live under `test/lint/` and scan shell source with `grep -nE`,
skipping lines that are pure comments (`no-bash4.sh:20-24`,
`no-deps.sh:16-20`) so a header explaining *why* a construct is avoided does
not itself trip the rule that avoids it.

**`test/lint/no-bash4.sh`** scans `plugins/` and `test/` (excluding its own
`test/lint/` directory, `no-bash4.sh:14-18`) for the bash-4-only constructs
listed above. On a hit, the failure format, from `scan()`
(`no-bash4.sh:20-25`), is:

```
BASH4: <explanation>
<file>:<line>:<matched text>
```

repeated once per construct that matched anywhere, with a trailing blank
line after each block (`printf 'BASH4: %s\n%s\n\n' "$2" "$_hits"`). A clean
run instead prints `no-bash4: clean` (`no-bash4.sh:39`). Exit status is `0`
on a clean scan, `1` if anything matched (`no-bash4.sh:12,24,40`).

**`test/lint/no-deps.sh`** scans only `plugins/` (shipped code; tests and
docs are explicitly allowed to name a forbidden tool in order to explain why
it is avoided — `no-deps.sh:5-6`) for the excluded commands above. Its
failure format, from the same `scan()` pattern
(`no-deps.sh:16-21`), is:

```
FORBIDDEN DEP: <explanation>
<file>:<line>:<matched text>
```

also one block per construct, blank-line separated, and also exits `1` on
any match, `0` and `no-deps: clean` otherwise (`no-deps.sh:38-39`).

Both linters are static `grep`-based scans over shipped `.sh` files, not
runtime checks — they catch a forbidden construct or command the moment it
is committed, before it ever reaches someone else's machine.

## The lock's undeclared exception

Everything above is enforced. This section is not: it is a known gap in the
policy itself, recorded here rather than fixed, because fixing it would be
a behavioural change to a script under `plugins/relay/scripts/`, which is
out of scope for documentation work.

`relay_lock()`'s staleness check, `_relay_lock_try_break()`
(`relay-lib.sh:255-316`), decides whether a same-host lock's owner process
is still alive by shelling out to `ps`:

```
if ! ps -p "$_rlb_pid" >/dev/null 2>&1; then
  _rlb_stale=1
fi
```

(`relay-lib.sh:279-280`). `ps` is not in the hard-dependency list above, and
`test/lint/no-deps.sh` does not scan for it — its pattern list
(`no-deps.sh:23-36`) has no `ps` entry, so a call to `ps` is not a lint
failure the way a call to `timeout` or `stat -f` would be. `relay-lib.sh:8`
does list `ps` among the "allowed externals" in its header comment, which
is accurate as far as it goes, but that comment is prose, not something
`no-deps.sh` checks against; it records intent without enforcing it.

The consequence is more than a missing lint rule. The check above treats
*any* non-zero return from `ps -p "$pid"` as proof the owner is dead and
proceeds to break the lock (`_rlb_stale=1`, followed by the race-safe break
at `relay-lib.sh:305-313`). A `ps` that cannot run at all — for instance
because it is unavailable inside a sandbox, where invoking it returns
`rc=127` for "command not found" — produces exactly the same non-zero
status as a `ps` that ran fine and correctly reported the pid is gone. The
code cannot tell those two cases apart, and it resolves the ambiguity
toward breaking the lock. This means the single-instance lock, which exists
specifically to guarantee mutual exclusion between two supervisors on the
same project, fails *open* rather than closed in exactly the environment
where fail-closed would matter most: a live owner process whose liveness
cannot even be checked. This was reproduced directly, and it is the reason
two of the repository's own tests currently fail.

This is a real, currently-undeclared dependency and a real correctness gap,
recorded here for the maintainer. It is not something this document fixes —
that would mean editing `relay-lib.sh`, which is explicitly out of scope
for a documentation-only pass — and it is not cause for alarm about
anything else in this file: it is the one place the stated dependency
policy and the actual code disagree, and it is now named as exactly that.
