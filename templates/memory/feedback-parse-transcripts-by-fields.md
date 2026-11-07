---
name: feedback-parse-transcripts-by-fields
description: "Transcript format is version-dependent: mtime is not activity, 'user' records are not all human."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Parse Claude Code transcripts by fields, not by look

Claude Code transcript files have an undocumented, version-dependent format, so test any parser against current sample files. File mtime is not session activity, records with type user are not all typed by a human, and subagent runs may sit in separate files. Classify what you cannot identify as unknown rather than guessing.

**Why:** Naive parsing reports dead sessions as live, counts system text as people, and undercounts usage.

**How to apply:** Build fixtures from current transcripts; read activity from record timestamps, noting gaps; mark human turns only by a verified field, else unknown; count usage once per message id.
