---
name: feedback-hooks-read-stdin-block-explicitly
description: "Command hooks get JSON on stdin; block through a documented mechanism, then test a real call."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Write hooks that read stdin and block explicitly

A Claude Code command hook receives the event as JSON on stdin, not as arguments. Block a PreToolUse call only through a documented blocking mechanism (a blocking exit code or a JSON deny decision; check the current hooks docs), since other failures may let the call run. A hook sees command text, not behaviour, so do not make a regex judge what a command will do.

**Why:** A hook that reads arguments or fails without a clear block decision may let the call through, and a text parser is either bypassed or over-blocks.

**How to apply:** Parse stdin JSON; block with the documented exit code or a deny decision, giving a reason; test with a real blocked call; recheck the hooks docs after upgrades.
