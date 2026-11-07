---
name: feedback-diagnose-403-404-with-controls
description: "A 404 alone cannot tell route, resource and access problems apart; read the full error before blaming."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Diagnose API 403 and 404 with controls, not guesses

A 404 alone cannot tell a moved route, a missing resource and a hidden access denial apart, so test with controls before blaming the key. A 403 can mean many things (a Cloudflare browser-signature block such as error 1010, an IP block, a plan refusal), and rate limits usually come as 429, so read the status, headers and full body. Run controls only with documented routes and safe read-only requests, never by retrying real writes.

**Why:** Wrong conclusions ('key revoked', 'IP banned') lead to pointless rotations and escalations.

**How to apply:** Repeat one safe read with a known-good and a deliberately wrong key; check the documented route; set an identifying User-Agent if the client sends none; read the full error body and headers.
