---
name: feedback-test-empty-and-non-empty-inputs
description: "A job that usually finds nothing needs a safe non-empty test; empty and failed must look different."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Test a mostly-empty job on non-empty and empty input

A script whose usual result is 'nothing found' needs an end-to-end test on representative non-empty data, in a test environment or with external effects (messages, billing, writes) disabled. It must report an explicit 'empty' outcome that is distinct from a failure to fetch or process.

**Why:** Silent jobs can be broken for weeks, because 'nothing found' looks the same as 'nothing worked'.

**How to apply:** Plant one representative case in a sandbox or dry run and check it is found; feed empty input and check the explicit empty verdict; break the source and check it reports a failure.
