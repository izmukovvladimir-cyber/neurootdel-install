#!/usr/bin/env bash
# verify-stage.sh -- end-of-stage check: what was taught and installed, one line per item, ✅ or ❌,
# and under every ❌ how to fix it. Run by the installer at the end of each stage and by the student
# (sudo neurootdel-verify) or an agent at any time. Reads only; changes nothing on the server.
#
# Stages: workshop = Jarvis + Richard, intensive = + Coder + Auditor. Default: INSTALL_STAGE from
# guard.conf. An agent installed outside the stage (a bot already on this server) is checked too.
# Per agent: service active, own bot answers getMe, owner in the allowlist, workspace, CLAUDE.md and
# rules present, @-paths of CLAUDE.md resolve, hooks on, skills. Server: starter rules, memory rotation,
# guard, login watch, backup, root requests. Auditor: Hermes service, ChatGPT login, bridge.
# Editorial loop: «выключено» while EDITORIAL_ENABLED=0 (not a failure).
#
# Tokens: read from the env files, sent to curl through stdin (-K -), never argv, never printed.
# Exit: 0 = all ✅, 1 = at least one ❌, 2 = usage / no guard.conf.
# Tests: NEUROOTDEL_GUARD_CONF (guard.conf), VERIFY_CRON_DIR (/etc/cron.d), VERIFY_VAR_LIB (/var/lib),
#        VERIFY_ETC (/etc); systemctl, curl, crontab, jq are taken from PATH.
set -uo pipefail

LIB="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CONF="${NEUROOTDEL_GUARD_CONF:-$LIB/guard.conf}"
CRON_DIR="${VERIFY_CRON_DIR:-/etc/cron.d}"
VAR_LIB="${VERIFY_VAR_LIB:-/var/lib}"
ETC="${VERIFY_ETC:-/etc}"

usage() { echo "usage: $(basename "$0") [--stage workshop|intensive]" >&2; exit 2; }

STAGE=""
while (($#)); do
    case "$1" in
        --stage) STAGE="${2:-}"; shift ;;
        --stage=*) STAGE="${1#--stage=}" ;;
        -h|--help) usage ;;
        *) usage ;;
    esac
    shift
done

[[ -f "$CONF" ]] || { echo "❌ нет ${CONF}: установщик не дошёл до сторожа. Запусти установщик снова." >&2; exit 2; }
# shellcheck disable=SC1090
. "$CONF"
STAGE="${STAGE:-${INSTALL_STAGE:-workshop}}"
[[ "$STAGE" == workshop || "$STAGE" == intensive ]] || usage

U="${AGENT_USER:-neurootdel}"
H="${AGENT_HOME:-/home/${U}}"
CR="${CONFIG_ROOT:-/etc/vladimir-plugin}"
OWNER="${OWNER_TG_ID:-}"
HERMES_HOME="${H}/.hermes"

PASS=0
FAIL=0
yes_() { PASS=$((PASS + 1)); printf '✅ %s\n' "$1"; }
no_()  { FAIL=$((FAIL + 1)); printf '❌ %s\n   как починить: %s\n' "$1" "$2"; }
# check <text> <fix hint> <command...> -- one line of the checklist.
check() {
    local text=$1 hint=$2; shift 2
    if "$@" >/dev/null 2>&1; then yes_ "$text"; else no_ "$text" "$hint"; fi
}
section() { printf '\n%s\n' "$1"; }

# env_get <file> <KEY> -- a value from an env file, quotes and spaces stripped; empty if none.
env_get() {
    [[ -r "$1" ]] || return 0
    sed -n "s/^[[:space:]]*${2}=//p" "$1" | tail -n 1 | tr -d '"'"'"'[:space:]'
}

unit_active() { [[ "$(systemctl is-active "$1" 2>/dev/null)" == active ]]; }

