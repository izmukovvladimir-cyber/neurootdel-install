---
name: feedback-one-predicate-one-kill-switch
description: "Two functions deciding the same validity question drift apart; a kill switch must stop every part."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Judge one condition with one shared predicate

When two functions decide the same validity question, make them call one shared predicate. A kill switch must be honoured by every component of the mechanism, not only the one that defined it.

**Why:** Duplicate logic drifts, and a stop that only one part honours does not stop the system.

**How to apply:** Extract the predicate; call it everywhere; test the kill switch against every component.
