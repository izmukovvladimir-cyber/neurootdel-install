#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2329  # eval strings, globals read by sourced fns, overrides
# Tests for the optional Coder agent of install.sh, no root needed:
#   token question and checks, channel.env (agent id, port), workspace from the coder templates,
#   install_coder skip / full path, guard.conf (CHANNEL_AGENTS, labels, gate self ids),
#   per-agent plugin hooks, memory rotation cron lines, skills copy, team refs, service enable,
#   and the bundled skill-finder.
# Run: bash tests/test_coder_install.sh
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
hasnt() { ! grep -qE -- "$2" "$1"; }
jqtrue() { jq -e "$2" "$1" >/dev/null 2>&1; }

FAKE_HOME="${TDIR}/home"
mkdir -p "$FAKE_HOME" "${TDIR}/systemd" "${TDIR}/etc" "${TDIR}/libexec"
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
CHANNEL_CONFIRM_BIN="${TDIR}/libexec/channel-confirm.sh"
CHANNEL_START_BIN="${TDIR}/libexec/channel-start.sh"
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

# --- channel.env: agent id and port ------------------------------------------------
E1="${TDIR}/env-coder"
CHANNEL_ENV_TOKEN="$TOKEN_C" CHANNEL_ENV_AGENT_ID=coder CHANNEL_ENV_PORT=8090 render_channel_env "" "555" "" /st /ws >"$E1"
check "env coder: agent id"            has "$E1" "AGENT_ID=coder"
check "env coder: own port"            has "$E1" "TELEGRAM_WEBHOOK_PORT=8090"
check "env coder: own token"           has "$E1" "TELEGRAM_BOT_TOKEN=${TOKEN_C}"
check "env coder: owner in both lists" bash -c "grep -qx 'TELEGRAM_ALLOWED_USER_IDS=555' '$E1' && grep -qx 'TELEGRAM_ALLOWED_CHAT_IDS=555' '$E1'"
check "env coder: header names its unit" grep -q 'restart channel-coder' "$E1"
check "env coder: header names Coder"  grep -q '^# Coder Telegram channel' "$E1"
E2="${TDIR}/env-jarvis"
CHANNEL_ENV_TOKEN="$TOKEN_J" render_channel_env "" "555" "" /st /ws >"$E2"
check "env jarvis: default id kept"    has "$E2" "AGENT_ID=jarvis"
check "env jarvis: default port kept"  has "$E2" "TELEGRAM_WEBHOOK_PORT=8089"
check "env jarvis: header unchanged"   grep -q '^# Jarvis Telegram channel' "$E2"
printf 'AGENT_ID=coder\nTELEGRAM_WEBHOOK_PORT=8095\n' >"${TDIR}/env-old"
CHANNEL_ENV_AGENT_ID=coder CHANNEL_ENV_PORT=8090 render_channel_env "${TDIR}/env-old" "" "" /st /ws >"${TDIR}/env-rerun"
check "env coder: re-run keeps owner port" has "${TDIR}/env-rerun" "TELEGRAM_WEBHOOK_PORT=8095"
check "env: bad agent id refused"  bash -c '! CHANNEL_ENV_AGENT_ID="co der" "$@" >/dev/null 2>&1' _ render_channel_env "" "" "" /st /ws
check "env: bad agent id refused (fn)" eval '! CHANNEL_ENV_AGENT_ID="x;y" render_channel_env "" "" "" /st /ws >/dev/null 2>&1'
check "env: bad port refused"          eval '! CHANNEL_ENV_PORT="80a" render_channel_env "" "" "" /st /ws >/dev/null 2>&1'

# --- coder templates: generic, every placeholder filled -----------------------------
check "tpl: coder CLAUDE.md exists"    test -f "${REPO}/templates/coder-CLAUDE.md"
check "tpl: coder rules exist"         test -f "${REPO}/templates/coder-rules.md"
check "tpl: coder unit exists"         test -f "${REPO}/templates/channel-coder.service"
PRIVATE='edgelab|Владимир|Vladimir|Светлан|Гостев|1815303740|348049383|gosteva|izmuk|([0-9]{1,3}\.){3}[0-9]{1,3}'
for f in coder-CLAUDE.md coder-rules.md channel-coder.service; do
    check "tpl: ${f} has no private names/ids/IPs" hasnt "${REPO}/templates/${f}" "$PRIVATE"
