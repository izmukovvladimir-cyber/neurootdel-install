---
name: feedback-harness-may-run-the-wrong-thing
description: "Stale .pyc, a no-op logging config or a path shadow can make a test green while testing nothing."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Make sure tests and mutants run what you think

A test harness can be green while testing nothing: a timestamp-based .pyc can be reused when source mtime and size match, logging.basicConfig is a no-op if a handler exists, and sys.path.insert beats PYTHONPATH. Delete __pycache__ between a mutation and its control run; python3 -B only stops writing bytecode, it still reads a stale cache.

**Why:** A mutation reverted within the same second keeps running the mutant's bytecode, so the result lies.

**How to apply:** Delete __pycache__ before isolated runs; print the imported module's path; check that the mutant actually changed the file; confirm the mutant run fails.
