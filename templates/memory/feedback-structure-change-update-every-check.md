---
name: feedback-structure-change-update-every-check
description: "Gates and monitors written for the old shape stay silent or raise false alarms on the new one."
metadata:
  type: feedback
  origin: installer starter lesson
---

# When you change a structure, update every check of it

A gate written for one variant checks a hard-coded field list and stays silent on a newer branch. A fix that changes an object's structure can make a neighbouring tool with a fixed norm raise a false alarm. Find every consumer before changing the shape.

**Why:** The checks stop protecting exactly where the new code goes, or they cry wolf.

**How to apply:** Grep for every reader of the structure; update gates and norms in the same change; run them on both shapes.
