---
name: feedback-judge-generated-code-by-render
description: "Generated HTML and scripts fail in ways source review misses; render them with real inputs."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Judge generated markup by its rendered output

Check generated code by reviewing the source and then running or rendering it with representative inputs in a safe test environment. A stray brace in mixed f-strings can silently break an embedded script, and search normalisation can differ between query and data.

**Why:** Source that looks right can produce a broken page that nobody notices until a person uses it.

**How to apply:** Review the source for side effects; render in a sandbox with representative, non-sensitive data; open the result; test the edge inputs (case, special letters, braces).
