---
name: feedback-large-payloads-via-file
description: "One argument is capped (commonly 128 KiB on Linux); above it the program never starts."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Pass large payloads via a file or stdin, not argv

On Linux a single command-line argument is capped (32 pages, commonly 128 KiB) regardless of the total argument limit. Send large bodies via a file or stdin, and keep secrets out of argv, where other users can see them in the process list.

**Why:** The command fails before starting with a confusing error, or the secret leaks via the process list.

**How to apply:** Write the body to a private temp file from mktemp and delete it after; use curl with a file body or a stdin pipe; never put tokens in arguments.