done
check "tpl: unit is all channel-coder" hasnt "${REPO}/templates/channel-coder.service" 'jarvis|Jarvis'

# --- workspace: coder kind ---------------------------------------------------------------
WS="${TDIR}/ws-coder"
_write_agent_workspace "$WS" coder
check "ws: CLAUDE.md from coder template" grep -q '^# Coder: технический специалист Анна' "${WS}/CLAUDE.md"
check "ws: owner timezone in CLAUDE.md" grep -q 'Asia/Bangkok' "${WS}/CLAUDE.md"
check "ws: config root in CLAUDE.md"   grep -q "${CONFIG_ROOT}/<агент>/channel.env" "${WS}/CLAUDE.md"
check "ws: rules from coder template"  grep -q '^# core/rules.md: рабочие правила Coder' "${WS}/core/rules.md"
check "ws: rules timezone filled"      grep -q 'TZ=Asia/Bangkok date' "${WS}/core/rules.md"
check "ws: rules restart via queue"    grep -q 'echo coder > /tmp/channel-restart-request' "${WS}/core/rules.md"
check "ws: no placeholder left"        bash -c "! grep -rq '{{' '${WS}/CLAUDE.md' '${WS}/core/rules.md'"
check "ws: includes resolve"           bash -c "for f in core/USER.md core/rules.md core/warm/decisions.md core/hot/handoff.md; do test -f '${WS}/'\$f || exit 1; done"
check "ws: USER.md has owner"          grep -q 'Анна' "${WS}/core/USER.md"
echo 'MY RULE' >>"${WS}/core/rules.md"
_write_agent_workspace "$WS" coder
check "ws: re-run keeps owner rules"   grep -q 'MY RULE' "${WS}/core/rules.md"
WSJ="${TDIR}/ws-jarvis"
_write_agent_workspace "$WSJ"
check "ws: jarvis default unchanged"   grep -q '^# My AI Agent (Jarvis)' "${WSJ}/CLAUDE.md"
check "ws: jarvis rules unchanged"     grep -q '^## One reply per question' "${WSJ}/core/rules.md"

