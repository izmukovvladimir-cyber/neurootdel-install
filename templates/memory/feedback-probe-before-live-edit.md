---
name: feedback-probe-before-live-edit
description: "Probe the target with the real credential where possible; rebuilding an object keeps unmentioned fields."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Probe before editing live config; keep what was unsaid

Before editing a live config, probe the target with the real credential where the API allows a safe read, and abort on failure; a successful read still does not prove write access. When rebuilding an existing object, 'the request did not mention it' is not permission to drop a field.

**Why:** A failed write leaves the object half changed, and a rebuild silently deletes settings people relied on.

**How to apply:** Probe with the real key where supported; snapshot the object and store it as securely as its secrets; change only named fields, atomically where possible; compare before and after.
