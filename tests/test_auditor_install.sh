#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2329  # eval strings, globals read by sourced fns, overrides
# Tests for the optional Auditor (Hermes on GPT) of install.sh, no root and no Hermes needed:
#   token question and bot clash, install_auditor skip / full path (engine and CLI stubbed): role SOUL from the
#   template, .env (bot, owner, local api_server key), plugins copied and enabled, model on the ChatGPT login,
#   units + read-only drop-in + bridge unit; SOUL kept when the owner edited it; services started only after the
#   ChatGPT login; final notes; main order; guard watches the bridge; STAFF/TOOLS; the lesson text.
# Run: bash tests/test_auditor_install.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TDIR="$(mktemp -d)"
trap 'rm -rf "${TDIR:?}"' EXIT
export PYTHONDONTWRITEBYTECODE=1

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
has()   { grep -qxF -- "$2" "$1"; }
not()   { ! "$@"; }   # negation in THIS shell: sourced functions are not visible to a child bash -c
hasnt() { ! grep -qE -- "$2" "$1"; }

FAKE_HOME="${TDIR}/home"
mkdir -p "$FAKE_HOME" "${TDIR}/systemd" "${TDIR}/etc" "${TDIR}/lib"
sed -e "s#^readonly RICHARD_HOME=.*#readonly RICHARD_HOME=\"${TDIR}/richard\"#" \
    -e "s#/etc/systemd/system/#${TDIR}/systemd/#g" \
    "${REPO}/install.sh" >"${TDIR}/install.sh"

