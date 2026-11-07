---
name: feedback-telegram-no-raw-markdown
description: "Raw markdown symbols show as clutter; use plain text or a correctly escaped parse mode."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Send people formatted or plain text, never raw markdown

Messages to people in Telegram contain no raw markdown symbols. Write clean plain text, or use a parse mode (HTML or MarkdownV2) and escape dynamic content correctly for it. In script-generated digests, convert markdown to the chosen mode instead of sending it raw.

**Why:** Stars and hashes in a message look broken and make the agent look careless.

**How to apply:** Choose plain text, HTML or MarkdownV2; escape dynamic text for that mode; convert markdown in scripts; check the first real message as it arrives.
