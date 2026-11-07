---
name: feedback-context-rereads-drive-the-cost
description: "In long agent sessions re-read context often outweighs output; measure usage before optimizing."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Measure where token cost goes before cutting it

In long tool-using sessions the context re-read on every call often costs more than the output, so fewer calls and leaner context usually save more than shorter replies. Editing a file loaded into the prompt prefix (such as CLAUDE.md) invalidates the cache from that point, so the next call pays more for that context. Measure your actual usage split before optimizing.

**Why:** Optimizing the wrong part saves nothing, while scattered small edits to loaded files add cache writes.

**How to apply:** Check usage per call (input, cache read, cache write, output); merge checks into fewer calls; batch edits to loaded files; keep loaded files small.
