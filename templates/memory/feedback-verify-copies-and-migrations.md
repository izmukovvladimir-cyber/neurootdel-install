---
name: feedback-verify-copies-and-migrations
description: "Copies can skip unreadable files, deletes can quietly fail, and the old server keeps running."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Verify copies, deletes and migrations by their outcome

Copy and delete operations can look done while not: a non-root rsync skips unreadable files with an error and a non-zero exit that a script can easily ignore, and a failed delete is invisible if errors are hidden. Plan the final cutover with a backup, a dry-run preview of any deletions and a consistency check. After a migration the old machine still runs its crontab and bots until stopped.

**Why:** A migration looks done while files are missing, deleted items come back, and two machines answer the same users.

**How to apply:** Check rsync exit status and errors; verify each delete by listing; preview with --dry-run before any --delete pass, with a backup; stop the old host's jobs and bots in a coordinated cutover.
