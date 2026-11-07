---
name: feedback-memory-dir-follows-working-dir
description: "Auto-memory follows the project a session starts in; another start dir can show an empty memory."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Start an agent from the same working directory

Claude Code picks the auto-memory location from the project the session starts in, and settings can move it. Starting the same agent from another project directory can show a different, nearly empty memory that looks like data loss. Pin the start directory and find the memory location actually in use before migrating or restoring anything.

**Why:** The agent suddenly forgets everything and everyone suspects data loss.

**How to apply:** Pin the working directory in the service unit; if memory looks empty, find the memory dir the session really uses (for example via /memory); compare before restoring anything.