export INSTALL_SH_SOURCED_FOR_TESTING=1
export NEUROOTDEL_TEMPLATES_DIR="${REPO}/templates"
export NEUROOTDEL_INSTALLER_ROOT="$REPO"
# shellcheck disable=SC1091
source "${TDIR}/install.sh"
set +e
apply_install_names new
AGENT_HOME="$FAKE_HOME"
CONFIG_ROOT="${TDIR}/etc"
JARVIS_ENV_DIR="${CONFIG_ROOT}/jarvis"
CODER_ENV_DIR="${CONFIG_ROOT}/coder"
GUARD_LIB_DIR="${TDIR}/lib"
as_agent() { "$@"; }
fix_owner() { :; }
write_as_user() { mkdir -p "$(dirname "$2")"; cp "$1" "$2"; chmod "$3" "$2"; }
install() {    # drop -o/-g/-m: the sandbox user cannot chown to root
    local args=()
    while (($#)); do case $1 in -o|-g|-m) shift 2 ;; *) args+=("$1"); shift ;; esac; done
    command install "${args[@]}"
}
step() { :; }
OPERATOR_NAME="Анна"; OPERATOR_LANGUAGE="Russian"; OPERATOR_TIMEZONE="Asia/Bangkok"; TG_USER_ID="555"

TOKEN_J="123456789:AAHabcdefghijklmnopqrstuvwxyz0123456"
TOKEN_R="222333444:RRHabcdefghijklmnopqrstuvwxyz0123456"
TOKEN_C="777888999:CCHabcdefghijklmnopqrstuvwxyz0123456"
TOKEN_A="444555666:AUDabcdefghijklmnopqrstuvwxyz0123456"
HH="${FAKE_HOME}/.hermes"

# --- token question ----------------------------------------------------------------------------------
unset NEUROOTDEL_AUDITOR_BOT_TOKEN EDGELAB_AUDITOR_BOT_TOKEN
OUT=$( (NEUROOTDEL_NONINTERACTIVE=1 collect_auditor_input </dev/null) 2>&1; printf 'rc=%s' "$?")
check "input: unattended without env -> stop (bot required)" grep -q 'rc=1$' <<<"$OUT"
check "input: stop says Auditor needs its own bot"          grep -q 'Auditor needs its own bot' <<<"$OUT"
JARVIS_BOT_TOKEN="$TOKEN_J"; RICHARD_BOT_TOKEN="$TOKEN_R"; CODER_BOT_TOKEN="$TOKEN_C"
check "clash: Jarvis bot"      _auditor_bot_clash "${TOKEN_J%%:*}:XXXabcdefghijklmnopqrstuvwxyz0123456"
check "clash: Coder bot"       _auditor_bot_clash "$TOKEN_C"
check "clash: own bot is fine" not _auditor_bot_clash "$TOKEN_A"
OUT=$( (NEUROOTDEL_AUDITOR_BOT_TOKEN="$TOKEN_R" collect_auditor_input) 2>&1; printf 'rc=%s' "$?")
check "input: Richard's token refused" grep -q 'rc=1$' <<<"$OUT"
check "input: refusal says why"        grep -q 'SEPARATE bot' <<<"$OUT"
OUT=$( (NEUROOTDEL_AUDITOR_BOT_TOKEN="bad" collect_auditor_input) 2>&1; printf 'rc=%s' "$?")
check "input: bad format refused"      grep -q 'rc=1$' <<<"$OUT"

# --- install_auditor: no token -> clean skip ---------------------------------------------------------
AUDITOR_BOT_TOKEN=""; AUDITOR_INSTALLED=0
OUT=$(install_auditor 2>&1); RC=$?
check "skip: rc 0"                  test "$RC" -eq 0
check "skip: says how to add later" grep -q 'stage intensive' <<<"$OUT"
check "skip: no hermes home"        test ! -e "$HH"
check "skip: no unit"               test ! -e "${TDIR}/systemd/hermes-auditor.service"
check "skip: not marked installed"  test "$AUDITOR_INSTALLED" = 0

# --- install_auditor: full path, engine + CLI stubbed --------------------------------------------------
CALLS="${TDIR}/hermes.calls"; : >"$CALLS"
_install_hermes_engine() {
    mkdir -p "$(auditor_hermes_home)/hermes-agent/.hermes/bin"
    [[ -f "$(auditor_hermes_home)/SOUL.md" ]] || \
        printf 'You are Hermes Agent, built by Nous Research.\n' >"$(auditor_hermes_home)/SOUL.md"
}
_hermes() {
    printf '%s\n' "$*" >>"$CALLS"
    [[ "$*" == "config get model.provider" ]] && printf '%s\n' "${FAKE_PROVIDER:-auto}"
    return 0
}
AUDITOR_BOT_TOKEN="$TOKEN_A"
install_auditor >"${TDIR}/out1" 2>&1; RC=$?
check "full: rc 0"                    test "$RC" -eq 0
check "full: marked installed"        test "$AUDITOR_INSTALLED" = 1
S="${HH}/SOUL.md"
check "soul: engine default kept as .bak-install" grep -q 'Nous Research' "${S}.bak-install"
check "soul: role written"            grep -q '^# Аудитор AI-отдела' "$S"
check "soul: owner name filled"       grep -q 'владельца (Анна)' "$S"
check "soul: timezone filled"         grep -q '(Asia/Bangkok)' "$S"
check "soul: no placeholder left"     hasnt "$S" '\{\{'
check "soul: methodology sections"    bash -c 'for h in "## Факт, вывод, гипотеза, не проверено" "## Как проверяешь" "## Дефект и отчёт" "## Нельзя" "## Эскалация"; do grep -qxF "$h" "$1" || exit 1; done' _ "$S"
check "soul: mode 600"                test "$(stat -c '%a' "$S")" = 600
E="${HH}/.env"
check "env: bot token"                has "$E" "TELEGRAM_BOT_TOKEN=${TOKEN_A}"
check "env: owner only"               has "$E" "TELEGRAM_ALLOWED_USERS=555"
check "env: api key generated"        grep -qE '^API_SERVER_KEY=[0-9a-f]{64}$' "$E"
check "env: api on loopback"          has "$E" "API_SERVER_HOST=127.0.0.1"
check "env: api port"                 has "$E" "API_SERVER_PORT=8642"
check "env: mode 600"                 test "$(stat -c '%a' "$E")" = 600
check "env: token not in output"      bash -c "! grep -q AUDabc '${TDIR}/out1'"
for p in factcheck secretguard readonly; do
    check "plugin ${p}: copied"       test -f "${HH}/plugins/${p}/__init__.py" -a -f "${HH}/plugins/${p}/plugin.yaml"
    check "plugin ${p}: enabled"      has "$CALLS" "plugins enable ${p} --no-allow-tool-override"
done
check "plugins: no pycache copied"    test -z "$(find "${HH}/plugins" -name '__pycache__')"
check "config: provider openai-codex" has "$CALLS" "config set model.provider openai-codex"
check "config: default model"         has "$CALLS" "config set model.default ${AUDITOR_MODEL_DEFAULT}"
check "config: no interim messages"   has "$CALLS" "config set display.platforms.telegram.interim_assistant_messages false"
check "bus: folders"                  bash -c 'for d in inbox work done failed; do test -d "$1/$d" || exit 1; done' _ "${FAKE_HOME}/var/lib/auditor-bus"
# The read-only drop-in lists the engine state dirs with "-" (skipped when missing at unit start): on a clean
# server they must exist before the first start, or ProtectHome keeps them read-only and Telegram never connects.
check "state dirs: engine state exists before start" test -d "${FAKE_HOME}/.local/state/hermes"
check "state dirs: cache exists before start"        test -d "${FAKE_HOME}/.cache"
U="${TDIR}/systemd/hermes-auditor.service"
check "unit: written"                 test -f "$U"
check "unit: runs pinned binary"      has "$U" "ExecStart=\"${HH}/hermes-agent/.hermes/bin/hermes\" \"gateway\" \"run\""
check "unit: agent user"              has "$U" "User=${AGENT_USER}"
check "unit: hermes home"             has "$U" "Environment=\"HERMES_HOME=${HH}\""
check "unit: no placeholder"          hasnt "$U" '\{\{'
D="${TDIR}/systemd/hermes-auditor.service.d/10-readonly.conf"
check "dropin: home read-only"        has "$D" "ProtectHome=read-only"
check "dropin: role/env/config/plugins read-only" has "$D" "ReadOnlyPaths=${HH}/.env ${HH}/SOUL.md ${HH}/config.yaml ${HH}/plugins -${HH}/hermes-agent"
check "dropin: no placeholder"        hasnt "$D" '\{\{'
B="${TDIR}/systemd/hermes-auditor-bridge.service"
check "bridge unit: runs bridge"      has "$B" "ExecStart=/usr/bin/python3 ${GUARD_LIB_DIR}/auditor-bridge.py"
check "bridge unit: writes only bus"  has "$B" "ReadWritePaths=${FAKE_HOME}/var/lib/auditor-bus"
check "bridge unit: no placeholder"   hasnt "$B" '\{\{'

# --- re-run: owner edits kept, key kept, model the owner picked kept ---------------------------------------
KEY1=$(grep '^API_SERVER_KEY=' "$E")
printf '\nМоя правка роли.\n' >>"$S"
printf 'MY_OWN=1\n' >>"$E"
: >"$CALLS"; AUDITOR_BOT_TOKEN=""; AUDITOR_INSTALLED=0; FAKE_PROVIDER="openai-codex"
install_auditor >"${TDIR}/out2" 2>&1
check "rerun: still installed"        test "$AUDITOR_INSTALLED" = 1
check "rerun: owner's role kept"      grep -q 'Моя правка роли.' "$S"
check "rerun: new template beside"    test -f "${S}.new-install"
check "rerun: says where the new role is" grep -q 'SOUL.md.new-install' "${TDIR}/out2"
check "rerun: token kept"             has "$E" "TELEGRAM_BOT_TOKEN=${TOKEN_A}"
check "rerun: api key kept"           has "$E" "$KEY1"
check "rerun: own keys kept"          has "$E" "MY_OWN=1"
check "rerun: model not reset"        bash -c "! grep -q 'config set model' '$CALLS'"
: >"$CALLS"
NEUROOTDEL_AUDITOR_MODEL="gpt-x" install_auditor >/dev/null 2>&1
check "rerun: explicit model applied" has "$CALLS" "config set model.default gpt-x"
unset FAKE_PROVIDER
# kept token turned out to be the Jarvis bot: stop
printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TOKEN_J" >"${TDIR}/jenv"; mkdir -p "$JARVIS_ENV_DIR"; cp "${TDIR}/jenv" "${JARVIS_ENV_DIR}/channel.env"
sed -i "s/^TELEGRAM_BOT_TOKEN=.*/TELEGRAM_BOT_TOKEN=${TOKEN_J}/" "$E"
OUT=$( (install_auditor) 2>&1; printf 'rc=%s' "$?")
check "rerun: kept token = Jarvis bot -> stop" grep -q 'rc=1$' <<<"$OUT"
sed -i "s/^TELEGRAM_BOT_TOKEN=.*/TELEGRAM_BOT_TOKEN=${TOKEN_A}/" "$E"

# --- symlinks planted in the agent's home: nothing is read through them, nothing written -----------------------
printf 'ROOTSECRET\n' >"${TDIR}/rootfile"
cp -p "$E" "${E}.real"; rm -f "$E"; ln -s "${TDIR}/rootfile" "$E"
OUT=$( (AUDITOR_BOT_TOKEN="$TOKEN_A"; install_auditor) 2>&1; printf 'rc=%s' "$?")
check "symlink env: stops"            grep -q 'rc=1$' <<<"$OUT"
check "symlink env: target untouched" has "${TDIR}/rootfile" "ROOTSECRET"
check "symlink env: not copied anywhere" bash -c "! grep -rqs ROOTSECRET '$HH'"
rm -f "$E"; mv "${E}.real" "$E"
cp -p "$S" "${S}.real"; rm -f "$S"; ln -s "${TDIR}/rootfile" "$S"
OUT=$( (install_auditor) 2>&1; printf 'rc=%s' "$?")
check "symlink soul: stops"           grep -q 'rc=1$' <<<"$OUT"
check "symlink soul: target untouched" has "${TDIR}/rootfile" "ROOTSECRET"
rm -f "$S"; mv "${S}.real" "$S"

# --- engine pin: an existing checkout at another commit is left alone -----------------------------------
eval "$(sed -n '/^_install_hermes_engine() {/,/^}/p' "${REPO}/install.sh")"
mkdir -p "${HH}/hermes-agent/.hermes/bin"; printf '#!/bin/sh\n' >"${HH}/hermes-agent/.hermes/bin/hermes"; chmod +x "${HH}/hermes-agent/.hermes/bin/hermes"
as_agent() { case "$1" in git) printf 'deadbeef00000000000000000000000000000000\n' ;; *) "$@" ;; esac; }
curl() { printf 'curl %s\n' "$*" >>"${TDIR}/curl.calls"; return 1; }
OUT=$(_install_hermes_engine 2>&1); RC=$?
check "pin: other commit kept, rc 0"  test "$RC" -eq 0
check "pin: says it is left alone"    grep -q 'left as it is' <<<"$OUT"
check "pin: nothing downloaded"       test ! -e "${TDIR}/curl.calls"
as_agent() { case "$1" in git) printf '%s\n' "$HERMES_COMMIT" ;; *) "$@" ;; esac; }
OUT=$(_install_hermes_engine 2>&1)
check "pin: same commit -> ok"        grep -q 'already at' <<<"$OUT"
rm -f "${HH}/hermes-agent/.hermes/bin/hermes"
apt_install_missing() { :; }
OUT=$( (_install_hermes_engine) 2>&1; printf 'rc=%s' "$?")
check "pin: download failure stops"   grep -q 'rc=1$' <<<"$OUT"
check "pin: installer from the pinned commit" grep -q "raw.githubusercontent.com/NousResearch/hermes-agent/${HERMES_COMMIT}/scripts/install.sh" "${TDIR}/curl.calls"
curl() { local o=""; while (($#)); do [[ "$1" == "-o" ]] && o=$2; shift; done; printf 'evil\n' >"$o"; }
OUT=$( (_install_hermes_engine) 2>&1; printf 'rc=%s' "$?")
check "pin: checksum mismatch refused" grep -q 'checksum mismatch' <<<"$OUT"
unset -f curl
as_agent() { "$@"; }

# --- services: started only after the ChatGPT login ---------------------------------------------------
SCALLS="${TDIR}/systemctl.calls"; : >"$SCALLS"
systemctl() { printf '%s\n' "$*" >>"$SCALLS"; return 0; }
_retire_legacy_gateway() { return 0; }
RICHARD_BOT_TOKEN=""; CODER_INSTALLED=0; AUDITOR_INSTALLED=1
enable_services >/dev/null 2>&1
check "svc: auditor units enabled"    grep -qx 'enable hermes-auditor.service hermes-auditor-bridge.service --quiet' "$SCALLS"
check "svc: not started before login" bash -c "! grep -q 'restart hermes-auditor' '$SCALLS'"
printf '{"credential_pool":{"openai-codex":[{"id":"x"}]}}' >"${HH}/auth.json"
: >"$SCALLS"
enable_services >/dev/null 2>&1
check "svc: started after login"      grep -qx 'restart hermes-auditor.service hermes-auditor-bridge.service' "$SCALLS"
printf '{"credential_pool":{"openai-codex":[]}}' >"${HH}/auth.json"
check "login: empty pool = not logged in" not _auditor_logged_in
: >"$SCALLS"; AUDITOR_INSTALLED=0
enable_services >/dev/null 2>&1
check "svc: no auditor -> untouched"  bash -c "! grep -q hermes '$SCALLS'"

# --- final notes ---------------------------------------------------------------------------------------
AUDITOR_INSTALLED=1; AUDITOR_BOT_USERNAME="my_auditor_bot"
OUT=$(final_instructions 2>&1)
check "final: auditor line"           grep -q 'Auditor: .*hermes-auditor.*@my_auditor_bot' <<<"$OUT"
check "final: login command"          grep -qF "auth add openai-codex --type oauth --no-browser" <<<"$OUT"
check "final: device code hint"       grep -q 'device code authorization for Codex' <<<"$OUT"
check "final: ask command"            grep -qF "${GUARD_LIB_DIR}/auditor-ask.py --from jarvis" <<<"$OUT"
check "final: no token printed"       bash -c "! grep -q AUDabc <<<\"\$1\"" _ "$OUT"
AUDITOR_INSTALLED=0
OUT=$(final_instructions 2>&1)
check "final: how to add later"       grep -q 'Auditor:   not installed: intensive stage' <<<"$OUT"
check "final: no login step without it" bash -c "! grep -q 'auth add openai-codex' <<<\"\$1\"" _ "$OUT"

# --- wiring: main order, guard, team refs, lib scripts ---------------------------------------------------
check "main: install_auditor after guard + group watch" bash -c "grep -A2 '^    install_guard\$' '${REPO}/install.sh' | tail -n 1 | grep -qx '    install_auditor'"
check "inputs: auditor asked after coder"  bash -c "grep -A1 '^        collect_coder_input\$' '${REPO}/install.sh' | grep -qx '        collect_auditor_input'"
check "guard: watches the bridge unit"     grep -q '"hermes-auditor-bridge")' "${REPO}/lib/agents-guard.py"
check "staff: Auditor row"                 grep -q '^| Auditor | `auditor` |' "${REPO}/templates/shared/STAFF.md"
check "staff: how to ask the Auditor"      grep -qF '{{LIB}}/auditor-ask.py --from' "${REPO}/templates/shared/STAFF.md"
check "tools: auditor services"            grep -q '^| `hermes-auditor-bridge` |' "${REPO}/templates/shared/TOOLS.md"
check "lib: bridge compiles"               python3 -m py_compile "${REPO}/lib/auditor-bridge.py"
check "lib: ask compiles"                  python3 -m py_compile "${REPO}/lib/auditor-ask.py"
check "pin: installer sha is 64 hex"       grep -qE '^readonly HERMES_INSTALLER_SHA256="[0-9a-f]{64}"$' "${REPO}/install.sh"
check "pin: commit is 40 hex"              grep -qE '^readonly HERMES_COMMIT="[0-9a-f]{40}"$' "${REPO}/install.sh"

# --- templates and lesson: generic, plain Russian ---------------------------------------------------------
L="${REPO}/docs/lesson-auditor.md"
check "lesson: exists"                     test -s "$L"
check "lesson: no long dash"               bash -c '! grep -q "—" "$1"' _ "$L"
check "lesson: no 'не X, а Y'"             bash -c '! grep -qiE "(^|[^[:alpha:]])не [[:alpha:]]+( [[:alpha:]]+)?, а [[:alpha:]]|, а не " "$1"' _ "$L"
check "lesson: login step"                 grep -qF 'auth add openai-codex --type oauth --no-browser' "$L"
check "lesson: restart + check"            grep -qF 'systemctl is-active hermes-auditor hermes-auditor-bridge' "$L"
check "soul template: no long dash"        bash -c '! grep -q "—" "$1"' _ "${REPO}/templates/auditor-SOUL.md"
for f in "${REPO}/templates/auditor-SOUL.md" "$L" "${REPO}/templates/hermes-auditor.service" \
         "${REPO}/templates/hermes-auditor-bridge.service" "${REPO}/templates/hermes-auditor-readonly.conf"; do
    check "generic: $(basename "$f") has no names/servers" \
        bash -c '! grep -qE "Светлан|Николай|Юли[яи]|Владимир|Гостев|gosteva|147\.45\.|[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}" "$1"' _ "$f"
done

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
