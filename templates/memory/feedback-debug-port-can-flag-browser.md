---
name: feedback-debug-port-can-flag-browser
description: "Some anti-bot checks may react to an open remote-debugging port; test it as one hypothesis."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Test the browser debug port when a site blocks you

Anti-bot scoring on some web apps may react to an open remote-debugging port among other automation signals. Treat it as a hypothesis: retry with only the port closed, keeping profile, cookies and flags the same, before blaming proxies or typing speed.

**Why:** Agents can waste days on proxies and typing delays while the real signal is elsewhere.

**How to apply:** Change only the debug port and retry; repeat to rule out chance; if confirmed, keep automation off that site or use its supported route.
