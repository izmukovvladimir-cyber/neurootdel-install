---
name: feedback-event-proves-only-what-it-saw
description: "An empty getUpdates reflects only the current offset and filters; a used invite link proves only its use."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Conclude only what an event actually shows

getUpdates may return fewer items than the limit, so keep calling with offset set to the last update_id plus one and persist that offset; an empty answer means no updates were returned for the current offset and allowed_updates, not that no relevant event happened. An entry via a one-time link proves the link was used, not that its intended person joined.

**Why:** Over-reading events misses updates and credits the wrong person.

**How to apply:** Advance and store offset after each processed batch; check allowed_updates covers the events you need; match members by user identity, not by link.
