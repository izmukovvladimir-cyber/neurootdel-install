---
name: feedback-sandboxed-service-writes-elsewhere
description: "PrivateTmp and protection settings change what a service sees and may write; check where the file went."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Check the file on disk when a sandboxed service writes

When a systemd service writes a file for you, check where it actually lands. With PrivateTmp its /tmp is a private namespace you do not see, and ProtectHome or ProtectSystem make paths inaccessible or read-only, so writes there fail with an error.

**Why:** The file is not where you look, and debugging starts in the wrong place.

**How to apply:** systemctl cat the unit for sandbox options; check the service log for write errors; write to an allowed, shared path; check the file exists after the run.
