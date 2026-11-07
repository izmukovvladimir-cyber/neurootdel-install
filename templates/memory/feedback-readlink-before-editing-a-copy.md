---
name: feedback-readlink-before-editing-a-copy
description: "A per-agent skill or config dir may be a symlink to a shared one that others use."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Resolve symlinks before editing a per-agent copy

Before changing a file in an agent's or client's copy of a skill or config, resolve the file itself and its directory with readlink -f; a symlink can sit on the file or on any parent. If it resolves to a shared location, the edit hits everyone.

**Why:** A 'local' edit silently changes behaviour for every agent that shares the target.

**How to apply:** readlink -f the file and its directory; if shared, ask the owner whether to edit it or give this agent its own copy; then edit.
