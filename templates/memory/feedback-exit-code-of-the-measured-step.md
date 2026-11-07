---
name: feedback-exit-code-of-the-measured-step
description: "In a pipe the code is the last stage's; a failed download can leave a stale or partial file."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Read the exit code of the step you measure

An exit code belongs to the last link of a pipeline: cmd | tail returns tail's code unless pipefail is set, and timeout replaces the code when it ends the command (its docs list the values and --preserve-status). Capture the code before trimming output. A failed curl -o may leave a partial or stale file, so download into a fresh temp file and accept it only when curl exits 0, the status is the expected one and the content passes a check.

**Why:** A failing script looks successful, and stale downloaded content is read as today's fact.

**How to apply:** Capture output and rc together, then print a tail; use set -o pipefail or PIPESTATUS; curl --fail into a fresh temp file; validate the content, then move it into place.
