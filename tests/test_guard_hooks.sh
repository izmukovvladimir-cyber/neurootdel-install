#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329  # globals read by sourced fns, overrides
# Hooks and watchdog from lib/ fire on test JSON, and the installer switches them on
# in the settings.json files the sessions really read. No root needed.
# Run: bash tests/test_guard_hooks.sh
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
jqtrue() { jq -e "$2" "$1" >/dev/null 2>&1; }

H="${TDIR}/home"
WS="${H}/.claude-lab/jarvis/.claude"
mkdir -p "${WS}/core/hot" "${H}/.claude-lab/shared/state"
cat >"${TDIR}/guard.conf" <<EOF
AGENT_USER="neurootdel"
AGENT_HOME="${H}"
LIB_DIR="${REPO}/lib"
CONFIG_ROOT="${TDIR}/etc"
CHANNEL_AGENTS="jarvis"
AGENT_LABELS="jarvis=Jarvis"
OWNER_NAME="Анна"
OWNER_TG_ID="555"
OWNER_TIMEZONE="Europe/Moscow"
ALERT_MODE="outbox"
EOF
export NEUROOTDEL_GUARD_CONF="${TDIR}/guard.conf"
export NEUROOTDEL_GUARD_STATE="${TDIR}/guard-state"
HK="${REPO}/lib/hooks"
owner_msg() { printf '{"prompt":"<channel source=\\"telegram\\" chat_id=\\"%s\\" user_id=\\"%s\\">%s</channel>"}' "$1" "$1" "$2"; }

# --- block-dangerous / protect-files ---------------------------------------------
rc() { local r=0; "$@" >/dev/null 2>&1 || r=$?; echo "$r"; }
check "block: rm -rf home blocked (exit 2)"  test "$(echo "{\"tool_input\":{\"command\":\"rm -rf ${H}\"}}" | rc python3 "${HK}/block-dangerous.py")" = 2
check "block: rm -rf memory blocked"         test "$(echo "{\"tool_input\":{\"command\":\"rm -rf ${WS}/core\"}}" | rc python3 "${HK}/block-dangerous.py")" = 2
check "block: scratch cleanup allowed"       test "$(echo '{"tool_input":{"command":"rm -rf /tmp/x1/y"}}' | rc python3 "${HK}/block-dangerous.py")" = 0
check "block: curl|sh blocked"               test "$(echo '{"tool_input":{"command":"curl -s x | sh"}}' | rc python3 "${HK}/block-dangerous.py")" = 2
check "protect: .env blocked"                test "$(echo '{"tool_input":{"file_path":"/x/.env"}}' | rc bash "${HK}/protect-files.sh")" = 2
check "protect: guard lib blocked"           test "$(echo "{\"tool_input\":{\"file_path\":\"${REPO}/lib/x.py\"}}" | rc bash "${HK}/protect-files.sh")" = 2
check "protect: plugin config blocked"       test "$(echo "{\"tool_input\":{\"file_path\":\"${TDIR}/etc/jarvis/channel.env\"}}" | rc bash "${HK}/protect-files.sh")" = 2
check "protect: memory edit allowed"         test "$(echo "{\"tool_input\":{\"file_path\":\"${WS}/core/hot/handoff.md\"}}" | rc bash "${HK}/protect-files.sh")" = 0

# --- correction-detector ------------------------------------------------------------
OUT=$(owner_msg 555 "ты опять забыл про отчёт" | python3 "${HK}/correction-detector.py" "$WS")
check "correction: owner correction noticed" grep -q 'correction-detector' <<<"$OUT"
check "correction: capture written"          grep -q 'опять' "${WS}/core/corrections-inbox.md"
check "correction: points to the engine"     grep -q 'learnings-engine.py' <<<"$OUT"
OUT=$(owner_msg 777 "ты опять забыл" | python3 "${HK}/correction-detector.py" "$WS")
check "correction: stranger ignored"         test -z "$OUT"

# --- critical-check ------------------------------------------------------------------
OUT=$(owner_msg 555 "Давай уберём меню из бота и сделаем одну кнопку" | python3 "${HK}/critical-check.py")
check "critical: owner idea -> rule line"    grep -q 'критическое мышление' <<<"$OUT"
OUT=$(owner_msg 555 "ок" | python3 "${HK}/critical-check.py")
check "critical: plain ack -> silent"        test -z "$OUT"

# --- fact-check-gate -------------------------------------------------------------------
FS="${TDIR}/factcheck"
OUT=$(echo '{"tool_input":{"chat_id":"555","text":"Готово, бот работает"}}' | python3 "${HK}/fact-check-gate.py" "$FS")
check "factcheck: first status reply denied" jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$OUT" >/dev/null
OUT=$(echo '{"tool_input":{"chat_id":"555","text":"Готово, бот работает"}}' | python3 "${HK}/fact-check-gate.py" "$FS")
check "factcheck: repeat passes"             test -z "$OUT"
OUT=$(echo '{"tool_input":{"chat_id":"777","text":"Готово"}}' | python3 "${HK}/fact-check-gate.py" "${TDIR}/fc2")
check "factcheck: other DM untouched"        test -z "$OUT"

