---
name: feedback-write-apis-full-object-read-back
description: "Some update endpoints replace the whole object, and a failed write may still have happened."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Follow the update schema; retry only idempotent writes

Check each endpoint's update semantics: a replace endpoint overwrites the whole object, so omitting an array wipes it, while a patch endpoint takes only changed fields. Use version or ETag preconditions where supported, and verify by reading back. Retry a write automatically only if the endpoint documents it as idempotent, or documents idempotency-key support and you resend the same key and payload within its dedup window, since a write that failed mid-response may already have taken effect.

**Why:** Partial updates silently delete data, and retried writes duplicate actions.

**How to apply:** Read the docs for replace versus patch; send what the schema expects, with a precondition if available; read back and compare; on a failed non-idempotent write check state before retrying.
