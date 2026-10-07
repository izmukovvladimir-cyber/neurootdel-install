---
name: quick-reminders
description: Schedule, list and cancel one-shot reminders via cron. Invoke when operator says "remind me at X", "in 10 minutes", "tomorrow at 9", "list my reminders", or "cancel reminder N".
---

# quick-reminders

Simple cron-based one-shot reminders. No `openclaw` binary dependency --
the agent writes cron entries directly via `crontab -l | crontab -`.

## When to use

- Operator asks "remind me in 10 minutes to stretch".
- Operator asks "remind me tomorrow at 9am".
- Operator asks "list my reminders" or "cancel reminder 3".

## How it works

Three helper scripts live in `$HOME/.claude-lab/{AGENT}/.claude/skills/quick-reminders/scripts/`:

- `create.sh TIMESPEC MESSAGE` -- append a one-shot cron entry.
- `list.sh` -- print pending reminders.
- `delete.sh ID` -- remove one by numeric ID.

Reminder cron lines are tagged with `# qr:ID=<nonce>` so the skill can find
and delete them without touching the operator's other crontab entries.

Delivery uses the agent's own Telegram bot. The token is read when the
reminder fires (it never lands in crontab), from the first source that exists
(`scripts/tg-target.sh`):

1. `$TELEGRAM_BOT_TOKEN_FILE` -- a file with just the token (explicit override).
2. `/etc/vladimir-plugin/jarvis/channel.env` (servers installed before the
   rename: `/etc/dashi-plugin/jarvis/channel.env`), line `TELEGRAM_BOT_TOKEN=` --
   where the installer puts it (root:<agent user> 0640, the agent reads it via its group).
3. `$HOME/claude-gateway/secrets/bot-token` -- old gateway installs.

```bash
ENV_FILE=/etc/vladimir-plugin/jarvis/channel.env
[ -e "$ENV_FILE" ] || ENV_FILE=/etc/dashi-plugin/jarvis/channel.env
TOKEN=$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$ENV_FILE" | head -n1)
curl -fsSL --max-time 30 \
  -d "chat_id=${TG_ID}" -d "text=${MESSAGE}" \
  "https://api.telegram.org/bot${TOKEN}/sendMessage"
```

`TG_ID`: `$TELEGRAM_CHAT_ID`, else the first id of `TELEGRAM_ALLOWED_USER_IDS`
in channel.env, else `allowlist_user_ids[0]` of the old gateway config.

## Time formats supported

- `in 10m`, `in 2h`, `in 3d`  -> relative offsets
- `2026-05-01 14:30`          -> absolute (local time)
- `tomorrow 9am`, `monday 8:00` -> natural, parsed via GNU `date -d`

## Not supported

- Recurring reminders (use plain cron for that).
- Timezone-aware scheduling beyond the server's local time.
- Snooze / edit in-place (cancel + recreate instead).
