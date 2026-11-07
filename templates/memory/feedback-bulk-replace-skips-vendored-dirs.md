---
name: feedback-bulk-replace-skips-vendored-dirs
description: "Mass replace across a tree must skip .venv, node_modules, .git and caches."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Exclude vendored dirs from bulk find-and-replace

A mass replace across a tree excludes .venv, site-packages, node_modules, __pycache__ and .git, and uses matching chosen for the task (word boundaries, paths, identifiers, case). Review the actual diff before keeping it.

**Why:** Editing vendored code breaks libraries in ways that surface much later and far from the edit.

**How to apply:** List matches first with exclusions; replace with matching fitted to the task; review the diff; run the tests.
