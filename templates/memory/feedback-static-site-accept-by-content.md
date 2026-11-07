---
name: feedback-static-site-accept-by-content
description: "A 200 proves availability, not the new version; check that the new text is served."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Accept a site edit by its new text, not by HTTP 200

A deploy that reports 200 proves the page is up, not that the new revision is served. Accept a text change only when the new string is present and the old one is gone, and check layout, asset or behaviour changes by looking at them. Check that removed pages behave as intended at the destination (404, 410 or a redirect), since many deploy methods do not delete remote files by themselves.

**Why:** Hosts often publish after a delay or from caches, so the old text is still served while the deploy says 'live'.

**How to apply:** Fetch the page and grep for the new and old strings; check non-text changes in a browser; fetch removed URLs and confirm the intended response; repeat after the host's publish delay.
