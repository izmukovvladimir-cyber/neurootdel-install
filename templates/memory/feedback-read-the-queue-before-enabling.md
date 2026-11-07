---
name: feedback-read-the-queue-before-enabling
description: "Automation over a non-empty queue can act on the backlog at once, including postponed items."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Read the queue before switching automation on

Automation switched on over a non-empty queue may act on its backlog at once, turning items deliberately postponed into actions taken without consent. Before enabling, inspect the queue by eye, check which items the automation will treat as due, and mark deferred items.

**Why:** Postponed messages or posts go out in one burst that nobody approved.

**How to apply:** List the queue; check due and eligibility rules; mark or move deferred items; enable and watch the first pass.
