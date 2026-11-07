---
name: feedback-shown-secret-is-burned
description: "Captured command output reaches the transcript and the model provider; a key seen there must be revoked."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Treat any secret that reached output as burned

Output captured from a command (echo, API JSON, error text in logs) usually lands in the transcript and at the model provider. The moment a key appears there, revoke it, issue a replacement, and verify the old one is rejected and the new one works. Code shared publicly carries no private addresses, ids or keys.

**Why:** A leaked key keeps working for whoever saw it until it is revoked.

**How to apply:** Mask secrets in output; on a leak revoke the old key explicitly and switch to a new one; confirm with a safe call that the old fails and the new works; handle logs by the redaction and retention policy and scan code before publishing.
