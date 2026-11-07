---
name: feedback-ffmpeg-exact-stills-with-ss
description: "fps-filter contact sheets can drift from the source timeline on variable-frame-rate video."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Take exact video stills with ffmpeg -ss

A contact sheet built with an fps filter and drawn timestamps can drift from the source timeline on variable-frame-rate or offset video. Use it only to locate regions; for exact frames seek with -ss, take one frame and check its presentation timestamp when precision matters.

**Why:** Cuts and quotes placed by drifted timestamps land on the wrong moment.

**How to apply:** Locate with the sheet; extract with ffmpeg -ss SEC -i src -frames:v 1 out.png; read the source frame's timestamp with ffprobe -show_frames on the source file (filters may reset timestamps); label with that source timestamp.
