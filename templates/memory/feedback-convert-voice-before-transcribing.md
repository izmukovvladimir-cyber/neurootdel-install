---
name: feedback-convert-voice-before-transcribing
description: "Voice messages are usually Ogg Opus, which some transcription APIs reject; check before sending."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Check Telegram voice format before speech-to-text

Telegram voice messages are usually Ogg Opus (.oga) but can come in other formats, and some speech-to-text APIs reject Ogg. Check the actual file format and the provider's accepted formats, and convert with ffmpeg only when needed. Some providers bill a minimum duration per request, so many tiny clips can cost more than their length suggests.

**Why:** Transcription fails on every voice message, or quota runs out on tiny clips.

**How to apply:** Check the file's real format with ffprobe and the provider's list; convert with ffmpeg if needed; batch short clips where a minimum is billed; check the transcript is not empty.