# --- token question --------------------------------------------------------------------
tg_get_me() { printf '{"ok":true,"result":{"username":"my_coder_bot"}}'; }
OUT=$( (export NEUROOTDEL_NONINTERACTIVE=1; JARVIS_BOT_TOKEN="$TOKEN_J"; collect_coder_input; printf 'tok=[%s]' "$CODER_BOT_TOKEN") 2>&1; printf 'rc=%s' "$?" )
check "ask: unattended, no env -> stop (bot required)" grep -q 'rc=1$' <<<"$OUT"
check "ask: stop names the lesson"        grep -q 'lesson-create-bots.md' <<<"$OUT"
OUT=$( (export NEUROOTDEL_NONINTERACTIVE=1 NEUROOTDEL_CODER_BOT_TOKEN="$TOKEN_C"; JARVIS_BOT_TOKEN="$TOKEN_J"; RICHARD_BOT_TOKEN="$TOKEN_R"; collect_coder_input; printf 'tok=%s user=%s' "${CODER_BOT_TOKEN:0:9}" "$CODER_BOT_USERNAME") 2>&1 )
check "ask: env token taken"           grep -q 'tok=777888999 user=my_coder_bot' <<<"$OUT"
OUT=$( (export NEUROOTDEL_NONINTERACTIVE=1 NEUROOTDEL_CODER_BOT_TOKEN="$TOKEN_J"; JARVIS_BOT_TOKEN="$TOKEN_J"; collect_coder_input) 2>&1; printf 'rc=%s' "$?")
check "ask: same as Jarvis -> stop"    grep -q 'rc=1$' <<<"$OUT"
OUT=$( (export NEUROOTDEL_NONINTERACTIVE=1 NEUROOTDEL_CODER_BOT_TOKEN="$TOKEN_R"; JARVIS_BOT_TOKEN="$TOKEN_J"; RICHARD_BOT_TOKEN="$TOKEN_R"; collect_coder_input) 2>&1; printf 'rc=%s' "$?")
check "ask: same as Richard -> stop"   grep -q 'rc=1$' <<<"$OUT"
OUT=$( (export NEUROOTDEL_NONINTERACTIVE=1 NEUROOTDEL_CODER_BOT_TOKEN="nope"; collect_coder_input) 2>&1; printf 'rc=%s' "$?")
check "ask: bad format -> stop"        grep -q 'rc=1$' <<<"$OUT"
check "ask: token never echoed"        bash -c "! grep -q 'CCHabc' <<<\"\$1\"" _ "$OUT"
# re-run with empty answers: the bots already on the server still count (same id = same bot)
mkdir -p "$JARVIS_ENV_DIR" "${TDIR}/richard"
printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TOKEN_J" >"${JARVIS_ENV_DIR}/channel.env"
printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TOKEN_R" >"${TDIR}/richard/.env"
OUT=$( (export NEUROOTDEL_NONINTERACTIVE=1 NEUROOTDEL_CODER_BOT_TOKEN="${TOKEN_J%%:*}:ZZZabcdefghijklmnopqrstuvwxyz0123456"; JARVIS_BOT_TOKEN=""; RICHARD_BOT_TOKEN=""; collect_coder_input) 2>&1; printf 'rc=%s' "$?")
check "ask: Jarvis bot on server -> stop" grep -q 'rc=1$' <<<"$OUT"
OUT=$( (export NEUROOTDEL_NONINTERACTIVE=1 NEUROOTDEL_CODER_BOT_TOKEN="$TOKEN_R"; JARVIS_BOT_TOKEN=""; RICHARD_BOT_TOKEN=""; collect_coder_input) 2>&1; printf 'rc=%s' "$?")
check "ask: Richard bot on server -> stop" grep -q 'rc=1$' <<<"$OUT"
OUT=$( (export NEUROOTDEL_NONINTERACTIVE=1 NEUROOTDEL_CODER_BOT_TOKEN="$TOKEN_C"; JARVIS_BOT_TOKEN=""; RICHARD_BOT_TOKEN=""; collect_coder_input; printf 'rc=%s' "$?") 2>&1)
check "ask: own bot with others on server -> ok" grep -q 'rc=0$' <<<"$OUT"
rm -f "${JARVIS_ENV_DIR}/channel.env" "${TDIR}/richard/.env"
# getMe: the token goes to curl through stdin, never argv
BIN="${TDIR}/bin"; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s/getme.argv"\ncat >>"%s/getme.stdin"\nprintf "{\\"ok\\":true}"\n' "$TDIR" "$TDIR" >"${BIN}/curl"
chmod +x "${BIN}/curl"
OUT=$( eval "$(sed -n '/^tg_get_me() {/,/^}/p' "${REPO}/install.sh")"; PATH="${BIN}:${PATH}" tg_get_me "$TOKEN_C" )
check "getMe: answer passed through"   test "$OUT" = '{"ok":true}'
check "getMe: curl called"             test -s "${TDIR}/getme.argv"
check "getMe: token not in argv"       bash -c "! grep -q CCHabc '${TDIR}/getme.argv'"
check "getMe: token via stdin"         grep -q "^url = \"https://api.telegram.org/bot${TOKEN_C}/getMe\"$" "${TDIR}/getme.stdin"

# --- install_coder: no token -> clean skip ------------------------------------------------
CODER_BOT_TOKEN=""; CODER_INSTALLED=0
OUT=$(install_coder 2>&1); RC=$?
check "skip: rc 0"                     test "$RC" -eq 0
check "skip: says how to add later"    grep -q 'stage intensive' <<<"$OUT"
check "skip: no token in the hint"     bash -c "! grep -q 'TOKEN=<' <<<\"\$1\"" _ "$OUT"
check "skip: no workspace"             test ! -e "${FAKE_HOME}/.claude-lab/coder"
check "skip: no unit"                  test ! -e "${TDIR}/systemd/channel-coder.service"
check "skip: not marked installed"     test "$CODER_INSTALLED" = 0

