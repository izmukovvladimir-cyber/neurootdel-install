---
name: feedback-alert-suppressor-logs-itself
description: "A gate that silences a watchdog must leave a trace each time it suppresses."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Make any alert filter log a line when it fires

A gate that suppresses a watchdog signal goes after the threshold is computed and writes one log line each time it suppresses. Match its key exactly, not by substring.

**Why:** A silent suppressor hides real outages, and nobody can tell the watchdog was muted.

**How to apply:** Compute the alert; check the suppress rule with an exact key; log 'suppressed: why'; review the log weekly.
