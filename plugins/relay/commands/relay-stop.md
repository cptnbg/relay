---
description: Ask the running relay build to stop cleanly at the next safe point.
argument-hint: ""
---

Invoke the `relay` skill (Skill tool) and follow its `stop` section.

Before running any relay script with Bash, resolve the plugin root exactly as
the skill's "Resolve the plugin root" section specifies, and invoke scripts only
through $RELAY_ROOT — never through a bare CLAUDE_PLUGIN_ROOT expansion. If the
resolver prints "relay: FATAL", stop and tell the user to reinstall the plugin.
