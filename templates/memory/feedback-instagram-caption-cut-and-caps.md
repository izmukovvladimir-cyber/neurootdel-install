---
name: feedback-instagram-caption-cut-and-caps
description: "Captions get cut after the first lines; publishing tools may cap posts per rolling window."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Put the Instagram call to action in the first lines

Instagram truncates captions after the first line or two (roughly 125 characters in the feed, varying by surface), so a call to action placed later is often unseen. Publishing APIs and scheduling tools can cap posts per account, often over a rolling 24-hour window; check the limit of the tool you actually use.

**Why:** The key action goes unseen, and a batch of scheduled posts fails past the cap.

**How to apply:** Put the hook and action in the first line; check your publishing tool's quota; count posts in its window before scheduling.
