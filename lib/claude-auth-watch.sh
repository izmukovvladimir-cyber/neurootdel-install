#!/usr/bin/env bash
# claude-auth-watch.sh -- tells the OWNER, through the agent's own Telegram bot, that the agents lost
# their Claude login. Without it an agent with "Not logged in" just goes silent, and the guard's own
# login alert lands in its outbox, which nobody reads. Installed by neurootdel-install into <lib dir>,
# settings from <lib dir>/guard.conf; root cron /etc/cron.d/<user>-auth-watch, hourly.
#
# Checks (each sends at most one line, by the bot of the agent concerned, to OWNER_TG_ID):
#  1) pane: a channel agent (CHANNEL_AGENTS) shows "Not logged in / Please run /login / OAuth token
#     has expired" -> once per 6 h per agent;
#  2) no login at all: an agent unit is enabled, but there is no ~/.claude/.credentials.json and no
#     CLAUDE_CODE_OAUTH_TOKEN in that agent's channel.env -> once a day per agent, by its own bot;
#  3) optional long-lived setup-token: $STATE/oauth-issued holds its issue date (YYYY-MM-DD) ->
#     from WARN_DAYS before its 1-year expiry, once a day.
# The usage limit is not watched here: agents-guard.py already tells the owner by the bot.
# Bot: the agent's own TELEGRAM_BOT_TOKEN, else the main agent's, else Richard's. The token goes to
# curl through stdin (-K -), never argv, and is never printed.
# Stop: touch /var/lib/<user>-auth-watch/STOP (or remove the cron file).
# Tests: AUTH_WATCH_STATE (state dir), AUTH_WATCH_PANES (dir with <agent>.txt panes),
#        AUTH_WATCH_ENABLED (space list of enabled units), AUTH_WATCH_DRY=1 (print instead of send),
#        AUTH_WATCH_NOW (epoch seconds).
set -euo pipefail
umask 077

