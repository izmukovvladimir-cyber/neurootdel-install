---
name: feedback-telegram-pre-shows-tags-raw
description: "In Telegram HTML mode a pre block cannot carry a formatted post."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Keep formatted posts out of pre blocks

Telegram HTML parse mode allows almost no formatting nested inside pre or code, and literal angle brackets there must be escaped, so a formatted post cannot be delivered as a copy block. A post that must keep formatting (a bold first line) goes as a normal message.

**Why:** The owner copies a post full of visible tags, or loses the formatting they wanted.

**How to apply:** Send formatted posts as normal messages; use code blocks only for plain text to copy.
