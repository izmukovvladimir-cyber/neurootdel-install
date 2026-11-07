---
name: feedback-recipient-list-from-live-source
description: "Take rollout lists from the live source at that moment, filtered to who may receive it."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Build a recipient list from the live source, right then

Before any rollout to many recipients, take the list from the live source (directories, service list) right then, and intersect it with who is authorized and eligible to receive it (exclusions, opt-outs). Report the count with its source, and the skipped count with reasons.

**Why:** Lists from memory miss new members and include removed ones, so the rollout is silently partial.

**How to apply:** Query the live source; filter by authorization, exclusions and preferences; compare with the expected total; report count, source and skips to people allowed to see them.
