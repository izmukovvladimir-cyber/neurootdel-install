# LEARNINGS.md: the team's shared mistakes (cold file, Read before similar work)

Lessons useful to more than one agent go here: a mistake in a shared tool, in handing work between agents,
in working with the owner, that anyone could repeat.
An agent's own lesson goes to its own files:
`python3 {{LIB}}/hooks/learnings-engine.py <workspace> capture ...`
(`core/episodes.jsonl` + a line in `core/LEARNINGS.md`, top 5 return at session start).

Entry format:

```
## YYYY-MM-DD, <agent>, <gist in 5-7 words>
Symptom: what happened and how it was noticed.
Lesson: why it happened.
Rule: what to do next time, one sentence.
```

A repeat of a mistake from this file is a system failure: the rule moves one step up
(note -> core/rules.md -> hook or script).

---
