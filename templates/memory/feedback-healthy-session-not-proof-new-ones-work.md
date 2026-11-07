---
name: feedback-healthy-session-not-proof-new-ones-work
description: "A long-running session can keep working while new ones fail, for example on a broken credential."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Test new sessions, not only a running one

A long-running Claude Code process can keep working on credentials it already holds while newly started sessions fail, for example on a broken or expired credential file. Health-check by starting a real new session, not by looking at a running one.

**Why:** Everything looks fine until the next restart, when every agent fails at once.

**How to apply:** Spawn a real new session end to end as the health check; watch the credential file's presence and expiry; investigate failures before restarting the running ones.
