---
name: feedback-rollback-only-after-your-write
description: "On a refusal before writing there is nothing to roll back, and the backup is already stale."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Roll back only after your own write, not on any error

Track the write state as not attempted, confirmed written or outcome unknown; before any write there is nothing to roll back, and restoring a backup would undo others' newer changes. Roll back only a confirmed write, and do it as a conditional write (version or ETag check), a transaction or under a lock, so it fails if someone changed the object since. Reconcile an unknown outcome by reading the state before compensating.

**Why:** A blind rollback on any error overwrites good data with an old backup.

**How to apply:** Record not attempted, written or unknown; restore a bad confirmed write with a conditional write or transaction; on unknown, read the state first; log the reason either way.
