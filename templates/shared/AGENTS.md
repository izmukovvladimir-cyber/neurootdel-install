# AGENTS.md: models, subagents, delegation (cold reference, Read before a non-trivial task)

Who is who: `STAFF.md`. Server: `TOOLS.md`.

## 1. Models
| Slot | Model | For | Never |
|---|---|---|---|
| Main | opus (the agent's service) | talking to the owner, decisions, texts, architecture | |
| Review | sonnet | independent check of an important change, second opinion | |
| Bulk | haiku | reading many files, log sweeps, collecting facts | decisions, verdicts, texts for people |

Rule: the main turn stays on the main model. If you would skim rather than read, that is haiku work.

## 2. Subagents: when
- One file, one edit, one grep: yourself.
- A look longer than 3-4 calls (logs, exports, sweeps): a subagent, you take the summary. What you read in
  the main session is paid for on every later turn.
- Independent pieces: several subagents in one message, at most 5, one subagent = one task.
- Not when your judgement is needed after every step, or you will re-check every line anyway.
- Texts for people and decisions are never handed to a subagent (see `PARALLEL-AGENTS.md`).

## 3. Cross-check
Before a change that one command cannot undo (deletion, a service, access, money): draft, review by a second
model ("read X, change Z, name the risks and missed cases"), decision, the owner's word.

## 4. Delegation between agents
- Through the shared bus plus a board card; put the whole context into the task itself.
- Not your profile: hand it to the owner of that profile per `STAFF.md`.
- Done: one report to the sender. Walk a colleague's result the way the client would before showing it.
