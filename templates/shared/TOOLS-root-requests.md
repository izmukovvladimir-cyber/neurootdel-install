# Privileged actions through requests (root request carrier)

Agents have no general sudo. An action that needs root is asked for with a request: one line
in a file. Once a minute the root carrier (`{{LIB}}/agents-root-requests.sh`) takes the request,
checks it and runs only a pre-written action: with a backup, a check of the result and a line
in the journal.

## How to put a request
```
printf 'restart coder from=jarvis\n' > /var/lib/{{USER}}-requests/requests/my-req.tmp && mv /var/lib/{{USER}}-requests/requests/my-req.tmp /var/lib/{{USER}}-requests/requests/my-req
```
- File name: latin letters, digits, `.`, `_`, `-`, up to 64 characters. Write `.tmp` and rename,
  so the carrier never takes a half-written request.
- `from=<who asks>` at the end (jarvis|coder|richard|auditor) is optional. An agent's request to
  restart itself goes last.
- Result: `cat /var/lib/{{USER}}-requests/results/my-req.result`
  (ACCEPT, then DONE/DEFER/FAIL/REJECT/EXPIRED; a restart later gets VERIFY OK or VERIFY FAIL).
- Journal: `/var/log/{{USER}}-root-requests.log`.

## Requests
| Request | What it does |
|---|---|
| `restart <jarvis\|coder\|richard\|auditor>` | jarvis/coder/richard go into the agents-guard queue: restart after the end of the turn, richard last. auditor = its hermes units, at once. Same agent at most once in 2 min. |
| `allow-user <jarvis\|coder> <user_id>` | open the DM for a person (USER + CHAT ids), restart queued. Already there = ALREADY, no restart. |
| `allow-chat <jarvis\|coder> <chat_id>` | add a group (id with a minus) to TELEGRAM_ALLOWED_CHAT_IDS, restart queued. |
| `revoke-user <jarvis\|coder> <user_id>` | remove a person from USER + CHAT ids, backup next to channel.env, restart queued. The owner (OWNER_TG_ID, TELEGRAM_COMMAND_OWNER_IDS, TELEGRAM_PERMISSION_ALLOWED_USER_IDS) is never removed. |
| `permissions <jarvis\|coder>` | put `--dangerously-skip-permissions` back into the unit. Takes effect after `restart`. |
| `model <jarvis\|coder> <model>` | change `--model` in the unit (opus, sonnet, haiku, claude-opus-4-8 ...). Takes effect after `restart`. |
| `model-revert <jarvis\|coder>` | the model from before the last `model`. |
| `cron-restore` | bring back missing /etc/cron.d/{{USER}}-* files and the {{USER}} crontab from the newest nightly backup (existing files are never overwritten). |

Anything else is refused (REJECT). A command, a path or a unit name cannot be passed in a request.
Model, access and removing people: only on the owner's word.
Stop all requests (root only): `touch /etc/{{USER}}-root-requests.STOP`.
