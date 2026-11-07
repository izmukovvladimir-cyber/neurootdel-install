---
name: feedback-keep-sessionstart-context-small
description: "Large additionalContext may arrive only as a preview plus a file path; stay well under the documented limit."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Keep SessionStart hook output small

If a SessionStart hook returns additionalContext above the documented size threshold (version-dependent, counted in characters), the model may get only a preview plus a file path. Keep the output well under the current documented limit, with the essentials first.

**Why:** The hook reports success while the session never sees most of the text.

**How to apply:** Check the hooks docs for the current threshold; measure in characters; put essentials first; ask the session about the last lines to verify it saw them.
