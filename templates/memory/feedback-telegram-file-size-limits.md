---
name: feedback-telegram-file-size-limits
description: "Bot API size limits depend on send method and media type; check the current docs and size the file first."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Size Telegram files by the Bot API limits

Telegram Bot API size limits differ by send method (upload, URL, file id reuse), media type and cloud versus self-hosted server, and downloads have their own limit. Check the current limit for the exact method before rendering, and size video from duration, budgeting audio and container overhead.

**Why:** Large files fail at the last step, after all the rendering work is done.

**How to apply:** Look up the limit for your send method and media type; compute the video bitrate from duration minus audio and overhead; encode two-pass; check the size before sending and send larger files as a link.
