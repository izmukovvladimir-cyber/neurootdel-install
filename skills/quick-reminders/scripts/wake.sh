#!/usr/bin/env bash
set -euo pipefail
# wake.sh ID -- run by the one-shot cron line of `create.sh --wake`: sends the saved text to the agent's own
# session through its channel webhook (POST 127.0.0.1:<TELEGRAM_WEBHOOK_PORT>/hooks/agent, the same path the
# guard scripts use), so the agent itself wakes up and does what it promised.
# The text lives in $QR_WAKE_DIR/<ID>.json (default ~/.claude-lab/shared/state/reminders), written by create.sh;
# the webhook token is read from channel.env at run time and goes to curl through stdin, the body through a
# private temp file: neither lands in argv or in crontab.
# Delivery: up to QR_WAKE_TRIES attempts (3), QR_WAKE_RETRY_SEC apart (60). All failed: the owner gets the
# text from the agent's bot ("будильник не дошёл до агента"), so the promise is not lost silently.
# The cron line is removed by this script under the same lock create.sh appends with, once the job is handled
# (delivered, or the owner was told). channel.env unreadable or the job file broken: nobody can be told, the line
# and the file stay and the reason is in wake.log.
# Exit: 0 delivered (the file is removed), 1 not delivered to the agent (the file stays, the reason in wake.log).

[[ $# -eq 1 && "$1" =~ ^[0-9a-f]{16}$ ]] || { echo "usage: $0 ID" >&2; exit 2; }
id="$1"
dir="${QR_WAKE_DIR:-$HOME/.claude-lab/shared/state/reminders}"
job="${dir}/${id}.json"
logf="${dir}/wake.log"
tries="${QR_WAKE_TRIES:-3}"
pause="${QR_WAKE_RETRY_SEC:-60}"
say() { printf '%s %s %s\n' "$(date '+%F %T')" "$id" "$1" >> "$logf" 2>/dev/null || true; }

drop_cron_line() {
    # Same lock as create.sh: a parallel add or removal cannot overwrite this one.
    (
        flock -w 30 9 || { say "crontab lock busy, line left"; exit 0; }
        crontab -l 2>/dev/null | grep -vF "qr:ID=${id} wake" | crontab - || say "crontab rewrite failed"
    ) 9>"${dir}/.crontab.lock"
}
[[ -f "$job" ]] || { say "no job file"; drop_cron_line; exit 1; }
env_file=$(jq -r '.env // empty' "$job" 2>/dev/null || true)
[[ -n "$env_file" && -r "$env_file" ]] || { say "job broken or channel.env not readable: ${env_file}; line kept"; exit 1; }
env_val() { sed -n "s/^$1=//p" "$env_file" | tail -n1 | tr -d '[:space:]"'; }

body=$(mktemp)
trap 'rm -f "${body:?}"' EXIT

# notify_owner REASON -- the owner gets the text from the agent's bot; the job is handled either way.
notify_owner() {
    local tg=""
    if jq -r '"chat_id=" + (.chat | @uri) + "&text=" + ("[будильник не дошёл до агента] " + .message | @uri)' \
            "$job" >"$body" 2>/dev/null; then
        tg=$(printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$(env_val TELEGRAM_BOT_TOKEN)" \
            | curl -s -o /dev/null -w '%{http_code}' -m 30 -K - --data-binary "@${body}" || true)
    fi
    say "$1; owner notified by the bot: ${tg:-nothing}"
    drop_cron_line
    exit 1
}

port=$(env_val TELEGRAM_WEBHOOK_PORT)
[[ "$port" =~ ^[0-9]+$ ]] || notify_owner "no TELEGRAM_WEBHOOK_PORT in ${env_file}"
jq -c '{message: .message, chatId: .chat}' "$job" >"$body" 2>/dev/null || notify_owner "job file unreadable"

code=""
for ((i = 1; i <= tries; i++)); do
    code=$(printf 'header = "Authorization: Bearer %s"\n' "$(env_val TELEGRAM_WEBHOOK_TOKEN)" \
        | curl -s -o /dev/null -w '%{http_code}' -m 30 -K - -H 'Content-Type: application/json' \
            --data-binary "@${body}" "http://127.0.0.1:${port}/hooks/agent" || true)
    if [[ "$code" == 200 ]]; then
        rm -f -- "${job:?}"
        say "delivered"
        drop_cron_line
        exit 0
    fi
    say "webhook answered ${code:-nothing} (try ${i}/${tries})"
    ((i < tries)) && sleep "$pause"
done

notify_owner "agent not woken"
