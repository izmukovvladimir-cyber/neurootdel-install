---
name: feedback-supergroup-upgrade-new-chat-id
description: "A group upgrade changes its id; writes to the old id fail with the new id in the error."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Take the new id when a group becomes a supergroup

When a Telegram group becomes a supergroup, its id changes and cannot be derived from the old one. Reads on the old id may still work; a write returns 400 with the new id in the error parameters.

**Why:** Bots silently stop posting to the group while reads look fine.

**How to apply:** On 'upgraded to a supergroup', read the migrate-to id from the error; update config; resend.
