---
name: feedback-zero-verdict-shows-input-size
description: "A clean result means nothing until you see how much the check actually read."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Print the input size next to every zero verdict

A zero from your own check is suspect until you see what went in. Print the input size and the expected total beside the verdict, and fail when coverage is suspiciously small.

**Why:** A half-filled cache or an empty input reads as 'all clean' and closes a real problem.

**How to apply:** Print read=N of expected=M; fail below a sane minimum; sort timestamps as epoch, never as strings.
