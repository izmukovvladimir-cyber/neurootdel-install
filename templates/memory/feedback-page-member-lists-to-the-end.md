---
name: feedback-page-member-lists-to-the-end
description: "One page reports everyone beyond it as missing; early exits assume an order the API may not keep."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Read paginated lists to the end before saying 'absent'

Chat and member APIs paginate; reading one page reports people beyond it as absent, and the read is not atomic. Follow the documented cursor or end signal to the end and return a completeness flag. Stop early only on a criterion the API guarantees, such as a documented sort order.

**Why:** People get wrongly reported as missing, removed or unpaid.

**How to apply:** Follow the cursor or continuation token to its end; count against the total, allowing for changes; re-read long lists; drop early exits based on assumed order.