# bot_ok <env_file> -- the bot in that file answers getMe. The URL with the token goes through stdin.
bot_ok() {
    local t resp
    t=$(env_get "$1" TELEGRAM_BOT_TOKEN)
    [[ "$t" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || return 1
    resp=$(printf 'url = "https://api.telegram.org/bot%s/getMe"\n' "$t" | curl -s -m 15 -K - 2>/dev/null) || return 1
    [[ "$resp" == *'"ok":true'* ]]
}

# owner_in <env_file> <KEY> -- the owner's Telegram id is in that comma/space list.
owner_in() {
    local v
    [[ "$OWNER" =~ ^[0-9]+$ ]] || return 1
    v=$(env_get "$1" "$2")
    [[ ",${v//[[:space:]]/}," == *",${OWNER},"* ]]
}

# owner_in_both <channel.env> -- the owner in both lists: user ids (who may write) and chat ids (where).
owner_in_both() { owner_in "$1" TELEGRAM_ALLOWED_USER_IDS && owner_in "$1" TELEGRAM_ALLOWED_CHAT_IDS; }

# BOT_FILES: "<label>=<env file>" of every agent checked; bots_unique: no two share one bot (same id
# before ':'), two pollers on one bot take each other's messages.
BOT_FILES=()
bots_unique() {
    local pair id seen=" "
    for pair in "${BOT_FILES[@]}"; do
        id=$(env_get "${pair#*=}" TELEGRAM_BOT_TOKEN)
        id="${id%%:*}"
        [[ -n "$id" ]] || continue
        [[ "$seen" == *" ${id} "* ]] && return 1
        seen="${seen}${id} "
    done
    return 0
}

# at_paths_ok <CLAUDE.md> -- every "@path" line of the file points at an existing file
# (~ = the agent's home, a relative path is taken from the file's dir).
at_paths_ok() {
    local f=$1 dir p
    [[ -f "$f" ]] || return 1
    dir=$(dirname "$f")
    while IFS= read -r p; do
        p="${p#@}"
        p="${p%%[[:space:]]*}"
        [[ -n "$p" ]] || continue
        case "$p" in
            "~/"*) p="${H}/${p#\~/}" ;;
            /*) ;;
            *) p="${dir}/${p}" ;;
        esac
        [[ -e "$p" ]] || return 1
    done < <(grep -E '^@[^[:space:]]+' "$f")
    return 0
}

# has_all <file> <needle...> -- every needle is in the file.
has_all() {
    local f=$1 n; shift
    [[ -f "$f" ]] || return 1
    for n in "$@"; do grep -qF -- "$n" "$f" || return 1; done
}

# skills_ok <skills_dir> <plugin_root> -- at least SKILLS_EXPECTED skills, linked into the session.
skills_ok() {
    local n
    [[ -d "$1" ]] || return 1
    n=$(find "$1" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) | wc -l)
    [[ "$n" -ge "${SKILLS_EXPECTED:-1}" && -e "${2}/.claude/skills" ]]
}

# starter_ok <CLAUDE.md> -- the starter rules block (or, in an older file, its rule-4 phrase), as the installer checks.
starter_ok() { grep -qF -- "<!-- agent-rules-starter:begin -->" "$1" || grep -qF -- "Понял так" "$1"; }

cron_on() { [[ -f "${CRON_DIR}/$1" && ! -e "$2" ]]; }

agent_crontab() {
    if [[ $EUID -eq 0 ]]; then crontab -u "$U" -l 2>/dev/null; else crontab -l 2>/dev/null; fi
}

listed_in() { [[ " ${2} " == *" ${1} "* ]]; }

auditor_logged_in() {
    jq -e '(.credential_pool["openai-codex"] // []) | length > 0' "${HERMES_HOME}/auth.json" >/dev/null 2>&1
}

SUDO_HINT="запусти проверку через sudo: sudo neurootdel-verify"

# --- channel agents (Jarvis, Coder) ---------------------------------------------------------------
check_channel_agent() {
    local agent=$1 label=$2 unit="channel-$1"
    local env="${CR}/${agent}/channel.env" ws="${H}/.claude-lab/${agent}/.claude"
    local plugin="${ws}/dashi-plugin-claude-code/plugin"
    section "${label} (${agent})"
    BOT_FILES+=("${label}=${env}")
    check "${label}: сервис ${unit} работает" \
        "после входа в Claude: sudo systemctl restart ${unit}; причина в журнале: sudo journalctl -u ${unit} -n 50" \
        unit_active "$unit"
    check "${label}: свой бот отвечает Telegram (getMe)" \
        "впиши токен своего бота из @BotFather в ${env} (TELEGRAM_BOT_TOKEN), урок docs/lesson-create-bots.md; без доступа к файлу ${SUDO_HINT}" \
        bot_ok "$env"
    check "${label}: владелец в списке доступа бота" \
        "твой id из @userinfobot в TELEGRAM_ALLOWED_USER_IDS и TELEGRAM_ALLOWED_CHAT_IDS файла ${env}, затем sudo systemctl restart ${unit}" \
        owner_in_both "$env"
    check "${label}: рабочая папка, CLAUDE.md и правила на месте" \
        "запусти установщик снова: он допишет недостающие файлы в ${ws}, твои не тронет" \
        ws_files_ok "$ws"
    check "${label}: файлы по ссылкам @ из CLAUDE.md существуют (загружаются)" \
        "открой ${ws}/CLAUDE.md, найди строку с @ на несуществующий файл: верни файл или убери строку" \
        at_paths_ok "${ws}/CLAUDE.md"
    check "${label}: практики learned-practices подключены" \
        "запусти установщик снова: он положит ${plugin}/.claude/rules/learned-practices.md" \
        test -f "${plugin}/.claude/rules/learned-practices.md"
    check "${label}: хуки включены (проверка фактов, ответ при сбое, сброс памяти перед сжатием)" \
        "запусти установщик снова: шаг хуков пишет ${plugin}/.claude/settings.json" \
        has_all "${plugin}/.claude/settings.json" fact-check-gate.py correction-detector.py fallback-reply-hook.ts precompact-flush.sh learnings-engine.py
    check "${label}: навыки на месте (не меньше ${SKILLS_EXPECTED:-?}) и видны в сессии" \
        "запусти установщик снова: недостающие навыки докопируются в ${ws}/skills" \
        skills_ok "${ws}/skills" "${ws}/dashi-plugin-claude-code"
    check "${label}: сторож следит за агентом" \
        "добавь ${agent} в CHANNEL_AGENTS файла ${CONF} (или запусти установщик снова)" \
        listed_in "$agent" "${CHANNEL_AGENTS:-}"
}

# ws_files_ok <workspace> -- CLAUDE.md and core/rules.md are both there.
ws_files_ok() { [[ -f "${1}/CLAUDE.md" && -f "${1}/core/rules.md" ]]; }

section_server() {
    local guard_stop="${VAR_LIB}/${U}-guard/STOP"
    section "Сервер: правила, память, сторожа"
    check "У каждого агента свой бот (ни один бот не делят двое)" \
        "создай в @BotFather отдельного бота агенту, у которого токен совпал с чужим (урок docs/lesson-create-bots.md), впиши его токен и перезапусти этого агента" \
        bots_unique
    check "Стартовые правила агентов в общем CLAUDE.md" \
        "запусти установщик снова: он допишет блок стартовых правил в ${H}/.claude/CLAUDE.md (с копией)" \
        starter_ok "${H}/.claude/CLAUDE.md"
    check "Правило про пароли и доступы в общем CLAUDE.md" \
        "запусти установщик снова: он допишет блок в ${H}/.claude/CLAUDE.md" \
        has_all "${H}/.claude/CLAUDE.md" "<!-- red-secrets-rule:begin -->"
    check "Хуки защиты всех сессий (опасные команды, защита файлов)" \
        "запусти установщик снова: шаг хуков пишет ${H}/.claude/settings.json" \
        has_all "${H}/.claude/settings.json" block-dangerous.py protect-files.sh compact-open-items-reminder.py
    check "Ротация памяти по расписанию (crontab ${U})" \
        "запусти установщик снова; без sudo проверка не видит чужой crontab: ${SUDO_HINT}" \
        bash -c '[[ "$1" == *"memory rotation end"* ]]' _ "$(agent_crontab)"
    check "Ночной сброс сессий агентов" \
        "запусти установщик снова; если стоит стоп: rm ${H}/.claude-lab/shared/state/agents-reset/STOP" \
        cron_on "${U}-agents-reset" "${H}/.claude-lab/shared/state/agents-reset/STOP"
    check "Сторож агентов следит (раз в минуту)" \
        "запусти установщик снова; если стоит стоп: sudo rm ${guard_stop}" \
        cron_on "${U}-agents-guard" "$guard_stop"
    check "Сторож входа в Claude (раз в час)" \
        "запусти установщик снова; если стоит стоп: sudo rm ${VAR_LIB}/${U}-auth-watch/STOP" \
        cron_on "${U}-auth-watch" "${VAR_LIB}/${U}-auth-watch/STOP"
    check "Ночной бэкап памяти" \
        "запусти установщик снова; если стоит стоп: rm ${H}/backups/memory/STOP" \
        cron_on "${U}-memory-backup" "${H}/backups/memory/STOP"
    check "Заявки агентов на root (раз в минуту)" \
        "запусти установщик снова; если стоит стоп: sudo rm ${ETC}/${U}-root-requests.STOP" \
        cron_on "${U}-root-requests" "${ETC}/${U}-root-requests.STOP"
}

check_richard() {
    local env="${RICHARD_ENV:-/opt/richard/.env}" unit="${RICHARD_UNIT:-claude-richard}"
    section "Richard"
    BOT_FILES+=("Richard=${env}")
    check "Richard: сервис ${unit} работает" \
        "после входа в Claude: sudo systemctl restart ${unit}; причина: sudo journalctl -u ${unit} -n 50" \
        unit_active "$unit"
    check "Richard: свой бот отвечает Telegram (getMe)" \
        "впиши токен отдельного бота Richard в ${env} (TELEGRAM_BOT_TOKEN), урок docs/lesson-create-bots.md; без доступа ${SUDO_HINT}" \
        bot_ok "$env"
    check "Richard: владелец в списке доступа бота" \
        "твой id из @userinfobot в ALLOWED_USERS файла ${env}, затем sudo systemctl restart ${unit}" \
        owner_in "$env" ALLOWED_USERS
    check "Richard: общий CLAUDE.md на месте, файлы по ссылкам @ существуют" \
        "запусти установщик снова: он восстановит ${H}/.claude/CLAUDE.md" \
        at_paths_ok "${H}/.claude/CLAUDE.md"
}

check_auditor() {
    local bus="${H}/var/lib/auditor-bus"
    section "Auditor (Hermes)"
    BOT_FILES+=("Auditor=${HERMES_HOME}/.env")
    check "Auditor: сервис hermes-auditor работает" \
        "после входа ChatGPT (урок docs/lesson-auditor.md): sudo systemctl restart hermes-auditor; причина: sudo journalctl -u hermes-auditor -n 50" \
        unit_active hermes-auditor
    check "Auditor: вход ChatGPT сделан" \
        "войди своим ChatGPT по уроку docs/lesson-auditor.md (команда auth add openai-codex); без доступа ${SUDO_HINT}" \
        auditor_logged_in
    check "Auditor: свой бот отвечает Telegram (getMe)" \
        "впиши токен отдельного бота Auditor в ${HERMES_HOME}/.env (TELEGRAM_BOT_TOKEN) или запусти установщик с --stage intensive" \
        bot_ok "${HERMES_HOME}/.env"
    check "Auditor: владелец в списке доступа бота" \
        "твой id из @userinfobot в TELEGRAM_ALLOWED_USERS файла ${HERMES_HOME}/.env, затем sudo systemctl restart hermes-auditor" \
        owner_in "${HERMES_HOME}/.env" TELEGRAM_ALLOWED_USERS
    check "Auditor: роль SOUL.md и плагины проверки на месте" \
        "запусти установщик снова с --stage intensive" \
        bash -c '[[ -f "$1/SOUL.md" && -d "$1/plugins/factcheck" && -d "$1/plugins/secretguard" && -d "$1/plugins/readonly" ]]' _ "$HERMES_HOME"
    check "Auditor: сброс сессии аудитора по расписанию (250k, память сохраняется до сброса)" \
        "запусти установщик снова с --stage intensive; если стоит стоп: rm ${H}/.claude-lab/shared/state/hermes-auditor-reset/STOP" \
        cron_on "${U}-hermes-reset" "${H}/.claude-lab/shared/state/hermes-auditor-reset/STOP"
    check "Auditor: мост для задач от агентов работает" \
        "sudo systemctl restart hermes-auditor-bridge; если стоит стоп: rm ${bus}/STOP" \
        bash -c '[[ "$(systemctl is-active hermes-auditor-bridge 2>/dev/null)" == active && -d "$1/inbox" && ! -e "$1/STOP" ]]' _ "$bus"
}

check_editorial() {
    local conf="${H}/.claude-lab/shared/editorial.conf" en bin
    section "Редакционный контур"
    en=$(env_get "$conf" EDITORIAL_ENABLED)
    if [[ "$en" != 1 ]]; then
        printf '⏸ Редакционный контур: выключено (включается по уроку docs/lesson-editorial.md)\n'
        return 0
    fi
    bin=$(env_get "$conf" CODEX_CHECK_BIN)
    bin="${bin/#\~/$H}"
    check "Редакционный контур: навык codex-check на месте" \
        "запусти установщик снова или поправь CODEX_CHECK_BIN в ${conf}" \
        test -f "$bin"
    check "Редакционный контур: Codex установлен" \
        "установи Codex CLI по уроку docs/lesson-editorial.md или поставь EDITORIAL_ENABLED=0 в ${conf}" \
        bash -c 'command -v codex || [[ -x "$1/.local/bin/codex" ]]' _ "$H"
}

# --- run -------------------------------------------------------------------------------------------
printf 'Проверка этапа: %s (%s)\n' "$STAGE" \
    "$([[ "$STAGE" == intensive ]] && echo "Jarvis, Richard, Coder, Auditor" || echo "Jarvis, Richard")"

check_channel_agent jarvis Jarvis
check_richard
coder_here=0
[[ -n "$(env_get "${CR}/coder/channel.env" TELEGRAM_BOT_TOKEN)" ]] && coder_here=1
if [[ "$STAGE" == intensive || "$coder_here" == 1 ]]; then
    check_channel_agent coder Coder
fi
auditor_here=0
[[ -f "${HERMES_HOME}/.env" ]] && auditor_here=1
if [[ "$STAGE" == intensive || "$auditor_here" == 1 ]]; then
    check_auditor
fi
section_server
check_editorial

printf '\nИтог: %s ✅, %s ❌\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
    printf 'Почини строки с ❌ по подсказкам и запусти снова: sudo neurootdel-verify\n'
    exit 1
fi
printf 'Этап %s пройден и установлен полностью.\n' "$STAGE"
exit 0
