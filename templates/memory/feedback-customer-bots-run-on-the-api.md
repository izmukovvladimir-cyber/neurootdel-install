---
name: feedback-customer-bots-run-on-the-api
description: "Serving customers through a personal Claude subscription login usually breaks the terms; use the API."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Run customer-facing bots on the API, not a subscription

A bot that talks to customers or leads runs on a paid API key or the platform's own AI, not on the owner's personal Claude subscription login, unless the applicable terms or a contract explicitly allow that integration. Subscriptions are generally for the subscriber's own use.

**Why:** Breaking the terms risks losing the account that all the owner's agents run on.

**How to apply:** Check which credential each customer-facing bot uses; move it to an API key; note the cost in handoff.
