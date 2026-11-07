---
name: feedback-find-every-copy-before-judging
description: "Scripts and prompts often exist in several copies; the one you read may not be the one that runs."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Find every copy of a file before judging what it does

Before stating how a script or bot prompt behaves, or approving an edit to it, find all copies by name and trace which one the live process actually loads. Compare the copies by checksum or the disputed line.

**Why:** Reviewing the installed snapshot instead of the loaded file approves changes that never take effect or contradict existing rules.

**How to apply:** Search by file name; check the process command line or include chain; diff copies; grep the loaded file for rules on the same topic.
