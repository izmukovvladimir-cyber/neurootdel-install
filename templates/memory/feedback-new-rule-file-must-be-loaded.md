---
name: feedback-new-rule-file-must-be-loaded
description: "A rule file that nothing loads or points to is never read."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Make sure a new rule file is actually loaded

A rule file affects behaviour only if something loads it: an import in CLAUDE.md, a directory the tool loads automatically (check its docs), or an explicit pointer with its trigger. When you create one, connect it in the same move and confirm in a new session that it is loaded.

**Why:** An unlinked rule file exists on disk and has no effect on behaviour.

**How to apply:** Check how the tool discovers rule files; add an import or pointer only if needed; confirm it loads in a new session (for example with /memory).