# --- install_coder: with a token (git/bun stubbed) ---------------------------------------
PR="${FAKE_HOME}/.claude-lab/coder/.claude/dashi-plugin-claude-code"
mkdir -p "${PR}/.git" "${PR}/plugin/scripts" "${PR}/.claude"; printf '{}' >"${PR}/plugin/.mcp.json"
as_agent() { case "$1" in git) [[ " $* " == *" rev-parse "* ]] && printf '%s\n' "$PLUGIN_COMMIT_DEFAULT"; return 0 ;; env) return 0 ;; *) "$@" ;; esac; }
mkdir -p "${FAKE_HOME}/.claude-lab/shared/secrets"; printf 'gsk_shared\n' >"${FAKE_HOME}/.claude-lab/shared/secrets/groq-api-key"
CODER_BOT_TOKEN="$TOKEN_C"
install_coder >/dev/null 2>&1; RC=$?
CE="${CODER_ENV_DIR}/channel.env"
check "coder: rc 0"                    test "$RC" -eq 0
check "coder: marked installed"        test "$CODER_INSTALLED" = 1
check "coder: env token"               has "$CE" "TELEGRAM_BOT_TOKEN=${TOKEN_C}"
check "coder: env agent id"            has "$CE" "AGENT_ID=coder"
check "coder: env port 8090"           has "$CE" "TELEGRAM_WEBHOOK_PORT=8090"
check "coder: env owner only"          has "$CE" "TELEGRAM_PERMISSION_ALLOWED_USER_IDS=555"
check "coder: env groq from shared"    has "$CE" "GROQ_API_KEY=gsk_shared"
check "coder: own state dir"           has "$CE" "TELEGRAM_STATE_DIR=${FAKE_HOME}/.claude-lab/shared/state/coder/telegram"
check "coder: own workspace root"      has "$CE" "TELEGRAM_WORKSPACE_ROOT=${FAKE_HOME}/.claude-lab/coder/.claude"
check "coder: webhook token generated" grep -qE '^TELEGRAM_WEBHOOK_TOKEN=[0-9a-f]{48}$' "$CE"
check "coder: hud off in plugin config" jqtrue "${FAKE_HOME}/.claude-lab/shared/state/coder/telegram/config.json" '.hud.enabled == false and .webhook.enabled == true'
check "coder: workspace CLAUDE.md"     grep -q '^# Coder' "${FAKE_HOME}/.claude-lab/coder/.claude/CLAUDE.md"
U="${TDIR}/systemd/channel-coder.service"
check "coder: unit written"            test -f "$U"
check "coder: unit runs channel-coder" grep -q "^ExecStart=/bin/bash ${CHANNEL_START_BIN} channel-coder " "$U"
check "coder: unit env file"           has "$U" "EnvironmentFile=${CE}"
check "coder: unit cwd = coder plugin" has "$U" "WorkingDirectory=${PR}/plugin"
check "coder: unit no placeholder"     hasnt "$U" '\{\{'
check "coder: channel approved"        jqtrue "${PR}/.claude/settings.local.json" '.enabledMcpjsonServers | index("dashi-channel")'
check "coder: plugin trusted"          jqtrue "${FAKE_HOME}/.claude.json" ".projects[\"${PR}/plugin\"].hasTrustDialogAccepted == true"
check "coder: jarvis env untouched"    test ! -e "${JARVIS_ENV_DIR}/channel.env"
# re-run without an answer: the token already on the server keeps Coder installed
CODER_BOT_TOKEN=""; CODER_INSTALLED=0
install_coder >/dev/null 2>&1
check "rerun: still installed"         test "$CODER_INSTALLED" = 1
check "rerun: token kept"              has "$CE" "TELEGRAM_BOT_TOKEN=${TOKEN_C}"
# Coder token kept on the server is the Jarvis bot (owner moved it by hand): stop before a second poller
printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TOKEN_J" >"${JARVIS_ENV_DIR}/channel.env"
cp -p "$CE" "${CE}.keep"; sed -i "s/^TELEGRAM_BOT_TOKEN=.*/TELEGRAM_BOT_TOKEN=${TOKEN_J%%:*}:QQQabcdefghijklmnopqrstuvwxyz0123456/" "$CE"
OUT=$( (install_coder) 2>&1; printf 'rc=%s' "$?")
check "rerun: kept token = Jarvis bot -> stop" grep -q 'rc=1$' <<<"$OUT"
check "rerun: clash says why"          grep -q 'same bot as Jarvis or Richard' <<<"$OUT"
mv "${CE}.keep" "$CE"; rm -f "${JARVIS_ENV_DIR}/channel.env"
CODER_BOT_TOKEN="$TOKEN_C"