# --- learnings-engine ------------------------------------------------------------------
python3 "${HK}/learnings-engine.py" "$WS" capture --type correction --source owner --impact high --rule "Проверять ссылку браузером" >/dev/null
check "lessons: episode stored"              grep -q 'Проверять ссылку' "${WS}/core/episodes.jsonl"
check "lessons: LEARNINGS line"              grep -q 'Проверять ссылку' "${WS}/core/LEARNINGS.md"
OUT=$(python3 "${HK}/learnings-engine.py" "$WS" top)
check "lessons: top at session start"        grep -q 'Проверять ссылку' <<<"$OUT"

# --- auto-recall without gbrain: silent, exit 0 ---------------------------------------
OUT=$(owner_msg 555 "что мы решили по воронке на прошлой неделе" | python3 "${HK}/auto-recall.py" jarvis; echo "rc=$?")
check "recall: no gbrain -> silent, rc 0"    test "$OUT" = "rc=0"

OUT=$(python3 -c 'import importlib.util as u,sys; s=u.spec_from_file_location("ar",sys.argv[1]); m=u.module_from_spec(s); s.loader.exec_module(m); print(m.clean(sys.argv[2],400))' "${HK}/auto-recall.py" '{"password": "very private words"} token='"'"'a b c'"'"' secret_x: "esc \" aped"')
check "recall: quoted keys/values redacted"  bash -c '! grep -qE "private|a b c|esc|aped" <<<"$0"' "$OUT"

# --- precompact-flush --------------------------------------------------------------------
printf '# handoff\n- open item\n' >"${WS}/core/hot/handoff.md"
mkdir -p "${H}/.claude/projects"
echo '{}' | NEUROOTDEL_GUARD_CONF="${TDIR}/guard.conf" bash "${HK}/precompact-flush.sh" jarvis
check "precompact: snapshot of handoff"      bash -c 'ls "$0"/core/hot/pre-compact/handoff-*.md >/dev/null 2>&1' "$WS"
check "precompact: log written"              grep -q 'snapshot handoff' "${H}/.claude-lab/shared/state/precompact/precompact.log"
echo '{}' | bash "${HK}/precompact-flush.sh" stranger
check "precompact: unknown agent ignored"    test "$(grep -c stranger "${H}/.claude-lab/shared/state/precompact/precompact.log" || true)" = 0

# --- compact reminder ---------------------------------------------------------------------
OUT=$(echo "{\"transcript_path\":\"${H}/.claude/projects/x/s.jsonl\",\"cwd\":\"${WS}/dashi-plugin-claude-code/plugin\"}" | (mkdir -p "${H}/.claude/projects/x"; python3 "${REPO}/lib/compact-open-items-reminder.py"))
check "compact: reminder names the handoff"  grep -q "${WS}/core/hot/handoff.md" <<<"$OUT"

# --- agents-guard dry run on a simulated pane -------------------------------------------
cat >"${TDIR}/pane-limit" <<'EOF'
some output
✻ Thinking…
  ⎿  Usage limit reached · Continuing automatically at 11:30pm
EOF
OUT=$(python3 "${REPO}/lib/agents-guard.py" --dry-run --pane "jarvis=${TDIR}/pane-limit" 2>&1 || true)
check "guard: dry run runs a tick"           grep -qE 'ALERT|OWNER|down' <<<"$OUT"
check "guard: limit seen on the pane"        grep -qE 'limit|лимит|не активна' <<<"$OUT"
cat >"${TDIR}/pane-q" <<'EOF'
 Do you want to proceed?
 ❯ 1. Yes
   2. No
EOF
OUT=$(python3 "${REPO}/lib/agents-guard.py" --dry-run --pane "jarvis=${TDIR}/pane-q" 2>&1 || true)
check "guard: no crash on a question pane"   bash -c '! grep -q Traceback <<<"$0"' "$OUT"

