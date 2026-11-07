#!/usr/bin/env bash
# shellcheck disable=SC2016  # single-quoted bodies of the stub commands
# Tests for lib/verify-stage.sh (end-of-stage check), no root, no network:
#   a synthetic install (guard.conf, env files, workspaces, cron files, Hermes home) and stub
#   systemctl / curl / crontab on PATH. Green workshop and intensive, each broken item -> ❌ with a hint
#   and exit 1, the stage taken from guard.conf, editorial «выключено», tokens never in argv or output.
# Run: bash tests/test_verify_stage.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
V="${REPO}/lib/verify-stage.sh"
TDIR="$(mktemp -d)"
trap 'rm -rf "${TDIR:?}"' EXIT

PASS=0
FAIL=0
check() {
    local name=$1; shift
    if "$@"; then
        PASS=$((PASS + 1)); printf 'ok   %s\n' "$name"
    else
        FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$name" >&2
    fi
}
not() { ! "$@"; }

TOKEN_J="123456789:AAHabcdefghijklmnopqrstuvwxyz0123456"
TOKEN_R="222333444:RRHabcdefghijklmnopqrstuvwxyz0123456"
TOKEN_C="777888999:CCHabcdefghijklmnopqrstuvwxyz0123456"
TOKEN_A="444555666:AUDabcdefghijklmnopqrstuvwxyz0123456"
OWNER=555

