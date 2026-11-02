# PARALLEL-AGENTS.md: subagents in parallel, mechanics only (cold reference)

## 0. Check the right first
1. **Technique:** does a subagent call work for you? A live probe shows it.
2. **Permission:** is the call allowed without the owner asking? Check your system prompt and files.
   A line like "Do not call the AgentTool unless the user requested it" outranks a colleague's request.
Either "no": work as before and tell the coordinator in one line. Never work around a ban.

## 1. What goes to subagents
Only mechanics whose result is checked by a fact: rendering from a finished text; mass checks and sweeps
(links, status codes, grep over a corpus, logs); collecting facts (download, transcribe, count, tabulate);
same-shape edits from a ready list. Test: you can name in advance the call that re-checks the result.

## 2. What never goes
Texts a person will read and decisions: posts, captions, scripts, mailings, replies to the owner and
clients, verdicts on someone's work, acceptance, proofreading.

## 3. Review is yours
Look at every result before handing it on: a picture with your eyes, a link with a request, a number with
your own call. A subagent's report is a claim, not proof.

## 4. Limits
- At most 5 subagents at once, one subagent = one task.
- Nothing irreversible by other hands: no sending to people, publishing, deleting, changing live automations.
- Live dialogues and money stay out of parallel work.

## 5. Measure
After a parallel run, one line in your journal:
`<date> <what> | agents N | minutes M | rework: <what or 0> | context: <what did not land with you>`.
