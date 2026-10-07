---
name: present
description: Turn a block of markdown or data into a self-contained, pretty HTML presentation and send it back over Telegram as a file. Invoke when operator says "present this", "make a slide deck", "visualise", "make an HTML report".
---

# present

Given markdown, JSON, CSV or a plain prose brief, generate a clean HTML file
(self-contained, no external assets) and deliver it via Telegram `sendDocument`.

## When to use

- Operator says "present this", "slide this up", "make a slide deck".
- Operator asks for an HTML report from data.
- A subagent produced a long markdown doc and the operator wants to show it.

## How to call

```bash
# From the agent:
skills/present/scripts/build.sh <source.md> <output.html>
skills/present/scripts/send.sh <output.html>
```

## Design

- No external CSS / JS. Inline a small stylesheet (dark + light media query).
- No hardcoded chat_id, no hardcoded bot token -- both read at runtime by
  `scripts/tg-target.sh` from `/etc/vladimir-plugin/jarvis/channel.env`
  (`TELEGRAM_BOT_TOKEN`, first id of `TELEGRAM_ALLOWED_USER_IDS`), where
  the installer puts them (servers installed before the rename:
  `/etc/dashi-plugin/jarvis/channel.env`). Old gateway installs fall back to
  `${HOME}/claude-gateway/secrets/bot-token` and `config.json`.
- Target chat is configurable via `PRESENT_CHAT_ID` env var (fallback to
  the owner id above).

## Delivery

```bash
ENV_FILE=/etc/vladimir-plugin/jarvis/channel.env
[ -e "$ENV_FILE" ] || ENV_FILE=/etc/dashi-plugin/jarvis/channel.env
TG_ID="${PRESENT_CHAT_ID:-$(sed -n 's/^TELEGRAM_ALLOWED_USER_IDS=//p' "$ENV_FILE" | cut -d, -f1)}"
TOKEN=$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$ENV_FILE" | head -n1)
curl -fsSL --max-time 60 \
  -F "chat_id=${TG_ID}" \
  -F "document=@${OUTPUT_HTML}" \
  "https://api.telegram.org/bot${TOKEN}/sendDocument"
```

## Differences from Silvana internal version

- `chat_id` is no longer hardcoded (was `164795011` in Silvana's copy).
- Bot token comes from `/etc/vladimir-plugin/jarvis/channel.env` (fallback
  `${HOME}/claude-gateway/secrets/bot-token`), not
  `~/.claude-lab/silvana/secrets/...`.
- HTML template is operator-neutral (no "Silvana" / "Dark Lady" branding).
