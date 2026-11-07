---
name: feedback-never-sleep-holding-a-lock
description: "A limiter that sleeps under flock makes every other process wait behind it at zero CPU."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Never sleep while holding a shared lock

If a shared limiter takes a lock and then sleeps until a slot frees, every other process queues behind the sleeper. Under the lock either reserve a free slot atomically and proceed after unlocking, or, if none is free, unlock, wait and retry, all within an overall deadline. A suspiciously round wait time hints at a code constant rather than a slow service.

**Why:** Parallel jobs stall for many minutes with no error and no load.

**How to apply:** Lock and check capacity; if free, reserve, unlock and work; if not, unlock, sleep and retry; give up at an overall deadline.
