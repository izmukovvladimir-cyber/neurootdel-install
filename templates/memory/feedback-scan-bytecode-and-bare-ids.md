---
name: feedback-scan-bytecode-and-bare-ids
description: "Compiled .pyc files keep old strings, and leak scanners miss bare numeric account ids."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Before shipping a copy, drop bytecode and scan bare ids

Python bytecode keeps strings of old revisions (removed names, paths, personal data). Exclude __pycache__ and .pyc from any copy you hand out, and scan the final artifact for sensitive data beyond names and key shapes, including bare numeric ids of any length. Treat matches as candidates to review by hand, not to replace blindly.

**Why:** A leak detector built from names and key shapes lets bytecode and numeric ids through.

**How to apply:** Exclude __pycache__, *.pyc, .venv, logs; clean again after your own test run; scan the final archive for numeric ids of any length and other sensitive data; review each hit in context before changing it.