# --- stubs ---------------------------------------------------------------------------------------
BIN="${TDIR}/bin"; mkdir -p "$BIN"
cat >"${BIN}/systemctl" <<EOF
#!/usr/bin/env bash
# is-active <unit>: active when the unit is listed in ${TDIR}/active
[[ "\$1" == is-active ]] || exit 1
if grep -qx -- "\$2" "${TDIR}/active" 2>/dev/null; then echo active; else echo inactive; exit 3; fi
EOF
cat >"${BIN}/curl" <<EOF
#!/usr/bin/env bash
# getMe stub: records argv and stdin; bots listed in ${TDIR}/dead_bots are refused
printf '%s\n' "\$*" >>"${TDIR}/curl.argv"
in=\$(cat); printf '%s\n' "\$in" >>"${TDIR}/curl.stdin"
id=\${in#*bot}; id=\${id%%:*}
if grep -qx -- "\$id" "${TDIR}/dead_bots" 2>/dev/null; then echo '{"ok":false}'; else echo '{"ok":true,"result":{"username":"b"}}'; fi
EOF
cat >"${BIN}/crontab" <<EOF
#!/usr/bin/env bash
cat "${TDIR}/crontab" 2>/dev/null
EOF
chmod +x "${BIN}"/*

# --- a synthetic green install -------------------------------------------------------------------
build() {
    rm -rf "${TDIR}/root"
    R="${TDIR}/root"; H="${R}/home/neurootdel"; CR="${R}/etc/vp"; LIB="${R}/lib"
    CRON="${R}/cron.d"; VARLIB="${R}/var/lib"; ETC="${R}/etc"
    mkdir -p "$H/.claude" "$CR/jarvis" "$CR/coder" "$LIB" "$CRON" "$VARLIB" "${R}/opt/richard"
    cat >"${LIB}/guard.conf" <<EOF
AGENT_USER="neurootdel"
AGENT_HOME="${H}"
CONFIG_ROOT="${CR}"
CHANNEL_AGENTS="jarvis"
OWNER_TG_ID="${OWNER}"
RICHARD_UNIT="claude-richard"
RICHARD_ENV="${R}/opt/richard/.env"
INSTALL_STAGE="${1:-workshop}"
SKILLS_EXPECTED="3"
EOF
    printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_ALLOWED_USER_IDS=%s,777\nTELEGRAM_ALLOWED_CHAT_IDS=%s\n' "$TOKEN_J" "$OWNER" "$OWNER" >"$CR/jarvis/channel.env"
    printf 'TELEGRAM_BOT_TOKEN=%s\nALLOWED_USERS=%s\n' "$TOKEN_R" "$OWNER" >"${R}/opt/richard/.env"
    printf '# global\n<!-- agent-rules-starter:begin -->\nrules\n<!-- red-secrets-rule:begin -->\n@~/.claude-lab/shared/team-rules.md\n' >"$H/.claude/CLAUDE.md"
    printf '{"hooks":"block-dangerous.py protect-files.sh compact-open-items-reminder.py"}\n' >"$H/.claude/settings.json"
    mkdir -p "$H/.claude-lab/shared"; echo team >"$H/.claude-lab/shared/team-rules.md"
    mkws jarvis
    for f in agents-reset agents-guard auth-watch memory-backup root-requests; do echo "* * * * * x" >"${CRON}/neurootdel-${f}"; done
    printf '# neurootdel-install v3: memory rotation\n0 4 * * * x\n# neurootdel-install memory rotation end\n' >"${TDIR}/crontab"
    printf 'claude-richard\nchannel-jarvis\n' >"${TDIR}/active"
    : >"${TDIR}/dead_bots"; : >"${TDIR}/curl.argv"; : >"${TDIR}/curl.stdin"
}
mkws() {
    local ws="$H/.claude-lab/$1/.claude" pl
    pl="${ws}/dashi-plugin-claude-code/plugin"
    mkdir -p "${ws}/core" "${pl}/.claude/rules" "${ws}/skills/a" "${ws}/skills/b" "${ws}/skills/c" "${ws}/dashi-plugin-claude-code/.claude"
    ln -sfn "${ws}/skills" "${ws}/dashi-plugin-claude-code/.claude/skills"
    printf '# %s\n@core/rules.md\n@~/.claude-lab/shared/team-rules.md\n' "$1" >"${ws}/CLAUDE.md"
    echo rules >"${ws}/core/rules.md"
    echo lp >"${pl}/.claude/rules/learned-practices.md"
    echo '{"x":"fact-check-gate.py correction-detector.py fallback-reply-hook.ts precompact-flush.sh learnings-engine.py"}' >"${pl}/.claude/settings.json"
}
mkcoder() {
    printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_ALLOWED_USER_IDS=%s\nTELEGRAM_ALLOWED_CHAT_IDS=%s\n' "$TOKEN_C" "$OWNER" "$OWNER" >"$CR/coder/channel.env"
    mkws coder
    sed -i 's/^CHANNEL_AGENTS=.*/CHANNEL_AGENTS="jarvis coder"/' "${LIB}/guard.conf"
    echo channel-coder >>"${TDIR}/active"
}
mkauditor() {
    local hh="$H/.hermes"
    mkdir -p "${hh}/plugins/factcheck" "${hh}/plugins/secretguard" "${hh}/plugins/readonly" "$H/var/lib/auditor-bus/inbox"
    printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_ALLOWED_USERS=%s\n' "$TOKEN_A" "$OWNER" >"${hh}/.env"
    echo soul >"${hh}/SOUL.md"
    echo '{"credential_pool":{"openai-codex":[{"refresh_token":"SECRET-REFRESH-XYZ"}]}}' >"${hh}/auth.json"
    printf 'hermes-auditor\nhermes-auditor-bridge\n' >>"${TDIR}/active"
    echo '# reset' >"${CRON}/neurootdel-hermes-reset"
}
run() {
    PATH="${BIN}:${PATH}" NEUROOTDEL_GUARD_CONF="${LIB}/guard.conf" VERIFY_CRON_DIR="$CRON" \
        VERIFY_VAR_LIB="$VARLIB" VERIFY_ETC="$ETC" bash "$V" "$@" >"${TDIR}/out" 2>&1 && RC=0 || RC=$?
}
out_has() { grep -qF -- "$1" "${TDIR}/out"; }
# fails_with <line text> -- that item is ❌ and a fix hint follows it
fails_with() { local a; a=$(grep -A1 -F -- "❌ $1" "${TDIR}/out"); [[ "$a" == *"как починить:"* ]]; }
# hint_has <line text> <word> -- the fix hint under that ❌ names the word
hint_has() { local a; a=$(grep -A1 -F -- "❌ $1" "${TDIR}/out"); [[ "$a" == *"$2"* ]]; }

# --- green workshop ------------------------------------------------------------------------------
build workshop
run
check "workshop green: exit 0"                 test "$RC" -eq 0
check "workshop green: no ❌"                  not grep -q "^❌" "${TDIR}/out"
check "workshop green: stage from guard.conf"  out_has "Проверка этапа: workshop"
check "workshop green: Jarvis service"         out_has "✅ Jarvis: сервис channel-jarvis работает"
check "workshop green: Richard bot getMe"      out_has "✅ Richard: свой бот отвечает Telegram (getMe)"
check "workshop green: memory rotation"        out_has "✅ Ротация памяти по расписанию"
check "workshop green: Coder not checked"      not out_has "Coder:"
check "workshop green: Auditor not checked"    not out_has "Auditor:"
check "editorial off: «выключено», not ❌"     out_has "⏸ Редакционный контур: выключено"
check "token: never in curl argv"              not grep -qE 'AAHabc|RRHabc' "${TDIR}/curl.argv"
check "token: went through stdin"              grep -q "bot${TOKEN_J}/getMe" "${TDIR}/curl.stdin"
check "token: never in the output"             not grep -qE 'AAHabc|RRHabc' "${TDIR}/out"

