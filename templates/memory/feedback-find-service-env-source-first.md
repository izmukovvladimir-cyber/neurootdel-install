---
name: feedback-find-service-env-source-first
description: "Find where a systemd service really gets a variable before changing it."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Find a service's real env source before editing it

Before changing an environment variable of a systemd service, find where its effective value comes from: inline Environment lines, one or several EnvironmentFile entries and drop-ins. Precedence is not simply textual order, so confirm the effective value instead of reasoning about it. Do not guess from the project's main-looking .env.

**Why:** An edit to the wrong file changes nothing, and the service keeps the old value after a restart.

**How to apply:** systemctl cat the unit including drop-ins; list every source of the variable; edit the one that sets the effective value, running daemon-reload if you changed the unit or a drop-in; restart and confirm the startup environment in /proc/PID/environ of the main PID (systemctl show lists only unit properties); if the app changes the variable after start, check it through the app's own diagnostics.