# --- guard.conf: Coder watched by the guard ------------------------------------------------
INSTALL_TAG=neurootdel-install
GC="${TDIR}/guard.conf"
CODER_INSTALLED=0; JARVIS_BOT_TOKEN="$TOKEN_J"; RICHARD_BOT_TOKEN="$TOKEN_R"
render_guard_conf "" >"$GC"
check "guard: no coder -> jarvis only" has "$GC" 'CHANNEL_AGENTS="jarvis"'
CODER_INSTALLED=1
render_guard_conf "" >"$GC"
check "guard: coder in CHANNEL_AGENTS" has "$GC" 'CHANNEL_AGENTS="jarvis coder"'
check "guard: coder label"             has "$GC" 'AGENT_LABELS="jarvis=Jarvis,coder=Coder"'
check "guard: coder bot is self"       has "$GC" 'FACT_GATE_SELF_IDS="123456789 777888999"'
render_guard_conf "$GC" >"${GC}.2"
check "guard: re-run no duplicates"    bash -c "grep -qx 'CHANNEL_AGENTS=\"jarvis coder\"' '${GC}.2' && grep -qx 'AGENT_LABELS=\"jarvis=Jarvis,coder=Coder\"' '${GC}.2' && grep -qx 'FACT_GATE_SELF_IDS=\"123456789 777888999\"' '${GC}.2'"
sed -i -e 's/^CHANNEL_AGENTS=.*/CHANNEL_AGENTS="jarvis analyst"/' -e 's/^AGENT_LABELS=.*/AGENT_LABELS="jarvis=Ника,analyst=Алан"/' "$GC"
render_guard_conf "$GC" >"${GC}.3"
check "guard: owner agents kept + coder" has "${GC}.3" 'CHANNEL_AGENTS="jarvis analyst coder"'
check "guard: owner labels kept + coder" has "${GC}.3" 'AGENT_LABELS="jarvis=Ника,analyst=Алан,coder=Coder"'
NEUROOTDEL_FACT_GATE_SELF_IDS="42" render_guard_conf "" >"${GC}.4"
check "guard: env self ids win"        has "${GC}.4" 'FACT_GATE_SELF_IDS="42"'
check "guard: python reads coder"      bash -c "NEUROOTDEL_GUARD_CONF='$GC.2' python3 -c 'import sys; sys.path.insert(0,\"${REPO}/lib\"); import guard_conf as g; c=g.load(); sys.exit(0 if c.channel_agents==[\"jarvis\",\"coder\"] and c.label(\"coder\")==\"Coder\" and c.main_agent==\"jarvis\" else 1)'"

# --- per-agent plugin hooks ------------------------------------------------------------------
PJ="${FAKE_HOME}/.claude-lab/jarvis/.claude/dashi-plugin-claude-code/plugin"
mkdir -p "$PJ" "${FAKE_HOME}/.claude"
mkdir -p "$JARVIS_ENV_DIR"; printf 'TELEGRAM_WEBHOOK_PORT=8089\n' >"${JARVIS_ENV_DIR}/channel.env"
CODER_INSTALLED=1
setup_agent_hooks >/dev/null 2>&1; RC=$?
CS="${PR}/plugin/.claude/settings.json"
JS="${PJ}/.claude/settings.json"
check "hooks: rc 0"                     test "$RC" -eq 0
check "hooks: coder auto-recall"        jqtrue "$CS" '[.hooks.UserPromptSubmit[].hooks[].command] | any(endswith("auto-recall.py coder"))'
check "hooks: coder correction ws"      jqtrue "$CS" "[.hooks.UserPromptSubmit[].hooks[].command] | any(. == \"python3 ${GUARD_LIB_DIR}/hooks/correction-detector.py ${FAKE_HOME}/.claude-lab/coder/.claude\")"
check "hooks: coder fact gate own state" jqtrue "$CS" "[.hooks.PreToolUse[].hooks[].command] | any(endswith(\"shared/state/coder/factcheck\"))"
check "hooks: coder fallback port 8090" jqtrue "$CS" '[.hooks.Stop[].hooks[].command] | any(contains("127.0.0.1:8090/hooks/fallback-reply"))'
check "hooks: coder lessons at start"   jqtrue "$CS" '[.hooks.SessionStart[].hooks[].command] | any(contains("learnings-engine.py") and contains("/coder/.claude top"))'
check "hooks: coder precompact flush"   jqtrue "$CS" '[.hooks.PreCompact[].hooks[].command] | any(endswith("precompact-flush.sh coder"))'
check "hooks: jarvis still jarvis"      jqtrue "$JS" '[.hooks.UserPromptSubmit[].hooks[].command] | any(endswith("auto-recall.py jarvis"))'
check "hooks: jarvis fallback port 8089" jqtrue "$JS" '[.hooks.Stop[].hooks[].command] | any(contains("127.0.0.1:8089/hooks/fallback-reply"))'
setup_agent_hooks >/dev/null 2>&1
check "hooks: re-run no duplicates"     jqtrue "$CS" '[.hooks.UserPromptSubmit[].hooks[].command] | length == 3'
rm -rf "${PR}/plugin.moved"; mv "${PR}/plugin" "${PR}/plugin.moved"
OUT=$(setup_agent_hooks 2>&1); RC=$?
check "hooks: coder plugin missing -> fail" test "$RC" -ne 0
check "hooks: names the coder"          grep -q 'coder hooks NOT set' <<<"$OUT"
mv "${PR}/plugin.moved" "${PR}/plugin"