LIB="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CONF="${NEUROOTDEL_GUARD_CONF:-$LIB/guard.conf}"
[[ -f "$CONF" ]] || { echo "missing: $CONF" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONF"

STATE="${AUTH_WATCH_STATE:-/var/lib/${AGENT_USER}-auth-watch}"
NOW="${AUTH_WATCH_NOW:-$(date +%s)}"
WARN_DAYS=14
PANE_COOLDOWN=21600
LOGIN_RE='⎿.*(Not logged in|Please run /login|OAuth token has expired)'
read -r -a AGENTS <<< "${CHANNEL_AGENTS:-jarvis}"
MAIN="${MAIN_AGENT:-${AGENTS[0]:-jarvis}}"
OWNER="${OWNER_TG_ID:-}"

log() { printf '%s %s\n' "$(date -u -d "@${NOW}" +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

[[ -e "${STATE}/STOP" ]] && exit 0
mkdir -p "$STATE"
chmod 700 "$STATE"
[[ "$OWNER" =~ ^[0-9]+$ ]] || { log "no OWNER_TG_ID in ${CONF}, nobody to tell"; exit 0; }

today=$(TZ="${OWNER_TIMEZONE:-Europe/Moscow}" date -d "@${NOW}" +%F)

# env_get <file> <KEY> -- a value from an env file, quotes stripped; empty if none.
env_get() {
    [[ -r "$1" ]] || return 0
    sed -n "s/^[[:space:]]*${2}=//p" "$1" | tail -n 1 | tr -d '"'"'"'[:space:]'
}

channel_env() { printf '%s/%s/channel.env' "${CONFIG_ROOT:-/etc/vladimir-plugin}" "$1"; }

# bot_token <agent> -- the agent's bot, else the main agent's, else Richard's.
bot_token() {
    local t
    t=$(env_get "$(channel_env "$1")" TELEGRAM_BOT_TOKEN)
    [[ -n "$t" ]] || t=$(env_get "$(channel_env "$MAIN")" TELEGRAM_BOT_TOKEN)
    [[ -n "$t" || -z "${RICHARD_ENV:-}" ]] || t=$(env_get "$RICHARD_ENV" TELEGRAM_BOT_TOKEN)
    printf '%s' "$t"
}

# send <agent> <text> -- rc 0 only when Telegram accepted the message.
send() {
    local agent=$1 text=$2 token resp
    if [[ "${AUTH_WATCH_DRY:-0}" == "1" ]]; then
        printf 'SEND via=%s chat=%s text=%s\n' "$agent" "$OWNER" "$text"
        return 0
    fi
    token=$(bot_token "$agent")
    if [[ ! "$token" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
        log "no bot token for ${agent}: alert not sent: ${text}"
        return 1
    fi
    resp=$(printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$token" \
        | curl -s -m 20 -K - --data-urlencode "chat_id=${OWNER}" --data-urlencode "text=${text}" 2>/dev/null) || true
    if [[ "$resp" == *'"ok":true'* ]]; then
        log "alert sent via ${agent}: ${text}"
        return 0
    fi
    log "alert NOT delivered via ${agent}: ${text}"
    return 1
}

unit_enabled() {
    if [[ -n "${AUTH_WATCH_ENABLED+x}" ]]; then
        [[ " ${AUTH_WATCH_ENABLED} " == *" $1 "* ]]
    else
        systemctl is-enabled --quiet "$1" 2>/dev/null
    fi
}

# pane <agent> -- the last 40 non-empty lines of the agent's tmux screen; empty if not running.
pane() {
    local sess="channel-$1"
    if [[ -n "${AUTH_WATCH_PANES:-}" ]]; then
        [[ -f "${AUTH_WATCH_PANES}/$1.txt" ]] && grep -v '^[[:space:]]*$' "${AUTH_WATCH_PANES}/$1.txt" | tail -n 40
        return 0
    fi
    systemctl is-active --quiet "$sess" 2>/dev/null || return 0
    runuser -u "$AGENT_USER" -- tmux -L "$sess" capture-pane -p -t "$sess" 2>/dev/null \
        | grep -v '^[[:space:]]*$' | tail -n 40 || true
}

label() {
    local pair
    for pair in ${AGENT_LABELS//,/ }; do
        [[ "${pair%%=*}" == "$1" ]] && { printf '%s' "${pair#*=}"; return 0; }
    done
    printf '%s' "$1"
}

# 1) panes stuck on a lost login
for a in "${AGENTS[@]}"; do
    [[ "$a" =~ ^[a-z0-9-]+$ ]] || continue
    screen=$(pane "$a")   # captured first: grep -q on a pipe would SIGPIPE it under pipefail
    if grep -qE "$LOGIN_RE" <<<"$screen"; then
        last=$(cat "${STATE}/pane-${a}" 2>/dev/null || echo 0)
        [[ "$last" =~ ^[0-9]+$ ]] || last=0
        if (( NOW - last > PANE_COOLDOWN )); then
            if send "$a" "$(label "$a"): вход в Claude слетел (Not logged in), агент не отвечает. Нужен новый вход: sudo -u ${AGENT_USER} -i bash -lc 'claude auth login'"; then
                printf '%s\n' "$NOW" > "${STATE}/pane-${a}"
            fi
        fi
    fi
done

# 2) no login at all while an agent is meant to run: per enabled agent, which has a login when the
#    shared ~/.claude/.credentials.json exists or its own channel.env carries CLAUDE_CODE_OAUTH_TOKEN.
shared_login=0
[[ -s "${AGENT_HOME}/.claude/.credentials.json" ]] && shared_login=1
for a in "${AGENTS[@]}"; do
    [[ "$a" =~ ^[a-z0-9-]+$ ]] || continue
    unit_enabled "channel-${a}" || continue
    (( shared_login )) && continue
    [[ -n "$(env_get "$(channel_env "$a")" CLAUDE_CODE_OAUTH_TOKEN)" ]] && continue
    [[ "$(cat "${STATE}/nologin-${a}" 2>/dev/null)" != "$today" ]] || continue
    if send "$a" "$(label "$a"): нет входа в Claude, агент не может отвечать. Нужен вход: sudo -u ${AGENT_USER} -i bash -lc 'claude auth login'"; then
        printf '%s\n' "$today" > "${STATE}/nologin-${a}"
    fi
done

# 3) long-lived setup-token close to its expiry
if [[ -f "${STATE}/oauth-issued" ]]; then
    issued=$(tr -d '[:space:]' < "${STATE}/oauth-issued")
    if [[ "$issued" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && expires=$(date -d "${issued} + 365 days" +%s 2>/dev/null); then
        left=$(( (expires - NOW) / 86400 ))
        if (( left <= WARN_DAYS )) && [[ "$(cat "${STATE}/expiry-sent" 2>/dev/null)" != "$today" ]]; then
            if send "$MAIN" "Вход Claude у агентов истекает через ${left} дн. ($(date -d "@${expires}" +%d.%m.%Y)). Нужен новый вход заранее, иначе агенты замолчат."; then
                printf '%s\n' "$today" > "${STATE}/expiry-sent"
            fi
        fi
    else
        log "bad date in ${STATE}/oauth-issued: ${issued}"
    fi
fi
exit 0
