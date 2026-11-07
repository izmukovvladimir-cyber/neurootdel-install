---
name: feedback-restart-agents-safely
description: "Drain an agent before restarting it; many cold starts at once can exhaust memory."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Restart agents in waves and check what is inside

Before restarting any agent's service, pause its intake or let it drain, wait until active work finishes or checkpoints, and check what else runs in its cgroup. Restart many agents in small waves sized to the server's memory, then restore intake. Afterwards reconcile incoming messages against replies and completed actions, and answer only what is truly unhandled without repeating actions already done.

**Why:** A restart kills live conversations, and a simultaneous cold start of the whole fleet swaps the server.

**How to apply:** Pause intake and wait for the open turn to finish; systemd-cgls the unit; restart in waves sized to capacity and restore intake; reconcile unanswered messages against effects before replying.
