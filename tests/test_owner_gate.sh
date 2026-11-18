#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329  # globals read by sourced fns, overrides
# hooks/owner-gate.py (#1920 b, g): actions on the owner's bots, services, schedule and files, and edits
# of the agent's own rules/settings/hooks, run only after the OWNER taps «Allow» on the card the plugin
# sends him (permission_gate route of the dashi plugin). Everything else passes without a card.
# The plugin is replaced by a local fake that answers allow / deny / timeout and logs what it was asked.
# Also: the installer registers the hook in the plugin settings of every channel agent and switches
# the plugin route on; the starter rules name the rule. No root needed.
# Run: bash tests/test_owner_gate.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TDIR="$(mktemp -d)"
SRV_PID=""
cleanup() {
    [[ -n "$SRV_PID" ]] && kill "$SRV_PID" 2>/dev/null || true
    rm -rf "${TDIR:?}"
}
trap cleanup EXIT
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
LAB="${H}/.claude-lab"
WS="${LAB}/jarvis/.claude"
PLUG="${WS}/dashi-plugin-claude-code/plugin"
mkdir -p "${WS}/core/hot" "${WS}/core/warm" "${WS}/memory" "${WS}/azv/soul" "${PLUG}/.claude" \
    "${H}/.claude/hooks" "${LAB}/shared/state/jarvis" "${TDIR}/etc/jarvis" "${H}/bots/admin" "${H}/work/proj"
printf '# rules\n- one\n' >"${WS}/core/rules.md"
printf '# Jarvis\n' >"${WS}/CLAUDE.md"
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
OWNER_GATE_TIMEOUT_SEC="3"
EOF
export NEUROOTDEL_GUARD_CONF="${TDIR}/guard.conf"
GATE="${REPO}/lib/hooks/owner-gate.py"
SECRET="AAHsecretsecretsecretsecretsecret12"

# --- fake plugin route ----------------------------------------------------------------------
cat >"${TDIR}/fake.py" <<'PY'
import http.server, json, sys, time
from pathlib import Path
d = Path(sys.argv[1])
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode()
        ok = self.path == "/hooks/permission/request" and self.headers.get("Authorization") == "Bearer tok123"
        with (d / "reqs.jsonl").open("a") as fh:
            fh.write(json.dumps({"path": self.path, "auth_ok": ok, "body": json.loads(body or "{}")}) + "\n")
        verdict = (d / "verdict").read_text().strip() if (d / "verdict").exists() else "deny"
        if not ok:
            self.send_response(401); self.end_headers(); return
        if verdict == "slow":
            time.sleep(30)
        if verdict == "503":
            self.send_response(503); self.end_headers(); self.wfile.write(b'{"error":"permission_gate disabled"}'); return
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(json.dumps({"status": verdict}).encode())
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
(d / "port").write_text(str(s.server_address[1]))
s.serve_forever()
PY
python3 "${TDIR}/fake.py" "$TDIR" &
SRV_PID=$!
for _ in $(seq 50); do [[ -s "${TDIR}/port" ]] && break; sleep 0.1; done
PORT=$(cat "${TDIR}/port")
cat >"${TDIR}/etc/jarvis/channel.env" <<EOF
TELEGRAM_BOT_TOKEN=123456:${SECRET}
TELEGRAM_WEBHOOK_HOST=127.0.0.1
TELEGRAM_WEBHOOK_PORT=${PORT}
TELEGRAM_WEBHOOK_TOKEN=tok123
EOF
: >"${TDIR}/reqs.jsonl"
verdict() { printf '%s\n' "$1" >"${TDIR}/verdict"; }
nreq() { wc -l <"${TDIR}/reqs.jsonl" | tr -d ' '; }

# gate <json> -- rc of the hook; stderr kept in ${TDIR}/err
gate() { local r=0; printf '%s' "$1" | python3 "$GATE" jarvis >"${TDIR}/out" 2>"${TDIR}/err" || r=$?; echo "$r"; }
bash_p() { jq -nc --arg c "$1" --arg cwd "${2:-$WS}" '{hook_event_name:"PreToolUse",session_id:"s1",tool_use_id:"tu1",tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}'; }
file_p() { jq -nc --arg t "$1" --arg f "$2" '{hook_event_name:"PreToolUse",session_id:"s1",tool_use_id:"tu2",tool_name:$t,tool_input:{file_path:$f,content:"x",old_string:"a",new_string:"b"}}'; }
edit_p() { jq -nc --arg f "$1" --arg o "$2" --arg n "$3" '{hook_event_name:"PreToolUse",tool_name:"Edit",tool_input:{file_path:$f,old_string:$o,new_string:$n}}'; }
write_p() { jq -nc --arg f "$1" --arg c "$2" '{hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$f,content:$c}}'; }
mcp_p() { jq -nc --arg t "$1" '{hook_event_name:"PreToolUse",tool_name:$t,tool_input:{id:"1"}}'; }

