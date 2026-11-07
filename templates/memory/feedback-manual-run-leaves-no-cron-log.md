---
name: feedback-manual-run-leaves-no-cron-log
description: "A tool logging to stderr may have a log file only through the scheduler's redirection."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Judge a manual run by the state it changed

A tool that logs to stderr may have a log file only because cron or a service redirects its output. Check the actual logging setup and how the job is invoked; if the log comes from redirection, a manual run leaves no line there, so judge it by the object it changes.

**Why:** An empty log after a manual run is read as 'it did not work' and starts a false hunt.

**How to apply:** Read the logging config and the cron or unit line; redirect output when running by hand; or check the changed object directly.
