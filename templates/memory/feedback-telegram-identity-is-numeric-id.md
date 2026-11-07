---
name: feedback-telegram-identity-is-numeric-id
description: "Display names and usernames change; compare the numeric id with a trusted stored one."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Prove a Telegram chat's identity by its numeric id

A channel or user display name is a mutable label; a mismatch is a reason to check, not evidence of substitution. Identity means comparing the numeric id with one you stored earlier from a trusted interaction; a username can change owners, so resolving it alone proves nothing. A group upgraded to a supergroup gets a new id, so check for a verified migration before calling it a substitution.

**Why:** Name changes trigger false alarms, and look-alike names pass as the real chat.

**How to apply:** Store the numeric id when you first verify a chat; compare later ids with it, following verified migrations; use an API method whose access rules cover that entity.
