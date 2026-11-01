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
| Richard | `richard` | server doctor: raises fallen agents, backups | `claude-richard` | home dir |

## Who gets what
- Texts, decisions, the owner's day: Jarvis.
- Service down, disk, memory, agent silent: Richard.

## How agents talk
- Agent to agent only through the shared bus (when installed) plus a board card; bots never write to each
  other in Telegram.
- A report on a colleague's task goes once to the sender; to the owner only when the task was the owner's,
  a decision is needed, or something broke.
