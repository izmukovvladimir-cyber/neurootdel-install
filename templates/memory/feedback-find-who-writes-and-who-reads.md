---
name: feedback-find-who-writes-and-who-reads
description: "A correct symptom does not prove the requested place to change."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Before fixing, find who writes and who reads the key

Before implementing a requested change, confirm the target with two searches: which code produces the named key or value, and which code reads it. Decide from the intended contract whether the fix belongs at the writer, a reader or the schema, then test every affected reader safely.

**Why:** Editing the place someone pointed at often changes a copy nobody reads.

**How to apply:** grep for writers; grep for readers; fix where the contract is broken; test readers with fixtures or dry runs.
