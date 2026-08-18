---
description: Resume a relay run that stopped or was blocked.
argument-hint: ""
---

Invoke the `relay` skill (Skill tool) and follow its `resume` section.

If BLOCKED.md exists, confirm the blocker is genuinely resolved and record the
resolution in RUN.md before relaunching. Never re-run the interview.

Before running any relay script with Bash, resolve the plugin root exactly as
the skill's "Resolve the plugin root" section specifies, and invoke scripts only
through $RELAY_ROOT — never through a bare CLAUDE_PLUGIN_ROOT expansion. If the
resolver prints "relay: FATAL", stop and tell the user to reinstall the plugin.
