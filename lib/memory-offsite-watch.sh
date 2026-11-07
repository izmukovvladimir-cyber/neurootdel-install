#!/usr/bin/env bash
# memory-offsite-watch.sh -- morning check that last night's off-server memory copy (memory-offsite.sh)
# reached GitHub; when not, ONE line to the OWNER through the main agent's own bot. Without it a copy
# that fails night after night is seen by nobody: its only trace is its own log.
# Installed by neurootdel-install into <lib dir>, settings from <lib dir>/guard.conf; root cron
# /etc/cron.d/<user>-memory-offsite, hourly with --auto: it looks only in the 09:xx hour of the owner's clock.
#
#  - OFFSITE_REPO empty: "no off-server copy" + how to turn it on, once in 7 days;
#  - repo set, last OK older than MAX_AGE_H (or no OK at all once the setup is older than that):
#    "the copy is stale since ..." + the last error, once a day.
# Bot: the main agent's TELEGRAM_BOT_TOKEN, else Richard's. The token goes to curl through stdin (-K -),
# never argv, and is never printed.
# Stop: touch /var/lib/<user>-offsite-watch/STOP
# Tests: OFFSITE_WATCH_STATE (state dir), OFFSITE_WATCH_DRY=1 (print instead of send), OFFSITE_WATCH_NOW (epoch).
set -euo pipefail
umask 077

LIB="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CONF="${NEUROOTDEL_GUARD_CONF:-$LIB/guard.conf}"
[[ -f "$CONF" ]] || { echo "missing: $CONF" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONF"

NOW="${OFFSITE_WATCH_NOW:-$(date +%s)}"
TZ_OWNER="${OWNER_TIMEZONE:-Europe/Moscow}"
if [[ "${1:-}" == "--auto" && "$(TZ="$TZ_OWNER" date -d "@${NOW}" +%-H)" != 9 ]]; then
    exit 0
fi
STATE="${OFFSITE_WATCH_STATE:-/var/lib/${AGENT_USER}-offsite-watch}"
LASTF="${AGENT_HOME}/backups/offsite/last"
LOGF="${AGENT_HOME}/backups/offsite/offsite.log"
MAX_AGE_H=26
OFF_EVERY_DAYS=7
OWNER="${OWNER_TG_ID:-}"
MAIN="${MAIN_AGENT:-jarvis}"

log() { printf '%s %s\n' "$(date -u -d "@${NOW}" +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

[[ -e "${STATE}/STOP" ]] && exit 0
mkdir -p "$STATE"
chmod 700 "$STATE"
[[ "$OWNER" =~ ^[0-9]+$ ]] || { log "no OWNER_TG_ID in ${CONF}, nobody to tell"; exit 0; }

env_get() {
    [[ -r "$1" ]] || return 0
    sed -n "s/^[[:space:]]*${2}=//p" "$1" | tail -n 1 | tr -d '"'"'"'[:space:]'
}

bot_token() {
    local t
    t=$(env_get "${CONFIG_ROOT:-/etc/vladimir-plugin}/${MAIN}/channel.env" TELEGRAM_BOT_TOKEN)
    [[ -n "$t" || -z "${RICHARD_ENV:-}" ]] || t=$(env_get "$RICHARD_ENV" TELEGRAM_BOT_TOKEN)
    printf '%s' "$t"
}

# send <text> -- rc 0 only when Telegram accepted the message.
send() {
    local text=$1 token resp
    if [[ "${OFFSITE_WATCH_DRY:-0}" == "1" ]]; then
        printf 'SEND chat=%s text=%s\n' "$OWNER" "$text"
        return 0
    fi
    token=$(bot_token)
    [[ "$token" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || { log "no bot token: alert not sent: ${text}"; return 1; }
    resp=$(printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$token" \
        | curl -s -m 20 -K - --data-urlencode "chat_id=${OWNER}" --data-urlencode "text=${text}" 2>/dev/null) || true
    if [[ "$resp" == *'"ok":true'* ]]; then log "alert sent: ${text}"; return 0; fi
    log "alert NOT delivered: ${text}"
    return 1
}

# once <key> <seconds> <text> -- send unless the same key was sent less than <seconds> ago.
once() {
    local f="${STATE}/sent-$1" last=0
    [[ -f "$f" ]] && last=$(tr -dc '0-9' <"$f")
    (( NOW - ${last:-0} >= $2 )) || return 0
    if send "$3"; then printf '%s\n' "$NOW" >"$f"; fi
}

when() { TZ="$TZ_OWNER" date -d "@$1" '+%d.%m %H:%M'; }

if [[ -z "${OFFSITE_REPO:-}" ]]; then
    once off $((OFF_EVERY_DAYS * 86400 - 3600)) "Копии памяти агентов вне сервера нет: если сервер или диск умрёт, память пропадёт вместе с ним. Включить за 5 минут: sudo neurootdel-offsite-setup (покажет ключ и шаги)."
    exit 0
fi

# The status file lives in the agent's home: read it AS the agent (a link it planted never makes root
# send a root-only file to Telegram), first line, 500 bytes, no control characters.
read_last() {
    if [[ $EUID -eq 0 ]]; then runuser -u "$AGENT_USER" -- head -n 1 -- "$LASTF" 2>/dev/null
    else head -n 1 -- "$LASTF" 2>/dev/null; fi | head -c 500 | tr -d '\000-\037' || true
}
state="" t_last=0 tag="" text=""
read -r state t_last tag text <<<"$(read_last)" || true
# A time from the future (more than 10 min ahead) is not trusted: it would silence the watch for years.
[[ "$t_last" =~ ^[0-9]+$ ]] && (( t_last <= NOW + 600 )) || t_last=0
# The status of another repo (the address changed since) says nothing about this one.
want=$(printf '%s' "$OFFSITE_REPO" | sha256sum | cut -c1-12)
[[ "$tag" == "$want" ]] || { state=""; t_last=0; text=""; }
t_ok=0
[[ "$state" == OK ]] && t_ok=$t_last
# The last OK is also kept here, bound to the repo: an ERR line replaces the OK line in the status file.
okf="${STATE}/last-ok"
if (( t_ok > 0 )); then
    printf '%s %s\n' "$want" "$t_ok" >"$okf"
elif [[ -f "$okf" ]]; then
    read -r otag t_ok <"$okf" || true
    [[ "$otag" == "$want" && "$t_ok" =~ ^[0-9]+$ ]] && (( t_ok <= NOW + 600 )) || t_ok=0
fi
max=$((MAX_AGE_H * 3600))
(( NOW - t_ok < max )) && exit 0
if (( t_ok == 0 )); then
    # Never copied: say so only once the setup itself is older than a night.
    setup_t=$(stat -c %Y "$CONF" 2>/dev/null || echo "$NOW")
    (( NOW - setup_t >= max )) || exit 0
    msg="Копия памяти агентов на GitHub (${OFFSITE_REPO}) ещё ни разу не выгрузилась."
else
    msg="Копия памяти агентов на GitHub не обновлялась с $(when "$t_ok")."
fi
if [[ "$state" == ERR && -n "$text" ]]; then
    msg+=" Последняя ошибка: ${text}."
elif [[ "$state" == OFF ]]; then
    msg+=" Прогон видит пустой репозиторий в настройках."
fi
msg+=" Лог: ${LOGF}. Ключ и доступ проверит: sudo neurootdel-offsite-setup ${OFFSITE_REPO}"
once stale $((20 * 3600)) "$msg"
exit 0
