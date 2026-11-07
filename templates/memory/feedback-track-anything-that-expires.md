---
name: feedback-track-anything-that-expires
description: "Cookies, keys, tokens, subscriptions and domains get an expiry line and a reminder before it."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Record expiry and a reminder for anything that lapses

When you install anything that expires or renews (cookies, API keys, OAuth tokens, subscriptions, domains, hosting), record what it is, where it lives, when it expires, whether it refreshes itself and how to renew it, never the secret value. Set a reminder or a monitor timed to its lifetime.

**Why:** Expired credentials break automations silently, usually at the worst moment.

**How to apply:** Write one line: what, where, expiry, refresh mode, how to renew; set a reminder well before expiry, or a monitor for short-lived tokens; check after renewal.
