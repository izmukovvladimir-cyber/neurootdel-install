---
name: feedback-judge-api-by-real-call-and-body
description: "Errors can come as HTTP 200 with a failure flag inside; a keyless GET says nothing about the real path."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Judge an API by the real client call and its parsed body

Check a service with the same kind of call real clients make (method, path, auth), using a safe read, a sandbox or a dry run rather than repeating a real send, purchase or write. Decide success by the API contract, status and body together: failures often arrive as HTTP 200 with an error flag inside. Your own script must never print 'ok' on its own.

**Why:** A light probe or a status-only check reports a dead service as alive, or a live one as dead.

**How to apply:** Pick a safe call on the real path; read status and body error fields together; detect limits from the documented status, error fields and retry headers; print success only from the parsed result.
