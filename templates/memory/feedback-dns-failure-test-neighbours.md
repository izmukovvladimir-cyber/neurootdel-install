---
name: feedback-dns-failure-test-neighbours
description: "One failing zone may be the server's resolver, not a dead domain."
metadata:
  type: feedback
  origin: installer starter lesson
---

# On a DNS failure, test neighbour domains first

A name-resolution error may be the server's resolver failing a single zone. Query several unrelated public domains through the same resolver, then the failing public domain through a public resolver, before concluding it is dead or blocked. Different answers can also mean split or private DNS, and internal names are never sent to public resolvers.

**Why:** A local resolver glitch gets reported as a site outage or a block.

**How to apply:** dig a few unrelated domains; dig the failing public name against a chosen public resolver; compare, allowing for split DNS; then conclude.
