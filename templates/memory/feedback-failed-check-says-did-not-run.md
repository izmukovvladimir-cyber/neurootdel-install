---
name: feedback-failed-check-says-did-not-run
description: "An unreadable source, a denied read or a truncated answer must not look like 'nothing found'."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Make a failed check say 'did not run', never empty

When a check cannot read its source (parser miss, pipe error, permission denied), it prints a visible 'CHECK DID NOT RUN: what, why' instead of an empty result. Keep three outcomes apart: ran and found nothing, failed, incomplete. A result exactly the size of the limit is checked for more pages before it is trusted.

**Why:** Silence, zero and 'not readable' look identical in a report, so a broken check passes as a clean one.

**How to apply:** Check exit codes and errors before trusting an empty result; report 'could not read' for denied reads; use pagination or truncation metadata when the result hits the limit.
