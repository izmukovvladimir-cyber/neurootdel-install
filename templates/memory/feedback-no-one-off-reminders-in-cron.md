---
name: feedback-no-one-off-reminders-in-cron
description: "Cron is for recurring jobs; a one-time reminder goes to the team's reminder tool."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Do not put one-off reminders into cron

A one-time reminder or 'wake me at X' is not added as a cron line. Hand it to the reminder tool the team uses (a secretary agent, a calendar, a task with a due time).

**Why:** One-off cron lines fire again next year or pile up as forgotten clutter.

**How to apply:** Use the calendar, reminder tool or a one-shot scheduler such as at or systemd-run --on-calendar; if only cron exists, guard the job with a done-marker file and a lock.