# --- memory rotation cron ---------------------------------------------------------------------
CRONF="${TDIR}/crontab"; : >"$CRONF"
crontab() { if [[ "$3" == -l ]]; then cat "$CRONF"; else cp "$3" "$CRONF"; fi; }
systemctl() { :; }
CODER_INSTALLED=1
install_memory_cron >/dev/null 2>&1; RC=$?
check "cron: rc 0"                      test "$RC" -eq 0
check "cron: jarvis job kept"           grep -q "^30 4 \* \* \* ${FAKE_HOME}/.claude-lab/jarvis/scripts/rotate-warm.sh" "$CRONF"
check "cron: coder 4 jobs"              test "$(grep -c "AGENT_WS=${FAKE_HOME}/.claude-lab/coder/.claude " "$CRONF")" -eq 4
check "cron: coder log dir made"        test -d "${FAKE_HOME}/.claude-lab/coder/logs"
check "cron: coder inside the block"    bash -c "awk '/memory rotation\$/{a=1} /memory rotation end/{a=0} a' '$CRONF' | grep -c AGENT_WS= | grep -qx 4"
check "cron: block ends with marker"    bash -c "tail -n1 '$CRONF' | grep -q 'memory rotation end'"
check "cron: no blank line in block"    bash -c "! grep -qx '' '$CRONF'"
install_memory_cron >/dev/null 2>&1
check "cron: re-run one block"          test "$(grep -c 'memory rotation end' "$CRONF")" -eq 1
CODER_INSTALLED=0
install_memory_cron >/dev/null 2>&1
check "cron: no coder -> no coder jobs" bash -c "! grep -q AGENT_WS= '$CRONF'"
unset -f crontab

# --- skills: same set for Coder, skill-finder bundled ------------------------------------------
check "skills: skill-finder in the list" bash -c 'printf "%s\n" "$@" | grep -qx skill-finder' _ "${SKILLS_FROM_INSTALLER[@]}"
check "skills: skill-finder bundled"    test -f "${REPO}/skills/skill-finder/SKILL.md"
check "skills: skill-finder frontmatter" grep -qx 'name: skill-finder' "${REPO}/skills/skill-finder/SKILL.md"
TPL="${TDIR}/tpl"; mkdir -p "${TPL}/skills"
for s in "${SKILLS_FROM_TEMPLATE[@]}"; do mkdir -p "${TPL}/skills/${s}"; printf -- '---\nname: %s\n---\n' "$s" >"${TPL}/skills/${s}/SKILL.md"; done
fetch_template() { printf '%s' "$TPL"; }
CODER_INSTALLED=1
OUT=$(install_skills 2>&1)
JSK="${FAKE_HOME}/.claude-lab/jarvis/.claude/skills"
CSK="${FAKE_HOME}/.claude-lab/coder/.claude/skills"
check "skills: jarvis 12/12"            grep -q '(12/12)' <<<"$OUT"
check "skills: jarvis has skill-finder" test -f "${JSK}/skill-finder/SKILL.md"
check "skills: coder copy 12"           grep -q 'Coder skills: 12 copied, 0 already there' <<<"$OUT"
check "skills: coder has skill-finder"  test -f "${CSK}/skill-finder/SKILL.md"
check "skills: coder copy is a copy"    test ! -L "${CSK}/present"
check "skills: coder plugin linked"     test "$(readlink "${PR}/.claude/skills")" = "$CSK"
echo 'OWNER EDIT' >>"${CSK}/present/SKILL.md"; echo 'mine' >"${CSK}/present/extra.txt"
OUT=$(install_skills 2>&1)
check "skills: re-run keeps coder edits" bash -c "grep -q 'OWNER EDIT' '${CSK}/present/SKILL.md' && test -f '${CSK}/present/extra.txt'"
check "skills: re-run reports kept"     grep -q 'Coder skills: 0 copied, 12 already there' <<<"$OUT"
CODER_INSTALLED=0; rm -rf "${CSK:?}"
install_skills >/dev/null 2>&1
check "skills: no coder -> no copy"     test ! -e "$CSK"

