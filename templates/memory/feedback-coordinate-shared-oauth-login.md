---
name: feedback-coordinate-shared-oauth-login
description: "Tools on one OAuth login can collide on refresh or revoke; follow the provider's token rules."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Coordinate tools that share one OAuth login

Several tools sharing one OAuth login can interfere: depending on the provider, a refresh can rotate tokens others still hold, reuse detection can revoke the whole grant, and a new login can sign others out. Where processes share the same credential by design, give one of them ownership of refreshing and storing it, and follow the provider's documented behaviour. Independent clients keep their own grants instead of sharing tokens.

**Why:** A revoked grant stops every tool on that account until a human logs in again.

**How to apply:** Read the provider's token rules; for one shared credential let one process refresh and store it; keep separate grants for independent clients; warn other users before a fresh login and on a revoke stop and ask the owner.
