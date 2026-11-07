---
name: feedback-headless-session-hangs-on-prompt
description: "An interactive Claude Code session left unattended can wait on a permission prompt with little outward sign."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Watch for an unattended agent stuck on a prompt

An interactive Claude Code session left running unattended (in tmux or under a service) can stop at a permission prompt, resume screen or onboarding wizard and wait for input. The service may still look active while no work happens. For unattended jobs prefer the non-interactive mode with narrowly scoped permissions, a timeout and error monitoring.

**Why:** The agent can look alive while doing nothing for hours.

**How to apply:** Use non-interactive mode for jobs; pre-approve only the needed tools; set timeouts and alert on errors; check the pane or transcript progress, not only service status.
