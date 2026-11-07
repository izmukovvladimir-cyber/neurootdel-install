---
name: feedback-silent-agent-check-the-turn
description: "A silent agent may have written prose without the reply tool, died on an API error, or hung on a call."
metadata:
  type: feedback
  origin: installer starter lesson
---

# When an agent is silent, check its turn first

A silent chat agent may still be alive: it wrote the answer as prose without calling the reply tool, its turn died on an API error, or one tool call hangs while messages queue. Delivery checks (service active, webhook 200) see none of these.

**Why:** Restarting delivery parts fixes nothing and loses queued messages.

**How to apply:** Read the transcript around the time; look for a missing reply call, API errors or a hung tool; check what the turn already did; send the missing reply or redo only the steps not done.
