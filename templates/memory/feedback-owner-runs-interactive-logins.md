---
name: feedback-owner-runs-interactive-logins
description: "OAuth and device-code approvals need a human; on a headless server send the link and code."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Let the owner run interactive logins; use device code

Do not complete interactive logins (OAuth consent, device-code approval) on the owner's behalf; a human approves them. You may start a device-code flow where the tool supports it and send the owner the link and one-time code, or ask them in one line to run the login in a terminal under the agent's user. A pending device flow may keep polling with a timeout and a cancel path, but no login waits unattended without a bound.

**Why:** An agent stuck inside an interactive login freezes, and access approved without the owner defeats the point of the login.

**How to apply:** Write the exact login command in a code block, or start the device flow and send its link and code; wait for the owner; check the stored token works; if it is rejected, report the error text instead of guessing the cause.
