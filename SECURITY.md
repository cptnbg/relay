# Security policy

## Reporting

Report vulnerabilities privately via GitHub Security Advisories on this
repository: Security tab → "Report a vulnerability". Private vulnerability
reporting is enabled, so that form is a working private channel and is the
preferred one. There is deliberately **no private-report email**:
`plugins/relay/.claude-plugin/plugin.json` carries no address, and this file
will not point at one that does not exist. Please do not open a public issue
for anything exploitable.

## Scope

In scope:

- Any way relay causes a credential to be read, logged, committed, or
  transmitted that the documented model does not already admit.
- Any way a **repository** — as opposed to the user — causes relay's supervisor
  to execute a command, or relaxes the sandbox or deny-list.
- Any way relay's context guard affects a session relay did not start.
- Any way the handoff channel lets one session grant a later session
  permissions RUN.md does not grant.

Out of scope, because they are documented properties rather than defects:

- The agent running your project's build and test commands, and those executing
  arbitrary repository code. The sandbox confines this; the deny-list does not
  see inside it. See "Read this before you run it" in the README.
- Deny-list bypasses **when the sandbox is enabled and enforced**. The deny-list
  is blast-radius reduction, not a boundary, and is documented as such.
- Anything reachable by a session when the operator has chosen
  `sandbox_mode: "disabled"` (full trust). That mode removes the boundary by
  design and by consent: reads, network, SSH and the deny-list's remaining
  entries are all bypassable from a shell, and relay's own state files are then
  guarded only by permission rules, which Bash does not honour. Reports that a
  full-trust session could reach something are describing the documented
  feature. What IS in scope there: relay selecting that mode without the
  operator configuring it, failing to prove the payload was accepted, or failing
  to surface the mode in `/relay-status` and `/relay-doctor`.
- Claude Code writing its own unredacted transcript to `~/.claude/projects/`.
  Relay does not control that file.
- Anything requiring an attacker who already has local code execution as the
  user.

## Design commitments

These are load-bearing. A change that relaxes one is a MAJOR version bump and
invalidates recorded consent. The consent half of that sentence is a
mechanism, not an assertion: consent is recorded as the git blob hash of the
exact notice text the user accepted (`consent.notice_hash`), and
`/relay-doctor` recomputes that hash from the installed SKILL.md and refuses
to run when consent is absent or the notice no longer matches
(`plugins/relay/scripts/relay-doctor.sh:338-371`). Changing the terms
mechanically forces re-consent. The commitments:

1. Relay never passes `--dangerously-skip-permissions`.
2. Relay never pushes to a git remote.
3. Relay always passes `--setting-sources user` and `--strict-mcp-config`, so a
   repository's own `.claude/settings.json` and `.mcp.json` never take effect.
4. Relay refuses to run unless it can prove, against observable behaviour, that
   the settings payload it sent was actually accepted — because `claude -p`
   silently ignores a payload that fails validation. In the default `enforced`
   mode that proof is the sandbox itself confining a read and an egress attempt.
   The sandbox is switched off only by an explicit per-project opt-in — the
   `sandbox_mode` key in that project's `config.json`, set to `"disabled"`.
   `/relay-init` is where the operator is asked for it and is the only path that
   records consent; the key can also be edited directly, which is the same
   deliberate act by another door and is documented in the README. Either way it
   is covered by the consent notice, surfaced by `/relay-status` and
   `/relay-doctor`, and still
   probed before every run — there the proof is that relay's own inline hook
   fired and that reads really are unconfined, so a dropped payload and a
   working full-trust run cannot be mistaken for one another. Relay never
   infers the mode, and never falls back to it.

   Two environment variables defeat this on purpose, and both are the test
   suite's, not a user's: `RELAY_SKIP_PROBE=1` skips the acceptance probe and
   `RELAY_SKIP_SELFTEST=1` skips the proof that the injection and
   guardrail-drift filters fire under this machine's `grep`. Anyone who can set
   them can already run any command as you, so they are not a privilege
   boundary — but a commitment stated without them would be false, and this
   file does not do that. Neither is read from config, neither is settable by a
   repository, and a run started with either set is a run whose protections
   were asserted rather than demonstrated.
5. Relay registers no global hooks; its context guard exists only inside
   sessions relay itself started.
6. A repository-tracked config can never make relay execute a command.
