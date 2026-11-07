---
name: feedback-selftest-uses-own-temp-paths
description: "A self-test on live state files can wipe a shared marker or counter for every colleague."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Run a shared tool's self-test on its own temp paths

A tool that shares state through files must self-test only against paths it created itself (a temp dir) and remove them in a finally block. Never run self-tests on, or restore snapshots over, live shared files.

**Why:** One self-test can reset a shared ban flag or counter and break the tool for everyone.

**How to apply:** Create a temp dir; point the tool at it via arguments; clean up in finally; never default to live paths in tests.
