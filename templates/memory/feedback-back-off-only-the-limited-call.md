---
name: feedback-back-off-only-the-limited-call
description: "Retries over retries multiply attempts; pause the limited scope until Retry-After passes."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Wait out Retry-After; do not stack retries

A retry wrapper over a client that already retries multiplies attempts. On a rate-limit answer, pause the calls in the limited scope (per key, route or IP, as the service documents) until Retry-After has passed, with one timer and an absolute deadline. If the limit is per IP, other jobs sharing that egress IP are affected too.

**Why:** Hammering a limited host can prolong the block and burn the quota you wait for.

**How to apply:** Read Retry-After (seconds or an HTTP date) and note the absolute end time; pause only the limited scope until then; probe recovery with one real call; if still limited, back off exponentially with a cap.
