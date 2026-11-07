---
name: feedback-telegram-topics-and-member-lists
description: "Post into a topic with message_thread_id; the HTTP Bot API cannot list all supergroup members."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Know how Telegram topics and member lists work

To post inside a forum topic, pass its message_thread_id. The HTTP Bot API cannot list all supergroup members: it can list administrators, get the count and check one member by id, which is reliable only when the bot is an administrator, so a failed check means unknown, not 'not a member'. A full roster needs an MTProto client with the required permissions.

**Why:** Posts land in the general topic, and member audits miss most people.

**How to apply:** Take message_thread_id from an update in that topic; check members by id with the bot as admin; treat errors as unknown; for full lists use an MTProto client only as the owner authorizes.
