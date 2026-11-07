---
name: feedback-tests-call-production-code
description: "A test that duplicates the formula proves only itself."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Make tests call the production function, not a copy

Move the logic you verify out of main() into module functions and call those exact functions in the test. A test that duplicates the formula instead of calling the production code proves nothing about it.

**Why:** The copy stays green while the real code drifts or breaks.

**How to apply:** Refactor logic into functions; import them in the test; break the real function once to see the test fail.
