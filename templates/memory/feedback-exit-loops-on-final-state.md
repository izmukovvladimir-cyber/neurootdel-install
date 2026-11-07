---
name: feedback-exit-loops-on-final-state
description: "Wait conditions check a marker or field, not the words one branch happens to print."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Exit wait loops on the final state, not message text

Wait and exit conditions check the end state you need (a marker file, a field), not the text a particular branch prints. Compute keys and paths with the tool's own function, not a re-implementation.

**Why:** Another branch prints different text, and the loop waits forever or exits too early.

**How to apply:** Define the end state; poll for it; add a timeout; import the tool's path function instead of copying it.
