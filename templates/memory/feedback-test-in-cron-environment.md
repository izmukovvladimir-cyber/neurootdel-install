---
name: feedback-test-in-cron-environment
description: "Cron has a minimal PATH and skips badly owned cron.d files without a word."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Test a cron script in cron's environment

A script that works when you run it can silently do nothing under cron: cron's PATH is minimal (no user bin dirs), and cron skips files in /etc/cron.d that are not owned by root or are writable by others.

**Why:** The job is 'installed' and never runs, and nobody notices for days.

**How to apply:** Use absolute paths; run once with env -i and the cron PATH; check owner and mode of cron.d files; check the first scheduled run in the log.