# --- team refs: coder gets team rules and the memory layout --------------------------------------
CODER_INSTALLED=1
mkdir -p "${FAKE_HOME}/.claude-lab/jarvis/.claude"; cp "${WSJ}/CLAUDE.md" "${FAKE_HOME}/.claude-lab/jarvis/.claude/CLAUDE.md"
install_team_refs >/dev/null 2>&1; RC=$?
CMEM="${FAKE_HOME}/.claude/projects/$(printf '%s' "${PR}" | sed 's/[^A-Za-z0-9]/-/g')/memory"
check "refs: rc 0"                      test "$RC" -eq 0
check "refs: coder team-rules @"        grep -q '^@~/.claude-lab/shared/team-rules.md$' "${FAKE_HOME}/.claude-lab/coder/.claude/CLAUDE.md"
check "refs: coder auto-memory index"   test -f "${CMEM}/MEMORY.md"
check "refs: coder library index"       test -f "${FAKE_HOME}/.claude-lab/coder/.claude/library/INDEX.md"
check "refs: coder archive dir"         test -d "${FAKE_HOME}/.claude-lab/coder/.claude/core/archive"
check "refs: STAFF names Coder"         grep -q '| Coder | `coder` |' "${FAKE_HOME}/.claude-lab/shared/STAFF.md"
install_team_refs >/dev/null 2>&1
check "refs: re-run one marker block"   test "$(grep -c 'BEGIN neurootdel-install: team-rules' "${FAKE_HOME}/.claude-lab/coder/.claude/CLAUDE.md")" -eq 1

# --- services: Coder enabled and started like Jarvis -----------------------------------------------
CALLS="${TDIR}/calls"; : >"$CALLS"
systemctl() { printf '%s\n' "$*" >>"$CALLS"; return 0; }
_retire_legacy_gateway() { return 0; }
printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TOKEN_J" >"${JARVIS_ENV_DIR}/channel.env"
printf '{}' >"${FAKE_HOME}/.claude/.credentials.json"
CODER_INSTALLED=1; RICHARD_BOT_TOKEN=""
enable_services >/dev/null 2>&1
check "svc: coder enabled"              grep -qx 'enable channel-coder.service --quiet' "$CALLS"
check "svc: coder restarted"            grep -qx 'restart channel-coder.service' "$CALLS"
: >"$CALLS"; CODER_INSTALLED=0
enable_services >/dev/null 2>&1
check "svc: no coder -> untouched"      bash -c "! grep -q channel-coder '$CALLS'"
rm -f "${FAKE_HOME}/.claude/.credentials.json"

# --- final notes ------------------------------------------------------------------------------------
CODER_INSTALLED=1; CODER_BOT_USERNAME="my_coder_bot"
OUT=$(final_instructions 2>&1)
check "final: coder line"               grep -q 'Coder: .*channel-coder.*@my_coder_bot' <<<"$OUT"
check "final: login watch stop"         grep -q 'auth-watch/STOP' <<<"$OUT"
check "final: restart includes coder"   grep -q 'sudo systemctl restart channel-jarvis channel-coder claude-richard' <<<"$OUT"
check "final: smoke-check coder"        grep -q 'systemctl is-active channel-coder' <<<"$OUT"
CODER_INSTALLED=0
OUT=$(final_instructions 2>&1)
check "final: how to add coder later"   grep -q 'Coder:     not installed: intensive stage' <<<"$OUT"
check "final: no coder -> plain restart" grep -q 'sudo systemctl restart channel-jarvis claude-richard' <<<"$OUT"

# --- main: Coder right after Jarvis -------------------------------------------------------------------
check "main: install_coder after install_jarvis" bash -c "grep -A1 '^    install_jarvis\$' '${REPO}/install.sh' | grep -qx '    install_coder'"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
