---
name: feedback-read-secrets-by-exact-name
description: "Heuristic parsing of a secrets file grabs the wrong value and fakes an 'expired token'."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Read secrets by their exact key name

Read a secrets file by the exact key name, never by heuristics like 'the first long value'. Describe keys by their current format from the provider's docs, not by how they looked years ago.

**Why:** The wrong field produces a false 'token expired' and a pointless rotation or alarm.

**How to apply:** Parse by name; validate the expected prefix from current docs; on mismatch report which field you read.