# passes: rc 0 and NO card was asked for
passes() { local before after r; before=$(nreq); r=$(gate "$1"); after=$(nreq); [[ "$r" == 0 && "$before" == "$after" ]]; }
# held: with the owner saying no, rc 2, one card asked for, the agent told to ask the owner
held() {
    local before after r; verdict deny; before=$(nreq); r=$(gate "$1"); after=$(nreq)
    [[ "$r" == 2 && "$after" == $((before + 1)) ]] && grep -q 'владельц' "${TDIR}/err" && grep -q '«да»' "${TDIR}/err"
}

# --- ordinary work passes without a card ---------------------------------------------------
SAFE_CMDS=(
    "ls -la"
    "cat ${WS}/CLAUDE.md"
    "grep -rn handoff ${WS}/core"
    "git status && git diff && git log --oneline -5"
    "git commit -m 'x' && git push origin feature/x"
    "python3 ${H}/work/proj/run.py --config settings.json"
    "curl -s https://api.telegram.org/bot\$TOKEN/getMe"
    "curl -s https://api.telegram.org/bot\$TOKEN/getUpdates?offset=1"
    "curl -s -X POST https://api.telegram.org/bot\$TOKEN/sendMessage -d chat_id=555 -d text=hi"
    "curl -s https://chatplace.io/api/v1/bots/12/flows"
    "curl -s -X POST https://api.openai.com/v1/audio/transcriptions -F file=@a.ogg"
    "curl -s -X POST http://127.0.0.1:8089/hooks/agent -d '{}'"
    "systemctl status channel-jarvis"
    "systemctl is-active channel-jarvis && systemctl list-timers"
    "journalctl -u channel-jarvis -n 50 --no-pager"
    "crontab -l"
    "crontab -u neurootdel -l"
    "rm -f /tmp/x.txt"
    "rm -rf /tmp/build-1 /var/tmp/y"
    "rm ${WS}/work-note.txt"
    "cd ${H}/work/proj && rm -f build/out.js"
    "echo '- done' >> ${WS}/core/hot/handoff.md"
    "sed -i 's/a/b/' ${WS}/core/hot/handoff.md"
    "echo '- new rule' >> ${WS}/core/rules.md"
    "cat ${H}/.claude/settings.json"
    "jq '.hooks' ${PLUG}/.claude/settings.json"
    "python3 -c \"import json;print(json.load(open('${H}/.claude/settings.json')))\""
    "printf 'restart jarvis from=jarvis\\n' > /var/lib/neurootdel-requests/requests/r1.tmp && mv /var/lib/neurootdel-requests/requests/r1.tmp /var/lib/neurootdel-requests/requests/r1"
    "tmux -L channel-jarvis capture-pane -p"
    "ffmpeg -i in.mp4 -t 3 /tmp/out.mp4"
    "npm test && bun test"
    "docker ps && pm2 list"
    "python3 -c 'print(1)'"
    "find ${WS}/work -name '*.png' -delete"
    "cp ${WS}/core/rules.md /tmp/rules.bak"
    "mkdir -p ${WS}/work && touch ${WS}/work/a"
)
for c in "${SAFE_CMDS[@]}"; do
    check "pass: ${c:0:70}" passes "$(bash_p "$c")"
