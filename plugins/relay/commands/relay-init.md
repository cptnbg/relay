---
description: Interview, consent, and configure an autonomous relay run for a plan.
argument-hint: "<plan-path>"
---

Invoke the `relay` skill (Skill tool) and follow its `init` section for the plan at: $ARGUMENTS

Do the full interview. Do not skip the consent gate, and do not start a run in this session.

Before running any relay script with Bash, resolve the plugin root exactly as
the skill's "Resolve the plugin root" section specifies, and invoke scripts only
through $RELAY_ROOT — never through a bare CLAUDE_PLUGIN_ROOT expansion. If the
resolver prints "relay: FATAL", stop and tell the user to reinstall the plugin.
