---
name: feedback-git-checkout-dot-is-not-a-reset
description: "Staged edits and untracked files survive checkout .; reset --hard discards uncommitted tracked work."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Know that git checkout . restores from the index

git checkout . (or git restore .) restores files under the current directory from the index, so staged edits survive and untracked files stay. git reset --hard returns tracked files to HEAD, discarding uncommitted tracked changes, and can remove untracked files in its way. Never promise 'full rollback' from either without checking.

**Why:** A rollback that leaves staged or untracked changes behind looks complete and is not.

**How to apply:** Run git status --ignored before and after; protect others' work first (stash -u or a commit for untracked files, a copy for ignored files the reset may overwrite, never committing secrets); remove untracked files only by explicit list.
