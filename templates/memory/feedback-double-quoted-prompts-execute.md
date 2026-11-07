---
name: feedback-double-quoted-prompts-execute
description: "A prompt built in double quotes runs any $(...) or backticks inside it."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Keep command examples out of double-quoted strings

A text block written in double quotes in a shell script (for example a prompt for a scheduled agent) performs command substitution on $(...) and backticks, so an example command runs or breaks the script. bash -n does not catch it. Text passed in through a quoted variable or read from a file is not re-executed; the risk is literal substitution syntax in the script source.

**Why:** The scheduled job silently executes an example command or sends a broken prompt.

**How to apply:** Use a quoted heredoc (<<'EOF') or a separate file for prompts; grep the built prompt before scheduling.
