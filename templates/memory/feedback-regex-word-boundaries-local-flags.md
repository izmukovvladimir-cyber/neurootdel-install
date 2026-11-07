---
name: feedback-regex-word-boundaries-local-flags
description: "Substring checks fire inside longer words; a global IGNORECASE makes [A-Z] match everything."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Match words with boundaries and test the negative case

'word' in text fires inside longer words, and compiling with re.IGNORECASE makes a class like [A-Z] case-insensitive, so an ALL-CAPS rule matches ordinary text. Use word boundaries, scope case-insensitivity locally, and test texts that must not match.

**Why:** Over-matching rules block or flag normal content, and nobody notices without negative tests.

**How to apply:** Use \b boundaries; use inline (?i:...) only where needed; add tests with near-miss texts.
