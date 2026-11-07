---
name: feedback-user-account-flood-and-spam
description: "FloodWait is cured by waiting; PeerFlood marks the account as spammy, so stop sending."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Treat PeerFlood as a spam verdict, not a pause

There is no safe daily number of cold messages from a Telegram user account; spam reports cause restrictions. FloodWait carries seconds and can be retried after waiting; PeerFlood is an anti-spam restriction, so stop sending rather than push on.

**Why:** Retrying through PeerFlood risks turning a restriction into a lost account.

**How to apply:** On PeerFlood store a hard stop; never promise a safe volume; resume only after the account's restriction status is clear.