# --- each broken item -> ❌ + hint + exit 1 ---------------------------------------------------------
build; printf 'channel-jarvis\n' >"${TDIR}/active"; run
check "richard down: exit 1"                   test "$RC" -eq 1
check "richard down: ❌ with hint"             fails_with "Richard: сервис claude-richard работает"
build; echo "${TOKEN_J%%:*}" >"${TDIR}/dead_bots"; run
check "jarvis bot refused: ❌ with hint"       fails_with "Jarvis: свой бот отвечает Telegram (getMe)"
check "jarvis bot refused: hint names the lesson" hint_has "Jarvis: свой бот" lesson-create-bots.md
build; sed -i 's/^TELEGRAM_ALLOWED_USER_IDS=.*/TELEGRAM_ALLOWED_USER_IDS=777/' "$CR/jarvis/channel.env"; run
check "owner not in allowlist: ❌"             fails_with "Jarvis: владелец в списке доступа бота"
build; sed -i 's/^TELEGRAM_ALLOWED_USER_IDS=.*/TELEGRAM_ALLOWED_USER_IDS=5555/' "$CR/jarvis/channel.env"; run
check "allowlist: 5555 is not owner 555"       fails_with "Jarvis: владелец в списке доступа бота"
build; sed -i '/^TELEGRAM_ALLOWED_CHAT_IDS=/d' "$CR/jarvis/channel.env"; run
check "owner not in chat ids: ❌"              fails_with "Jarvis: владелец в списке доступа бота"
build; printf 'TELEGRAM_BOT_TOKEN=%s\nALLOWED_USERS=%s\n' "$TOKEN_J" "$OWNER" >"${R}/opt/richard/.env"; run
check "Richard on Jarvis's bot: ❌"           fails_with "У каждого агента свой бот"
check "shared bot: exit 1"                     test "$RC" -eq 1
build intensive; mkcoder; mkauditor; printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_ALLOWED_USERS=%s\n' "$TOKEN_C" "$OWNER" >"$H/.hermes/.env"; run
check "Auditor on Coder's bot: ❌"            fails_with "У каждого агента свой бот"
build; rm "$H/.claude-lab/shared/team-rules.md"; run
check "@ path missing: Jarvis ❌"              fails_with "Jarvis: файлы по ссылкам @ из CLAUDE.md существуют (загружаются)"
check "@ path missing: Richard ❌"             fails_with "Richard: общий CLAUDE.md на месте, файлы по ссылкам @ существуют"
build; rm "$H/.claude-lab/jarvis/.claude/core/rules.md"; run
check "rules missing: ❌"                      fails_with "Jarvis: рабочая папка, CLAUDE.md и правила на месте"
build; rm "$H/.claude-lab/jarvis/.claude/dashi-plugin-claude-code/plugin/.claude/rules/learned-practices.md"; run
check "learned-practices missing: ❌"          fails_with "Jarvis: практики learned-practices подключены"
build; echo '{}' >"$H/.claude-lab/jarvis/.claude/dashi-plugin-claude-code/plugin/.claude/settings.json"; run
check "plugin hooks off: ❌"                   fails_with "Jarvis: хуки включены"
build; echo '{}' >"$H/.claude/settings.json"; run
check "user hooks off: ❌"                     fails_with "Хуки защиты всех сессий"
build; rm -rf "$H/.claude-lab/jarvis/.claude/skills/c"; run
check "skills below expected: ❌"              fails_with "Jarvis: навыки на месте"
build; rm "$H/.claude-lab/jarvis/.claude/dashi-plugin-claude-code/.claude/skills"; run
check "skills not linked into session: ❌"     fails_with "Jarvis: навыки на месте"
build; sed -i '/agent-rules-starter/d' "$H/.claude/CLAUDE.md"; run
check "starter rules missing: ❌"              fails_with "Стартовые правила агентов в общем CLAUDE.md"
build; : >"${TDIR}/crontab"; run
check "memory rotation missing: ❌"            fails_with "Ротация памяти по расписанию"
build; mkdir -p "${VARLIB}/neurootdel-guard"; touch "${VARLIB}/neurootdel-guard/STOP"; run
check "guard stopped: ❌"                      fails_with "Сторож агентов следит"
build; rm "${CRON}/neurootdel-auth-watch"; run
check "auth watch missing: ❌"                 fails_with "Сторож входа в Claude"
build; mkdir -p "$H/backups/memory"; touch "$H/backups/memory/STOP"; run
check "backup stopped: ❌"                     fails_with "Ночной бэкап памяти"
build; touch "${ETC}/neurootdel-root-requests.STOP"; run
check "root requests stopped: ❌"              fails_with "Заявки агентов на root"
build; sed -i 's/^CHANNEL_AGENTS=.*/CHANNEL_AGENTS=""/' "${LIB}/guard.conf"; run
check "guard not watching Jarvis: ❌"          fails_with "Jarvis: сторож следит за агентом"

