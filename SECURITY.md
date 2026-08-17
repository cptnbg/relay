# Security policy

## Reporting

Report vulnerabilities privately via GitHub Security Advisories on this
repository, or by email to the address in `.claude-plugin/plugin.json`. Please
do not open a public issue for anything exploitable.

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
- Claude Code writing its own unredacted transcript to `~/.claude/projects/`.
  Relay does not control that file.
- Anything requiring an attacker who already has local code execution as the
  user.

## Design commitments

These are load-bearing. A change that relaxes one is a MAJOR version bump and
invalidates recorded consent:

1. Relay never passes `--dangerously-skip-permissions`.
2. Relay never pushes to a git remote.
3. Relay always passes `--setting-sources user` and `--strict-mcp-config`, so a
   repository's own `.claude/settings.json` and `.mcp.json` never take effect.
4. Relay refuses to run if the sandbox cannot be proven enforced.
5. Relay registers no global hooks; its context guard exists only inside
   sessions relay itself started.
6. A repository-tracked config can never make relay execute a command.
