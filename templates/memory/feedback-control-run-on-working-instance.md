---
name: feedback-control-run-on-working-instance
description: "Before calling something broken or absent, repeat the check where it is known to work."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Run the same check on a known-working instance first

A config that looks fine on the broken object is a lone fact. Run the same read-only check on a working instance of the same kind: it helps tell a fault in this layer from one elsewhere, and shows whether your scan can see anything at all.

**Why:** A scan that says 'absent' everywhere may simply be blind.

**How to apply:** Pick a known-good twin; run the identical read-only diagnostic on both; compare; then narrow down the faulty layer.
