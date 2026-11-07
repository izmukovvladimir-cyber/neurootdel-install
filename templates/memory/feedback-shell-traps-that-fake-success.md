---
name: feedback-shell-traps-that-fake-success
description: "ssh in a read loop, timeout without kill, set -e and pgrep self-matches all hide failures."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Know the shell constructs that fake success

ssh inside while-read reads the loop's stdin and eats the rest of the list; timeout is not a ceiling if the process ignores SIGTERM; set -e kills a runner right when it should report; pgrep -f in the launching command finds its own wrapper. $! is the background job's PID, which may differ from a daemon's final PID.

**Why:** Each of these reports partial or no work as success, and the report goes out wrong.

**How to apply:** Give ssh -n or a /dev/null stdin in loops unless remote stdin is needed; timeout --kill-after; capture rc explicitly; assert processed count equals input count.
