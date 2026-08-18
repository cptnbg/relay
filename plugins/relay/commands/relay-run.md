---
description: Launch the detached relay supervisor for this project.
argument-hint: ""
---

Invoke the `relay` skill (Skill tool) and follow its `run` section.

Launch the supervisor detached and then END YOUR TURN. Do not stay alive polling it.

Before running any relay script with Bash, resolve the plugin root exactly as
the skill's "Resolve the plugin root" section specifies, and invoke scripts only
through $RELAY_ROOT — never through a bare CLAUDE_PLUGIN_ROOT expansion. If the
resolver prints "relay: FATAL", stop and tell the user to reinstall the plugin.
