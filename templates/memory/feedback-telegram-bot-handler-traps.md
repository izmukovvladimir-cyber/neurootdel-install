---
name: feedback-telegram-bot-handler-traps
description: "Type filters drop messages; text may be in caption or absent; verify both bot and destination."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Catch every message type and verify the sending bot

A bot handler that filters by message type drops whatever it does not match (forwards are ordinary messages with forward metadata, and new types appear). Read text, then caption, and handle messages with neither. Before reporting a send, check that the token belongs to the expected bot (getMe) and the destination chat is the intended one.

**Why:** Messages vanish without errors, and 'sent' reports may point to the wrong bot or chat.

**How to apply:** Add a catch-all handler in your framework's order; read text or caption and handle empty; check getMe and the chat id before sending; report which bot sent where.
