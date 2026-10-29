# TOOLS.md: this server, services, scripts (cold reference, Read when needed)

Written by the installer; add your own services below. No secrets here: tokens live in
`{{CONFIG_ROOT}}/<agent>/channel.env`, `/opt/richard/.env` and `~/.claude-lab/shared/secrets/`, never printed.
Before saying "it is down", check the live state (`systemctl status`, `ss -ltnp`): this file can lag.

## Services (systemd)
| Service | What | Port |
|---|---|---|
| `channel-jarvis` | Jarvis, Telegram channel (tmux + claude) | webhook 127.0.0.1 (TELEGRAM_WEBHOOK_PORT) |
| `claude-richard` | Richard, server doctor (SDK bot) | |

Restarting another agent's service is Richard's job. Your own service: `echo <agent> > /tmp/channel-restart-request`.

## Scripts `{{LIB}}/` (root-owned; changes only through the shell with the owner's decision)
- `agents-guard.py` (cron every minute, root): stall, permission question, login, limit + auto-answer,
  owner unanswered, restart queue. Alerts: `python3 {{LIB}}/agents-guard.py --drain`. Stop: touch /var/lib/{{USER}}-guard/STOP.
- `agents-reset.sh` (cron every 10 min, --auto): nightly 04:00 and daytime reset of bloated sessions by the
  owner's clock. Dry run: `bash {{LIB}}/agents-reset.sh --dry-run`.
- `agent-handoff-flush.py <agent>`: "Last 15 actions" into core/hot/handoff.md.
- `memory-backup.sh` (cron hourly, --auto = 03:30 owner time): ~/backups/memory, 14 days.
- `include_weight.py`: memory weight per turn. `compact-open-items-reminder.py`: SessionStart after compaction.
- `gbrain-call.py`: shared memory client (only when gbrain is installed on this server).

## Hooks `{{LIB}}/hooks/`
| Hook | Event | Where |
|---|---|---|
| `block-dangerous.py`, `protect-files.sh` | PreToolUse | ~/.claude/settings.json (every session) |
| `compact-open-items-reminder.py` | SessionStart | ~/.claude/settings.json |
| `correction-detector.py`, `auto-recall.py`, `critical-check.py` | UserPromptSubmit | plugin/.claude/settings.json |
| `fact-check-gate.py` | PreToolUse (reply, edit_message) | plugin/.claude/settings.json (main agent only) |
| `learnings-engine.py <ws> top` | SessionStart | plugin/.claude/settings.json |
| `precompact-flush.sh <agent>` | PreCompact | plugin/.claude/settings.json |

Hooks only work in a settings.json the session really reads: ~/.claude/settings.json and
`~/.claude-lab/<agent>/.claude/dashi-plugin-claude-code/plugin/.claude/settings.json` (the service's cwd).
Stop a hook: remove its line from that file.

## Plugins and code style
- superpowers: enabled in ~/.claude/settings.json (enabledPlugins).
- Code style rules: ~/.claude/rules/{bash,python,typescript}.md (load in every session).
