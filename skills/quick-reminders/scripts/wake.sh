#!/usr/bin/env bash
set -euo pipefail
# wake.sh ID -- run by the one-shot cron line of `create.sh --wake`: sends the saved text to the agent's own
# session through its channel webhook (POST 127.0.0.1:<TELEGRAM_WEBHOOK_PORT>/hooks/agent, the same path the
# guard scripts use), so the agent itself wakes up and does what it promised. Nothing goes to Telegram.
# The text lives in $QR_WAKE_DIR/<ID>.json (default ~/.claude-lab/shared/state/reminders), written by create.sh;
# the webhook token is read from channel.env at run time and goes to curl through stdin, never argv.
# Exit: 0 delivered (the file is removed), 1 not delivered (the file stays, the reason is in wake.log).

[[ $# -eq 1 && "$1" =~ ^[0-9a-f]{16}$ ]] || { echo "usage: $0 ID" >&2; exit 2; }
id="$1"
dir="${QR_WAKE_DIR:-$HOME/.claude-lab/shared/state/reminders}"
job="${dir}/${id}.json"
logf="${dir}/wake.log"
say() { printf '%s %s %s\n' "$(date '+%F %T')" "$id" "$1" >> "$logf" 2>/dev/null || true; }
[[ -f "$job" ]] || { say "no job file"; exit 1; }

env_file=$(jq -r '.env // empty' "$job")
[[ -r "$env_file" ]] || { say "channel.env not readable: ${env_file}"; exit 1; }
port=$(sed -n 's/^TELEGRAM_WEBHOOK_PORT=//p' "$env_file" | tail -n1 | tr -d '[:space:]"')
[[ "$port" =~ ^[0-9]+$ ]] || { say "no TELEGRAM_WEBHOOK_PORT in ${env_file}"; exit 1; }
body=$(jq -c '{message: .message, chatId: .chat}' "$job")

code=$({
    printf 'header = "Authorization: Bearer %s"\n' "$(sed -n 's/^TELEGRAM_WEBHOOK_TOKEN=//p' "$env_file" | tail -n1 | tr -d '[:space:]"')"
} | curl -s -o /dev/null -w '%{http_code}' -m 30 -K - -H 'Content-Type: application/json' \
        --data-binary "$body" "http://127.0.0.1:${port}/hooks/agent" || true)
if [[ "$code" == 200 ]]; then
    rm -f -- "${job:?}"
    say "delivered"
    exit 0
fi
say "webhook answered ${code:-nothing}"
exit 1
