---
name: feedback-yt-dlp-full-extract-for-views
description: "yt-dlp flat playlist can omit view counts; extract per video and handle missing values."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Use full per-video extraction for YouTube views

yt-dlp --flat-playlist lists a channel fast but may leave metadata such as view counts missing. For views, run a per-video extract with --skip-download, which is slower, and still handle missing values.

**Why:** Rankings built on empty view counts are random, and nobody notices the field was empty.

**How to apply:** List with --flat-playlist; extract views per video for the shortlist; treat NA as missing, not zero; record when you fetched them.