done
SAFE_FILES=(
    "Write ${WS}/memory/feedback-x.md"
    "Edit ${WS}/core/hot/handoff.md"
    "Edit ${WS}/core/warm/decisions.md"
    "Write ${H}/work/proj/config.py"
    "Write ${H}/work/proj/package.json"
    "Write ${WS}/work/report.html"
    "Write /tmp/a.txt"
    "Edit ${WS}/core/USER.md"
)
for f in "${SAFE_FILES[@]}"; do
    check "pass: ${f/${TDIR}/}" passes "$(file_p "${f%% *}" "${f#* }")"
done
check "pass: rules.md append by Edit"   passes "$(edit_p "${WS}/core/rules.md" "- one" $'- one\n- two')"
check "pass: rules.md append by Write"  passes "$(write_p "${WS}/core/rules.md" $'# rules\n- one\n- two\n')"
for t in mcp__dashi-channel__reply mcp__dashi-channel__edit_message mcp__dashi-channel__react \
        mcp__gbrain-memory__update_document mcp__claude_ai_Gmail__search_threads \
        mcp__claude_ai_Google_Calendar__create_event mcp__claude_ai_Google_Drive__read_file_content; do
    check "pass: ${t}" passes "$(mcp_p "$t")"
done
check "pass: Read is never asked"       passes "$(jq -nc --arg f "${WS}/CLAUDE.md" '{hook_event_name:"PreToolUse",tool_name:"Read",tool_input:{file_path:$f}}')"
check "pass: Glob/Grep never asked"     passes '{"hook_event_name":"PreToolUse","tool_name":"Grep","tool_input":{"pattern":"x"}}'

# --- the owner's bots, services, schedule, files: held until his «Allow» ---------------------
DANGER_CMDS=(
    "curl -s -X POST https://api.telegram.org/bot123456:${SECRET}/setWebhook -d url=https://x"
    "curl -s https://api.telegram.org/bot\$OTHER/deleteWebhook"
    "curl -s https://api.telegram.org/bot\$OTHER/logOut"
    "curl -s -X POST https://api.telegram.org/bot\$OTHER/setMyCommands -d commands=[]"
    "python3 -c \"import requests;requests.post('https://api.telegram.org/bot'+t+'/setMyDescription', data={})\""
    "curl -s -X PATCH https://chatplace.io/api/v1/bots/12 -d '{\"ai\":false}'"
    "curl -s https://chatplace.io/api/v1/bots/12/prompt -H 'Content-Type: application/json' --data '{\"prompt\":\"x\"}'"
    "curl -s -X DELETE https://salebot.pro/api/x/flows/3"
    "systemctl stop adminbot"
    "sudo systemctl disable --now adminbot.service"
    "systemctl --user restart mybot"
    "systemctl mask nginx"
    "service nginx restart"
    "pm2 stop adminbot"
    "docker stop adminbot"
    "docker compose down"
    "crontab -r"
    "crontab -e"
    "crontab /tmp/new.cron"
    "echo '* * * * * x' | crontab -"
    "sed -i 's/a/b/' /etc/cron.d/backup"
    "rm ${H}/bots/admin/config.py"
    "rm -rf /opt/mybot"
    "find /srv/bot -name '*.log' -delete"
    "echo x > ${WS}/CLAUDE.md"
    "sed -i 's/a/b/' ${H}/.claude/settings.json"
    "python3 -c \"open('${H}/.claude/settings.json','w').write('{}')\""
    "jq 'del(.hooks)' ${PLUG}/.claude/settings.json > /tmp/s && mv /tmp/s ${PLUG}/.claude/settings.json"
    "cp /tmp/s.json ${H}/.claude/settings.json"
    "mv ${H}/.claude/settings.json /tmp/"
    "rm ${H}/.claude/hooks/secret-outbound-guard.py"
    "echo x > ${WS}/core/rules.md"
    "tee ${H}/.claude/CLAUDE.md < /tmp/x"
    "printf 'model jarvis haiku\\n' > /var/lib/neurootdel-requests/requests/m1"
    "printf 'allow-user jarvis 777\\n' > /var/lib/neurootdel-requests/requests/a1"
    "tmux -L channel-jarvis send-keys 1 Enter"
)
for c in "${DANGER_CMDS[@]}"; do
    check "held: ${c:0:70}" held "$(bash_p "$c")"
done
DANGER_FILES=(
    "Edit ${WS}/CLAUDE.md"
    "Write ${H}/.claude/settings.json"
    "Edit ${PLUG}/.claude/settings.json"
    "Write ${PLUG}/.claude/settings.local.json"
    "Write ${H}/.claude/hooks/x.py"
    "Edit ${H}/.claude/CLAUDE.md"
    "Write ${WS}/azv/soul/rules.md"
    "Write ${H}/.claude/rules/bash.md"
    "Write ${H}/.claude.json"
    "Write ${WS}/.mcp.json"
    "Write ${H}/.claude/channels/dashi/config.json"
    "Write /etc/cron.d/x"
    "Edit /etc/systemd/system/adminbot.service"
    "Write ${H}/.config/systemd/user/x.service"
    "Edit ${H}/bots/admin/system_prompt.txt"
    "Edit ${WS}/../.claude/CLAUDE.md"
)
for f in "${DANGER_FILES[@]}"; do
    check "held: ${f/${TDIR}/}" held "$(file_p "${f%% *}" "${f#* }")"
done
check "held: rules.md rewrite by Edit"  held "$(edit_p "${WS}/core/rules.md" "- one" "- другое")"
check "held: rules.md rewrite by Write" held "$(write_p "${WS}/core/rules.md" $'# rules\n- другое\n')"
check "held: MultiEdit of CLAUDE.md"    held "$(jq -nc --arg f "${WS}/CLAUDE.md" '{hook_event_name:"PreToolUse",tool_name:"MultiEdit",tool_input:{file_path:$f,edits:[{old_string:"a",new_string:"b"}]}}')"
for t in mcp__chatplace__update_bot mcp__chatplace__delete_flow mcp__salebot__setPrompt \
        mcp__claude_ai_Google_Drive__trash_file mcp__claude_ai_Google_Calendar__delete_event mcp__x__disable_ai; do
    check "held: ${t}" held "$(mcp_p "$t")"
done

# --- Codex r1: owner's existing files, workspace rules/hooks, links, MCP name forms, append-only --------
printf 'AI=on\n' >"${H}/bots/admin/config.py"
mkdir -p "${TDIR}/lnk" "${WS}/rules" "${WS}/hooks"
ln -sf "${H}/.claude/settings.json" "${TDIR}/lnk/settings-link"
check "held: Write over the owner's bot config"   held "$(write_p "${H}/bots/admin/config.py" 'AI=off')"
check "held: redirect over the owner's bot config" held "$(bash_p "echo AI=off > ${H}/bots/admin/config.py")"
check "held: sed -i on the owner's bot config"    held "$(bash_p "sed -i s/on/off/ ${H}/bots/admin/config.py")"
check "pass: a new file in home is not the owner's" passes "$(write_p "${H}/new-note.md" 'x')"
check "pass: redirect to /dev/null"               passes "$(bash_p "ls > /dev/null 2>&1")"
check "pass: redirect to /dev/stderr"             passes "$(bash_p "echo oops > /dev/stderr")"
check "held: workspace rules dir"                 held "$(write_p "${WS}/rules/security.md" 'x')"
check "held: workspace hooks dir"                 held "$(write_p "${WS}/hooks/x.sh" 'x')"
check "held: write through a link to settings"    held "$(bash_p "printf '{}' > ${TDIR}/lnk/settings-link")"
check "held: Write through a link to settings"    held "$(write_p "${TDIR}/lnk/settings-link" '{}')"
check "pass: rm of the link itself is not the target" passes "$(bash_p "rm -f ${TDIR}/lnk/settings-link-missing")"
check "held: mcp resource_verb form"              held "$(mcp_p mcp__chatplace__bot_update)"
check "held: mcp batch_update form"               held "$(mcp_p mcp__crm__batch_update_records)"
check "pass: mcp list_* with a verb-like word"    passes "$(mcp_p mcp__crm__list_stop_words)"
check "held: rules.md line rewritten around old"  held "$(edit_p "${WS}/core/rules.md" "- one" "Отменено: - one")"
check "held: rules.md insert at the top"          held "$(edit_p "${WS}/core/rules.md" "# rules" $'# rules\n- top')"
check "pass: rules.md MultiEdit append"           passes "$(jq -nc --arg f "${WS}/core/rules.md" '{hook_event_name:"PreToolUse",tool_name:"MultiEdit",tool_input:{file_path:$f,edits:[{old_string:"- one\n",new_string:"- one\n- two\n"}]}}')"
verdict deny
gate "$(bash_p "curl -s -X PATCH https://chatplace.io/api/b/1 -u 'login:cleartextpw1' -H 'Authorization: Basic Zm9vOmJhcmJhego=' https://u:urlpass99@chatplace.io/x")" >/dev/null
check "card: -u password, Basic and URL password masked" bash -c '! grep -qE "cleartextpw1|Zm9vOmJhcmJhego|urlpass99" "$0"' "${TDIR}/reqs.jsonl"

# --- Codex r2: parents of protected trees, inline python writes, curl -o / wget -O ---------------------
mkdir -p "${WS}/work/sub"
printf 'x\n' >"${WS}/azv/soul/rules.md"
printf '{}\n' >"${PLUG}/.claude/settings.json"
check "held: rm -rf of the plugin dir (holds settings)" held "$(bash_p "rm -rf ${WS}/dashi-plugin-claude-code")"
check "held: rm -rf of azv (holds the prompt)"   held "$(bash_p "rm -rf ${WS}/azv")"
check "held: rm -rf of the workspace glob"       held "$(bash_p "rm -rf ${WS}/*")"
check "held: mv of azv away"                     held "$(bash_p "mv ${WS}/azv /tmp/azv-old")"
check "pass: rm -rf of a work subdir"            passes "$(bash_p "rm -rf ${WS}/work/sub")"
check "held: python write_text over owner config" held "$(bash_p "python3 -c \"from pathlib import Path; Path('${H}/bots/admin/config.py').write_text('AI=False')\"")"
check "held: python heredoc via a variable"      held "$(bash_p "python3 - <<'EOF'
from pathlib import Path
p = Path('${H}/bots/admin/config.py')
s = p.read_text().replace('on', 'off')
p.write_text(s)
EOF")"
check "pass: python writes to /tmp"              passes "$(bash_p "python3 -c \"from pathlib import Path; Path('/tmp/a.txt').write_text('x')\"")"
check "pass: python reads owner config, writes work" passes "$(bash_p "python3 - <<'EOF'
from pathlib import Path
src = Path('${H}/bots/admin/config.py')
out = Path('${WS}/work/copy.txt')
out.write_text(src.read_text())
EOF")"
check "held: curl -o over own settings"          held "$(bash_p "curl -fsSL https://example.org/s.json -o ${PLUG}/.claude/settings.json")"
check "held: wget -O over own settings"          held "$(bash_p "wget -q -O ${H}/.claude/settings.json https://example.org/s.json")"
check "pass: curl -o to /tmp"                    passes "$(bash_p "curl -fsSL https://example.org/a.png -o /tmp/a.png")"
check "pass: wget -O to work"                    passes "$(bash_p "wget -q -O ${WS}/work/a.png https://example.org/a.png")"

# --- Codex r3: recursive copy over protected trees, inline code with relative paths ---------------------
mkdir -p "${TDIR}/restore/sub"; printf 'x\n' >"${TDIR}/restore/CLAUDE.md"
check "held: cp -r contents into the workspace"  held "$(bash_p "cp -r ${TDIR}/restore/. ${WS}/")"
check "held: rsync -a --delete into the workspace" held "$(bash_p "rsync -a --delete ${TDIR}/restore/ ${WS}/")"
check "held: cp -a contents over the soul dir"    held "$(bash_p "cp -a ${TDIR}/restore/. ${WS}/azv/soul/")"
check "pass: cp -r into a work subdir"           passes "$(bash_p "cp -r ${TDIR}/restore ${WS}/work/")"
check "pass: rsync into a work subdir"           passes "$(bash_p "rsync -a ${TDIR}/restore/ ${WS}/work/r/")"
check "held: python relative path in the owner's dir" held "$(bash_p "python3 -c \"from pathlib import Path; Path('config.py').write_text('AI=False')\"" "${H}/bots/admin")"
check "held: cd into the owner's dir, then python" held "$(bash_p "cd ${H}/bots/admin && python3 -c \"open('config.py','w').write('AI=False')\"")"
check "pass: python relative write in work"      passes "$(bash_p "cd ${WS}/work && python3 -c \"open('out.txt','w').write('x')\"")"
check "pass: python encoding literal is no path" passes "$(bash_p "python3 -c \"open('/tmp/x.txt','w', encoding='utf-8').write('x')\"" "${H}/bots/admin")"

# --- Codex r4: cp -t, tree copies into the owner's dirs or over a nested CLAUDE.md, every interpreter run --
mkdir -p "${WS}/work/project"; printf 'x\n' >"${WS}/work/project/CLAUDE.md"
check "held: cp -a -t workspace"                 held "$(bash_p "cp -a -t ${WS} ${TDIR}/restore/.")"
check "held: cp --target-directory= workspace"   held "$(bash_p "cp -r --target-directory=${WS} ${TDIR}/restore/.")"
check "held: cp -a contents into the owner's bot dir" held "$(bash_p "cp -a ${TDIR}/restore/. ${H}/bots/admin/")"
check "held: cp -r over a nested CLAUDE.md in work" held "$(bash_p "cp -r ${TDIR}/restore/. ${WS}/work/project/")"
check "pass: cp -t into a work subdir"           passes "$(bash_p "cp -t ${WS}/work/sub ${TDIR}/restore/sub")"
check "held: second python after cd"             held "$(bash_p "python3 -c 'print(1)'
cd ${H}/bots/admin
python3 -c \"open('config.py','w').write('AI=False')\"")"

# --- Codex r5: cp -T, removing a parent of a nested CLAUDE.md, links to the owner's dirs, incomplete scans --
check "held: cp -aT over a dir with nested CLAUDE.md" held "$(bash_p "cp -aT ${TDIR}/restore ${WS}/work/project")"
check "held: rm -rf of a dir with nested CLAUDE.md"  held "$(bash_p "rm -rf ${WS}/work/project")"
check "held: mv away a dir with nested CLAUDE.md"    held "$(bash_p "mv ${WS}/work/project /tmp/archive")"
ln -sfn "${H}/bots/admin" "${WS}/work/admin-link"
check "held: cp -a into a link to the owner's dir"   held "$(bash_p "cp -a ${TDIR}/restore/. ${WS}/work/admin-link/")"
mkdir -p "${WS}/work/linkhost"; ln -sfn "${H}/bots/admin" "${WS}/work/linkhost/inner"
check "held: cp -r over a tree holding such a link"  held "$(bash_p "cp -r ${TDIR}/restore/. ${WS}/work/linkhost/")"
mkdir -p "${WS}/work/big"; python3 -c "import os,sys; [open(os.path.join(sys.argv[1], f'f{i}'), 'w').close() for i in range(50010)]" "${WS}/work/big"
check "held: tree too big to check fully"            held "$(bash_p "cp -r ${TDIR}/restore/. ${WS}/work/big/")"
rm -rf "${WS:?}/work/big"
mkdir -p "${WS}/work/nm/node_modules/x"; printf 'x\n' >"${WS}/work/nm/node_modules/x/CLAUDE.md"
check "pass: rm -rf of a build tree (node_modules skipped)" passes "$(bash_p "rm -rf ${WS}/work/nm")"
check "pass: rm -rf of a plain work subdir still free" passes "$(bash_p "rm -rf ${WS}/work/sub")"

# --- coordinator review: starting services, node fs calls, copy source vs destination, append on a new line --
for c in "systemctl enable adminbot" "sudo systemctl enable --now adminbot.service" "systemctl start adminbot" \
        "docker compose up -d" "docker compose up -d --force-recreate" "docker run -d --name bot img" \
        "docker create img" "pm2 start bot.js" "pm2 restart bot --update-env"; do
    check "held: ${c}" held "$(bash_p "$c")"
done
check "pass: systemctl status / list-units still free" passes "$(bash_p "systemctl status adminbot; systemctl list-units --type=service")"
check "pass: docker ps / compose ps still free"  passes "$(bash_p "docker ps && docker compose ps && pm2 list")"
check "held: node unlinkSync of the owner's file" held "$(bash_p "node -e 'require(\"fs\").unlinkSync(\"${H}/bots/admin/config.py\")'")"
check "held: node unlinkSync outside HOME"       held "$(bash_p "node -e 'require(\"fs\").unlinkSync(\"/srv/owner-bot/config.json\")'")"
check "held: node writeFileSync over the owner's file" held "$(bash_p "node -e 'require(\"fs\").writeFileSync(\"${H}/bots/admin/config.py\", \"x\")'")"
check "pass: python shutil.copy owner file -> /tmp" passes "$(bash_p "python3 -c 'import shutil; shutil.copy(\"${H}/bots/admin/config.py\",\"/tmp/config.json\")'")"
check "pass: node copyFileSync owner file -> /tmp" passes "$(bash_p "node -e 'require(\"fs\").copyFileSync(\"${H}/bots/admin/config.py\",\"/tmp/c.py\")'")"
check "pass: shutil.copy via variables -> /tmp"  passes "$(bash_p "python3 - <<'EOF'
import shutil
src = '${H}/bots/admin/config.py'
dst = '/tmp/c2.py'
shutil.copy(src, dst)
EOF")"
check "held: python shutil.copy back over the owner's file" held "$(bash_p "python3 -c 'import shutil; shutil.copy(\"/tmp/config.json\",\"${H}/bots/admin/config.py\")'")"
check "held: shutil.copy into the owner's dir"   held "$(bash_p "python3 -c 'import shutil; shutil.copy(\"/tmp/config.py\",\"${H}/bots/admin\")'")"
check "held: shutil.move of the owner's file away" held "$(bash_p "python3 -c 'import shutil; shutil.move(\"${H}/bots/admin/config.py\",\"/tmp/x.py\")'")"
check "held: node renameSync of the owner's file" held "$(bash_p "node -e 'require(\"fs\").renameSync(\"${H}/bots/admin/config.py\",\"/tmp/x.py\")'")"
check "held: rules.md tail glued to the last rule" held "$(edit_p "${WS}/core/rules.md" "- one" "- one и ещё")"
check "pass: rules.md new line after the last"   passes "$(edit_p "${WS}/core/rules.md" "- one" $'- one\n- three')"

# codex r6: copytree into the workspace, a dir destination in a variable, glued curl -uUSER:PASS
check "held: shutil.copytree into the workspace" held "$(bash_p "python3 -c 'import shutil; shutil.copytree(\"${TDIR}/restore\", \"${WS}\", dirs_exist_ok=True)'")"
check "held: shutil.copy to a dir held in a variable" held "$(bash_p "python3 - <<'EOF'
import shutil
src = '/tmp/config.py'
dst = '${H}/bots/admin'
shutil.copy(src, dst)
EOF")"
check "pass: shutil.copytree into a new work dir" passes "$(bash_p "python3 -c 'import shutil; shutil.copytree(\"${TDIR}/restore\", \"${WS}/work/newcopy\")'")"
verdict deny
gate "$(bash_p "curl -X PATCH https://chatplace.io/api/bots/12 -uadmin:q7NglueCred99 -d x=1")" >/dev/null
check "card: glued -uUSER:PASS masked"           bash -c '! grep -q "q7NglueCred99" "$0"' "${TDIR}/reqs.jsonl"

# init errors: fail closed with a clear text (missing dependency, load() raising)
FD="${TDIR}/brokenlib"; mkdir -p "${FD}/hooks"
cp "$GATE" "${REPO}/lib/hooks/block-dangerous.py" "${FD}/hooks/"
R=0; OUT=$(printf "%s" "$(bash_p "ls")" | python3 "${FD}/hooks/owner-gate.py" jarvis 2>&1) || R=$?
check "init: missing guard_conf -> rc 2"         test "$R" = 2
check "init: missing guard_conf -> clear text"   grep -q 'проверка не запустилась' <<<"$OUT"
printf 'def load(*a, **k):\n    raise RuntimeError("boom")\ndef read_raw(*a, **k):\n    return {}\n' >"${FD}/guard_conf.py"
R=0; OUT=$(printf "%s" "$(bash_p "ls")" | python3 "${FD}/hooks/owner-gate.py" jarvis 2>&1) || R=$?
check "init: load() raises -> rc 2"              test "$R" = 2
check "init: load() raises -> names the error"   grep -q 'RuntimeError: boom' <<<"$OUT"
cp "${REPO}/lib/guard_conf.py" "${FD}/guard_conf.py"; rm -f "${FD}/hooks/block-dangerous.py"
R=0; OUT=$(printf "%s" "$(bash_p "ls")" | python3 "${FD}/hooks/owner-gate.py" jarvis 2>&1) || R=$?
check "init: missing block-dangerous.py -> rc 2" test "$R" = 2 -a -n "$(grep 'проверка не запустилась' <<<"$OUT")"

# CLAUDE_CONFIG_DIR: the agent's config dir under another name is the same as ~/.claude
CCD="${H}/.claude-alt"; mkdir -p "${CCD}/projects/p/memory"
gate_ccd() { local r=0; printf '%s' "$1" | CLAUDE_CONFIG_DIR="$CCD" python3 "$GATE" jarvis >/dev/null 2>&1 || r=$?; echo "$r"; }
verdict deny
check "config dir: settings.json there held"   test "$(gate_ccd "$(write_p "${CCD}/settings.json" '{}')")" = 2
check "config dir: CLAUDE.md there held"       test "$(gate_ccd "$(write_p "${CCD}/CLAUDE.md" 'x')")" = 2
printf 'old\n' >"${CCD}/projects/p/memory/MEMORY.md"
B=$(nreq)
check "config dir: auto-memory free"           test "$(gate_ccd "$(write_p "${CCD}/projects/p/memory/MEMORY.md" 'new')")" = 0 -a "$(nreq)" = "$B"

# --- the card: what the owner sees --------------------------------------------------------------
verdict deny
gate "$(bash_p "curl -s -X POST https://api.telegram.org/bot123456:${SECRET}/setWebhook -d url=https://x")" >/dev/null
LAST=$(tail -n 1 "${TDIR}/reqs.jsonl")
check "card: bearer from channel.env"        jq -e '.auth_ok == true and .path == "/hooks/permission/request"' <<<"$LAST" >/dev/null
check "card: tool + preview + reason"        jq -e '.body.tool_name == "Bash" and (.body.preview | test("setWebhook")) and (.body.reason | length > 5)' <<<"$LAST" >/dev/null
check "card: bot token not in the card"      bash -c '! grep -q "$0" "$1"' "$SECRET" "${TDIR}/reqs.jsonl"
check "card: session + tool_use ids passed"  jq -e '.body.session_id == "s1" and .body.tool_use_id == "tu1"' <<<"$LAST" >/dev/null
check "card: timeout from guard.conf"        jq -e '.body.timeout_ms == 3000' <<<"$LAST" >/dev/null

# --- verdicts: only the owner's «allow» lets it run; everything else fails closed ---------------
SYS="$(bash_p "systemctl stop adminbot")"
verdict allow;   check "allow: owner tapped -> runs (rc 0)"     test "$(gate "$SYS")" = 0
verdict deny;    check "deny: owner refused -> rc 2"            test "$(gate "$SYS")" = 2
check "deny: message says ask the owner and wait for yes" grep -q 'спроси владельца' "${TDIR}/err"
verdict timeout; check "timeout: no tap -> rc 2"                test "$(gate "$SYS")" = 2
check "timeout: says the owner did not answer" grep -q 'не ответил' "${TDIR}/err"
verdict 503;     check "route off (503) -> rc 2"                test "$(gate "$SYS")" = 2
verdict weird;   check "unknown status -> rc 2"                 test "$(gate "$SYS")" = 2
verdict slow
T0=$(date +%s); R=$(gate "$SYS"); T1=$(date +%s)
check "slow plugin: rc 2 within the hook's own timeout" test "$R" = 2 -a $((T1 - T0)) -le 20

# --- the agent cannot approve itself ------------------------------------------------------------
verdict deny
mkdir -p "${LAB}/shared/state/jarvis/owner-gate"
for f in approve allow STOP ok; do : >"${LAB}/shared/state/jarvis/owner-gate/${f}"; done
: >"${WS}/owner-gate.STOP"
check "self-approval: files in its own dirs change nothing" test "$(gate "$SYS")" = 2
check "self-approval: creating such a file is itself held" held "$(bash_p "touch ${TDIR}/etc/owner-gate.STOP")"
cp "${TDIR}/etc/jarvis/channel.env" "${TDIR}/env.bak"
sed -i 's/^TELEGRAM_WEBHOOK_TOKEN=.*/TELEGRAM_WEBHOOK_TOKEN=wrong/' "${TDIR}/etc/jarvis/channel.env"
check "wrong bearer -> rc 2"                 test "$(gate "$SYS")" = 2
cp "${TDIR}/env.bak" "${TDIR}/etc/jarvis/channel.env"
sed -i 's/^TELEGRAM_WEBHOOK_HOST=.*/TELEGRAM_WEBHOOK_HOST=10.0.0.9/' "${TDIR}/etc/jarvis/channel.env"
verdict allow
B=$(nreq); R=$(gate "$SYS")
check "non-loopback host ignored: still asks 127.0.0.1" test "$R" = 0 -a "$(nreq)" = $((B + 1))
cp "${TDIR}/env.bak" "${TDIR}/etc/jarvis/channel.env"
rm -f "${TDIR}/etc/jarvis/channel.env"
verdict allow
check "no channel.env -> rc 2 (fail closed)" test "$(gate "$SYS")" = 2
cp "${TDIR}/env.bak" "${TDIR}/etc/jarvis/channel.env"
kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null || true; SRV_PID=""
check "plugin down -> rc 2"                  test "$(gate "$SYS")" = 2
check "plugin down -> agent told to ask in chat" grep -q 'спроси владельца' "${TDIR}/err"
check "broken payload -> rc 2"               test "$(gate 'not json')" = 2
check "events logged without the token"      bash -c 'test -s "$1" && ! grep -q "$0" "$1"' "$SECRET" "${LAB}/shared/state/jarvis/owner-gate/events.jsonl"
: >"${TDIR}/etc/owner-gate.STOP"
check "root STOP (config root) switches it off" test "$(gate "$SYS")" = 0
rm -f "${TDIR}/etc/owner-gate.STOP"

# --- installer: registered in the plugin settings of each channel agent, route on ------------------
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
CWS="${LAB}/coder/.claude"
CODER_ENV_DIR="${TDIR}/etc/coder"
mkdir -p "$CODER_ENV_DIR" "${CWS}/dashi-plugin-claude-code/plugin"
echo 'TELEGRAM_WEBHOOK_PORT=8094' >"${CODER_ENV_DIR}/channel.env"
CODER_INSTALLED=1 setup_agent_hooks
US="${H}/.claude/settings.json"
PS="${PLUG}/.claude/settings.json"
CPS="${CWS}/dashi-plugin-claude-code/plugin/.claude/settings.json"
OGM='[.hooks.PreToolUse[] | select(any(.hooks[]; .command | test("owner-gate.py")))]'
check "install: jarvis owner-gate registered once" jqtrue "$PS" "${OGM} | length == 1 and (.[0].hooks[0].command | test(\"^python3 /usr/local/lib/neurootdel/hooks/owner-gate.py jarvis\$\"))"
check "install: coder owner-gate registered once"  jqtrue "$CPS" "${OGM} | length == 1 and (.[0].hooks[0].command | test(\"owner-gate.py coder\$\"))"
check "install: matcher covers Bash/Edit/Write/MultiEdit/NotebookEdit/MCP" jqtrue "$PS" "${OGM}[0].matcher as \$m | [\"Bash\",\"Edit\",\"Write\",\"MultiEdit\",\"NotebookEdit\",\"mcp__chatplace__update_bot\"] | all(test(\"^(\" + \$m + \")\$\"))"
check "install: matcher skips Read"           jqtrue "$PS" "${OGM}[0].matcher as \$m | \"Read\" | test(\"^(\" + \$m + \")\$\") | not"
check "install: hook timeout above the wait"  jqtrue "$PS" "${OGM}[0].hooks[0].timeout >= 200"
check "install: not in user settings (Richard)" jqtrue "$US" '[.. | .command? // empty] | any(test("owner-gate")) | not'
cp "$PS" "${TDIR}/ps1"
CODER_INSTALLED=1 setup_agent_hooks
check "install: re-run adds nothing"          cmp -s "$PS" "${TDIR}/ps1"
# --solo (one agent, no Coder): the hook is registered the same way (#1920).
rm -f "$PS"
SOLO=1 CODER_INSTALLED=0 setup_agent_hooks
check "install: solo jarvis owner-gate registered once" jqtrue "$PS" "${OGM} | length == 1 and (.[0].hooks[0].command | test(\"owner-gate.py jarvis\$\")) and .[0].hooks[0].timeout >= 200"
CODER_INSTALLED=1 setup_agent_hooks
check "install: back to the full run, still once" jqtrue "$PS" "${OGM} | length == 1"
C="${TDIR}/config.json"
ensure_channel_config_defaults "$C"
check "install: plugin permission route on"   jqtrue "$C" '.permission_gate.enabled == true and .permission_gate.timeout_ms >= 180000'
echo '{"permission_gate":{"enabled":false}}' >"$C"
ensure_channel_config_defaults "$C"
check "install: owner's explicit off is kept"  jqtrue "$C" '.permission_gate.enabled == false and .permission_gate.timeout_ms >= 180000'
check "install: hook copied with the lib"     test -f "${REPO}/lib/hooks/owner-gate.py"

# --- the rule in the starter text ------------------------------------------------------------
SRC="${REPO}/templates/AGENT-RULES-STARTER.md"
check "rules: rule 8 names the owner's bots, services" grep -qF 'ботов, сервисов, расписаний и файлов владельца' "$SRC"
check "rules: rule 8 only after the owner's yes" grep -qF 'только после его явного «да»' "$SRC"
check "rules: rule 4 no longer a blanket «не жди»" bash -c '! grep -q "разрешения не жди\. " "$0"' "$SRC"
SOLO_G="${REPO}/templates/solo/global-CLAUDE.md"
check "rules: solo global names the owner's bots, services" grep -qF 'подключения его ботов, сервисов, cron,' "$SOLO_G"
check "rules: solo global own rules after «да»" grep -qF 'свои CLAUDE.md, settings и правила (кроме новой строки в core/rules.md) только после' "$SOLO_G"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