# --- intensive -----------------------------------------------------------------------------------
build intensive; run
check "intensive, nothing installed: exit 1"   test "$RC" -eq 1
check "intensive: Coder service ❌"            fails_with "Coder: сервис channel-coder работает"
check "intensive: Coder bot ❌"                fails_with "Coder: свой бот отвечает Telegram (getMe)"
check "intensive: Auditor login ❌"            fails_with "Auditor: вход ChatGPT сделан"
build intensive; mkcoder; mkauditor; run
check "intensive green: exit 0"                test "$RC" -eq 0
check "intensive green: no ❌"                 not grep -q "^❌" "${TDIR}/out"
check "intensive green: Auditor bridge"        out_has "✅ Auditor: мост для задач от агентов работает"
check "intensive green: Coder hooks"           out_has "✅ Coder: хуки включены"
check "intensive: login secret never printed"  not grep -q 'SECRET-REFRESH' "${TDIR}/out"
check "intensive: tokens never in argv"        not grep -qE 'CCHabc|AUDabc' "${TDIR}/curl.argv"
build intensive; mkcoder; mkauditor; echo '{"credential_pool":{}}' >"$H/.hermes/auth.json"; run
check "auditor not logged in: ❌"              fails_with "Auditor: вход ChatGPT сделан"
build intensive; mkcoder; mkauditor; sed -i '/hermes-auditor-bridge/d' "${TDIR}/active"; run
check "bridge down: ❌"                        fails_with "Auditor: мост для задач от агентов работает"
build intensive; mkcoder; mkauditor; rm "${CRON}/neurootdel-hermes-reset"; run
check "auditor reset cron missing: ❌"         fails_with "Auditor: сброс сессии аудитора по расписанию"
build intensive; mkcoder; mkauditor; mkdir -p "$H/.claude-lab/shared/state/hermes-auditor-reset"; touch "$H/.claude-lab/shared/state/hermes-auditor-reset/STOP"; run
check "auditor reset stopped: ❌"              fails_with "Auditor: сброс сессии аудитора по расписанию"
build intensive; mkcoder; mkauditor; sed -i 's/^CHANNEL_AGENTS=.*/CHANNEL_AGENTS="jarvis"/' "${LIB}/guard.conf"; run
check "guard not watching Coder: ❌"           fails_with "Coder: сторож следит за агентом"

# workshop server that already has a Coder bot: Coder is checked too; --stage overrides guard.conf
build workshop; mkcoder; run
check "workshop + Coder here: Coder checked"   out_has "✅ Coder: сервис channel-coder работает"
build workshop; run --stage intensive
check "--stage overrides guard.conf"           out_has "Проверка этапа: intensive"
run --stage big
check "wrong --stage: exit 2"                  test "$RC" -eq 2

# --- editorial on ----------------------------------------------------------------------------------
build; printf 'EDITORIAL_ENABLED=1\nCODEX_CHECK_BIN=~/nope.sh\n' >"$H/.claude-lab/shared/editorial.conf"; run
check "editorial on, skill missing: ❌"        fails_with "Редакционный контур: навык codex-check на месте"
build; printf 'EDITORIAL_ENABLED=1\nCODEX_CHECK_BIN=~/cc.sh\n' >"$H/.claude-lab/shared/editorial.conf"; echo x >"$H/cc.sh"
mkdir -p "$H/.local/bin"; printf '#!/bin/sh\n' >"$H/.local/bin/codex"; chmod +x "$H/.local/bin/codex"; run
check "editorial on, skill + codex: ✅"         out_has "✅ Редакционный контур: Codex установлен"

# --- no guard.conf ---------------------------------------------------------------------------------
OUT=$(PATH="${BIN}:${PATH}" NEUROOTDEL_GUARD_CONF="${TDIR}/none" bash "$V" 2>&1) && RC=0 || RC=$?
check "no guard.conf: exit 2"                  test "$RC" -eq 2
check "no guard.conf: says what to do"         grep -q 'Запусти установщик снова' <<<"$OUT"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
