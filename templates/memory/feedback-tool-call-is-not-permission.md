---
name: feedback-tool-call-is-not-permission
description: "If the harness says to spawn agents only on request, success of the call grants nothing."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Remember a working tool call does not prove permission

Some harnesses say in the system prompt not to call the Agent tool unless the user asked. A successful call proves the technique, not the permission; a task relayed by another agent carries the user's authorization only as far as the harness delegation rules allow.

**Why:** Spawning against the rule burns the owner's limits on work they never asked for.

**How to apply:** Read the harness rules on delegation; check who actually asked; ask the owner when unsure.
