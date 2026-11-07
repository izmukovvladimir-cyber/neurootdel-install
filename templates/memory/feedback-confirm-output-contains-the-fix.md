---
name: feedback-confirm-output-contains-the-fix
description: "An output or process older than the code edit probably lacks it; check revision or behaviour."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Confirm outputs and processes contain the fix

Before claiming a fix is live, confirm that each delivered output and running process actually contains it; one older than the edit is a strong sign it does not, but timestamps alone are not proof. Check the artifact's revision or behaviour, and rebuild, reload or restart through the normal deployment procedure, using the safe-restart steps for live services.

**Why:** Old outputs and old processes silently keep the bug after you said it was fixed.

**How to apply:** Compare output and process start times with the edit as a first signal; check the revision or reproduce the fixed behaviour; rebuild or restart through the deploy procedure; check again.
