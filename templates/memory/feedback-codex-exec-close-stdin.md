---
name: feedback-codex-exec-close-stdin
description: "In a non-tty shell with open stdin, codex exec can wait on stdin even with a prompt argument."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Run codex exec with stdin closed

In a non-interactive shell where stdin stays open, codex exec can block 'reading additional input from stdin' even when the prompt is an argument, so close stdin. Outside a git repo it refuses to run; pass --skip-git-repo-check only for a directory you chose deliberately and trust. An empty verdict is first a suspicion about your own call.

**Why:** The review hangs or returns nothing, and the empty result gets read as approval.

**How to apply:** Run codex exec ... </dev/null; add --skip-git-repo-check only for a trusted directory; check the exit status and that an explicit verdict is present.