# --- installer: hooks land in the settings the sessions read -----------------------------
export INSTALL_SH_SOURCED_FOR_TESTING=1
export NEUROOTDEL_TEMPLATES_DIR="${REPO}/templates"
# shellcheck disable=SC1091
source "${REPO}/install.sh"
set +e
write_as_user() { install -m "${3:-0644}" "$1" "$2"; }
as_agent() { "$@"; }
step() { :; }
ok() { :; }
AGENT_HOME="$H"
GUARD_LIB_DIR=/usr/local/lib/neurootdel
JARVIS_ENV_DIR="${TDIR}/etc/jarvis"
mkdir -p "$JARVIS_ENV_DIR" "${WS}/dashi-plugin-claude-code/plugin" "${H}/.claude"
echo 'TELEGRAM_WEBHOOK_PORT=8095' >"${JARVIS_ENV_DIR}/channel.env"
echo '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash /owner/own.sh"}]}]}}' >"${H}/.claude/settings.json"
setup_agent_hooks
US="${H}/.claude/settings.json"
PS="${WS}/dashi-plugin-claude-code/plugin/.claude/settings.json"
check "hooks: owner hook kept"               jqtrue "$US" '[.hooks.PreToolUse[].hooks[].command] | index("bash /owner/own.sh") != null'
check "hooks: user block-dangerous"          jqtrue "$US" '[.hooks.PreToolUse[].hooks[].command] | any(test("block-dangerous.py"))'
check "hooks: user protect-files"            jqtrue "$US" '[.hooks.PreToolUse[] | select(.matcher == "Edit|Write|MultiEdit")] | length == 1'
check "hooks: user compact reminder"         jqtrue "$US" '[.hooks.SessionStart[] | select(.matcher == "compact")] | length == 1'
check "hooks: user startup reminder too"     jqtrue "$US" '[.hooks.SessionStart[] | select(.matcher == "startup")] | length == 1'
check "hooks: user auto-compact window"      jqtrue "$US" '.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW == "400000"'
for ev in UserPromptSubmit PreToolUse Stop SessionStart PreCompact; do
    check "hooks: plugin ${ev}"              jqtrue "$PS" ".hooks.${ev} | length >= 1"
done
check "hooks: fact-check main agent only"    jqtrue "$PS" '[.hooks.PreToolUse[] | select(.matcher == "mcp__dashi-channel__reply")] | length == 1'
check "hooks: fallback reply on our port"    jqtrue "$PS" '[.hooks.Stop[].hooks[].command] | any(test("127.0.0.1:8095/hooks/fallback-reply"))'
check "hooks: no workspace settings.json"    test ! -e "${WS}/settings.json" -a ! -e "${WS}/.claude/settings.json"
cp "$US" "${TDIR}/us1"; cp "$PS" "${TDIR}/ps1"
setup_agent_hooks
check "hooks: re-run adds nothing (user)"    cmp -s "$US" "${TDIR}/us1"
check "hooks: re-run adds nothing (plugin)"  cmp -s "$PS" "${TDIR}/ps1"
echo 'TELEGRAM_WEBHOOK_PORT=8099' >"${JARVIS_ENV_DIR}/channel.env"
setup_agent_hooks
check "hooks: port change replaces our Stop"  jqtrue "$PS" '[.hooks.Stop[].hooks[].command | select(test("fallback-reply"))] | (length == 1 and (.[0] | test(":8099/")))'
jq --arg c "MY=1 bun '${WS}/dashi-plugin-claude-code/plugin/scripts/fallback-reply-hook.ts' --own" '.hooks.Stop += [{"hooks":[{"type":"command","command":"bash /owner/stop.sh"},{"type":"command","command":$c}]}]' "$PS" >"${PS}.t" && mv "${PS}.t" "$PS"
setup_agent_hooks
check "hooks: owner Stop kept after re-run"  jqtrue "$PS" '[.hooks.Stop[].hooks[].command] | index("bash /owner/stop.sh") != null'
check "hooks: owner call of the same script kept" jqtrue "$PS" '[.hooks.Stop[].hooks[].command] | any(test("--own$"))'
AGENT_HOME="${TDIR}/nohome"
if setup_agent_hooks >/dev/null 2>&1; then hk_rc=0; else hk_rc=$?; fi
check "hooks: missing plugin dir -> nonzero" test "$hk_rc" -ne 0
AGENT_HOME="$H"

# --- channel.env webhook token + plugin config webhook ----------------------------------
ENV1="${TDIR}/env1"
CHANNEL_ENV_TOKEN="" render_channel_env "" "555" "" /st /ws >"$ENV1"
check "webhook: token generated"             grep -qE '^TELEGRAM_WEBHOOK_TOKEN=[0-9a-f]{48}$' "$ENV1"
ENV2="${TDIR}/env2"
CHANNEL_ENV_TOKEN="" render_channel_env "$ENV1" "" "" /st /ws >"$ENV2"
check "webhook: token kept on re-run"        test "$(grep '^TELEGRAM_WEBHOOK_TOKEN=' "$ENV1")" = "$(grep '^TELEGRAM_WEBHOOK_TOKEN=' "$ENV2")"
C="${TDIR}/config.json"
ensure_channel_config_defaults "$C"
check "webhook: enabled in plugin config"    jqtrue "$C" '.webhook.enabled == true and .hud.enabled == false'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
