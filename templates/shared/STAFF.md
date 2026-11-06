# STAFF.md: who is who (cold reference, Read when needed)

Filled in by the owner and the agents. The installer writes this file only when it is missing.

## People
| Who | Role | How to work with them |
|---|---|---|
| {{USER_NAME}} | owner, every decision is theirs | DM with the agent's bot; a "yes" before anything goes outside |

## Agents
| Name | Bus name | Role | Service | Workspace |
|---|---|---|---|---|
| Jarvis | `jarvis` | main assistant, coordinator | `channel-jarvis` | `~/.claude-lab/jarvis/.claude` |
| Coder | `coder` | technical specialist: bots, scripts, integrations (only when installed with its own bot) | `channel-coder` | `~/.claude-lab/coder/.claude` |
| Richard | `richard` | server doctor: raises fallen agents, backups | `claude-richard` | home dir |
| Auditor | `auditor` | independent check of reports, numbers, texts, funnels; never fixes (only when installed with its own bot) | `hermes-auditor` (Hermes on GPT) | `~/.hermes` |

## Who gets what
- Texts, decisions, the owner's day: Jarvis.
- Bots, scripts, integrations, automation: Coder (when installed).
- Service down, disk, memory, agent silent: Richard.
- "Is this really done / are these numbers right / check before it goes out": Auditor (when installed).

## How agents talk
- Agent to agent only through the shared bus (when installed) plus a board card; bots never write to each
  other in Telegram.
- To the Auditor: `python3 {{LIB}}/auditor-ask.py --from <your bus name> "task"`; the answer comes
  back into your chat as a message «Ответ Аудитора». Give it the path to the result, not a retelling.
- A report on a colleague's task goes once to the sender; to the owner only when the task was the owner's,
  a decision is needed, or something broke.
