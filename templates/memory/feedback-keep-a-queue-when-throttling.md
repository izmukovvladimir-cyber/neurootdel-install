---
name: feedback-keep-a-queue-when-throttling
description: "Equal polling and delivery windows with a batch cap lose everything beyond the cap."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Keep your own queue when throttling delivery

If a source is polled for the last N minutes and delivery is throttled to once per N minutes with a batch cap, whatever exceeds the cap is lost for good. Keep an on-disk queue with a stable id per item, written atomically, and clear an item only on confirmed delivery; log sends so an uncertain one is reconciled, not blindly resent.

**Why:** Busy periods silently drop items, exactly when they matter most.

**How to apply:** Write polled items with stable ids to a queue file atomically; deliver from the queue and log each send; remove after confirmation; reconcile uncertain sends before retrying.
