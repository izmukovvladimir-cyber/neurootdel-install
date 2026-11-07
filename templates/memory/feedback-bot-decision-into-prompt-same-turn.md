---
name: feedback-bot-decision-into-prompt-same-turn
description: "An agreed decision about how a bot should behave lives in its prompt or config, not only in a report."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Put each agreed bot decision into its prompt at once

A behaviour decision the owner accepted for a bot you maintain goes into that bot's prompt or config in the same turn, within your authorized scope, with a backup first. Accepted findings of a live test become prompt lines or code fixes, not just a report.

**Why:** Decisions kept only in chat or reports are forgotten, and the bot keeps making the same mistake.

**How to apply:** Confirm the decision is accepted; back up the prompt; add the rule or fix; reload and test on several messages, following the deploy rules for live bots.
