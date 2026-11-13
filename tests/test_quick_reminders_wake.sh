#!/usr/bin/env bash
# quick-reminders --wake: the reminder wakes the agent itself through its channel webhook (wake.sh),
# the token never lands in crontab or in curl's argv, the job file goes once delivered.
# Synthetic data, crontab and curl are stubs. Run: bash tests/test_quick_reminders_wake.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TDIR="$(mktemp -d)"
trap 'rm -rf "${TDIR:?}"' EXIT
PASS=0; FAIL=0
check() { local n=$1; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok   $n"; else FAIL=$((FAIL+1)); echo "FAIL $n"; fi; }

export HOME="${TDIR}/home"
SK="${HOME}/.claude-lab/coder/.claude/skills/quick-reminders/scripts"
mkdir -p "$SK" "${TDIR}/bin"
cp "${REPO}/skills/quick-reminders/scripts/"*.sh "$SK/"
ENV="${TDIR}/channel.env"
printf 'TELEGRAM_BOT_TOKEN=111:AAHsecret\nTELEGRAM_WEBHOOK_PORT=8091\nTELEGRAM_WEBHOOK_TOKEN=whsecret\nTELEGRAM_ALLOWED_USER_IDS=555,777\n' >"$ENV"
export NEUROOTDEL_CHANNEL_ENV="$ENV"
cat >"${TDIR}/bin/crontab" <<'F'
#!/usr/bin/env bash
f="${HOME}/crontab.txt"
# Like the real one: no crontab -> "no crontab for <user>", exit 1; crontab.fail -> a read error.
if [[ "${1:-}" == "-l" ]]; then
    [[ -f "${HOME}/crontab.fail" ]] && { echo "crontab: permission denied" >&2; exit 1; }
    [[ -f "$f" ]] || { echo "no crontab for tester" >&2; exit 1; }
    cat "$f"; exit 0
fi
if [[ "${1:-}" == "-" ]]; then cat >"$f"; exit 0; fi
exit 1
F
cat >"${TDIR}/bin/curl" <<'F'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${HOME}/curl.argv"
printf '%s\n' "$@" >>"${HOME}/curl.argv.all"
cat >"${HOME}/curl.stdin"
cat "${HOME}/curl.stdin" >>"${HOME}/curl.stdin.all"
for a in "$@"; do [[ "$a" == @* ]] && cat "${a#@}" >"${HOME}/curl.body"; done
cat "${HOME}/curl.code" 2>/dev/null || printf 200
F
chmod +x "${TDIR}/bin/crontab" "${TDIR}/bin/curl"
export PATH="${TDIR}/bin:${PATH}"

OUT=$(bash "${SK}/create.sh" --wake "in 30 minutes" 'Проверь, взял ли "Coder" задачу' 2>&1); RC=$?
check "create --wake: exit 0"                       test "$RC" -eq 0
check "create --wake: agent from the skill path"    grep -q 'wake=coder' <<<"$OUT"
ID=$(sed -n 's/^scheduled: id=\([0-9a-f]*\) .*/\1/p' <<<"$OUT")
JOB="${HOME}/.claude-lab/shared/state/reminders/${ID}.json"
check "job file written"                            test -f "$JOB"
check "job: message with the wake mark"             bash -c 'jq -e ".message == \"[будильник] Проверь, взял ли \\\"Coder\\\" задачу\"" "$0"' "$JOB"
check "job: owner chat = first allowed id"          bash -c 'jq -e ".chat == \"555\"" "$0"' "$JOB"
check "cron: one wake line, tagged"                 bash -c 'test "$(grep -c "qr:ID=$0 wake$" "$1")" -eq 1' "$ID" "${HOME}/crontab.txt"
check "cron: no token, no message text in it"       bash -c '! grep -qE "AAHsecret|whsecret|Проверь" "$0"' "${HOME}/crontab.txt"
check "create: the text is not printed"           bash -c '! grep -q "Проверь" <<<"$0"' "$OUT"
check "job file private (600)"                     test "$(stat -c %a "$JOB")" = 600
check "list: shows the wake"                        bash -c 'bash "$0/list.sh" | grep -q "будильник агента"' "$SK"

bash "${SK}/wake.sh" "$ID"; RC=$?
check "wake: delivered, exit 0"                     test "$RC" -eq 0
check "wake: webhook URL of the agent's port"       grep -qx 'http://127.0.0.1:8091/hooks/agent' "${HOME}/curl.argv"
check "wake: token only through stdin"              bash -c 'grep -q "Bearer whsecret" "$0" && ! grep -q whsecret "$1"' "${HOME}/curl.stdin" "${HOME}/curl.argv"
check "wake: body = message + chatId"               bash -c 'grep -qF "\"chatId\":\"555\"" "$0" && grep -q "Проверь" "$0"' "${HOME}/curl.body"
check "wake: the text never in curl argv"           bash -c '! grep -q "Проверь" "$0"' "${HOME}/curl.argv"
check "wake: job file removed after delivery"       test ! -e "$JOB"
check "wake: its cron line removed"                 bash -c '! grep -q "qr:ID=$0" "$1"' "$ID" "${HOME}/crontab.txt"
check "wake: last line removed, no false failure"   bash -c '! grep -q "crontab rewrite failed" "$0"' "${HOME}/.claude-lab/shared/state/reminders/wake.log"

OUT=$(bash "${SK}/create.sh" --wake "in 1 hour" "второй" 2>&1)
ID2=$(sed -n 's/^scheduled: id=\([0-9a-f]*\) .*/\1/p' <<<"$OUT")
printf 502 >"${HOME}/curl.code"
: >"${HOME}/curl.stdin.all"; : >"${HOME}/curl.argv.all"
QR_WAKE_RETRY_SEC=0 bash "${SK}/wake.sh" "$ID2"; RC=$?
WL="${HOME}/.claude-lab/shared/state/reminders/wake.log"
check "wake: webhook down -> exit 1, job kept"      bash -c 'test "$0" -eq 1 && test -f "$1"' "$RC" "${HOME}/.claude-lab/shared/state/reminders/${ID2}.json"
check "wake: three tries logged"                    grep -q 'webhook answered 502 (try 3/3)' "$WL"
check "wake: owner told by the bot after the tries" bash -c 'grep -q "owner notified by the bot" "$0" && grep -q "api.telegram.org/bot111:AAHsecret/sendMessage" "$1"' "$WL" "${HOME}/curl.stdin.all"
check "wake: fallback text marks the miss"          grep -q '%D0%B2%D1%82%D0%BE%D1%80%D0%BE%D0%B9' "${HOME}/curl.body"
check "wake: bot token never in argv"               bash -c '! grep -q AAHsecret "$0"' "${HOME}/curl.argv.all"
check "wake: failed line removed too"               bash -c '! grep -q "qr:ID=$0" "$1"' "$ID2" "${HOME}/crontab.txt"
OUT=$(bash "${SK}/create.sh" --wake "in 2 hours" "третий" 2>&1)
ID3=$(sed -n 's/^scheduled: id=\([0-9a-f]*\) .*/\1/p' <<<"$OUT")
mv "$ENV" "${ENV}.away"
bash "${SK}/wake.sh" "$ID3"; RC=$?
mv "${ENV}.away" "$ENV"
check "wake: env unreadable -> line and job kept"   bash -c 'test "$0" -eq 1 && grep -q "qr:ID=$1 wake" "$2" && test -f "$3"' "$RC" "$ID3" "${HOME}/crontab.txt" "${HOME}/.claude-lab/shared/state/reminders/${ID3}.json"
sed -i '/^TELEGRAM_WEBHOOK_PORT=/d' "$ENV"
: >"${HOME}/curl.stdin.all"
bash "${SK}/wake.sh" "$ID3"; RC=$?
check "wake: no port -> owner told, line removed"   bash -c 'test "$0" -eq 1 && grep -q "sendMessage" "$1" && ! grep -q "qr:ID=$2" "$3"' "$RC" "${HOME}/curl.stdin.all" "$ID3" "${HOME}/crontab.txt"
bash "${SK}/wake.sh" "../etc"; RC=$?
check "wake: a bad id refused"                      test "$RC" -eq 2

printf 'TELEGRAM_BOT_TOKEN=111:AAHsecret\nTELEGRAM_ALLOWED_USER_IDS=555\n' >"$ENV"
bash "${SK}/create.sh" --wake "in 5 minutes" "x" >/dev/null 2>&1; RC=$?
check "create --wake: no webhook port -> refused"   test "$RC" -ne 0
OUT=$(bash "${SK}/create.sh" "in 5 minutes" "обычное напоминание" 2>&1); RC=$?
check "plain reminder still works"                  bash -c 'test "$0" -eq 0 && grep -q "sendMessage" "$1"' "$RC" "${HOME}/crontab.txt"

PID1=$(sed -n 's/^scheduled: id=\([0-9a-f]*\).*/\1/p' <<<"$OUT")
LOCKF="${HOME}/.claude-lab/shared/state/reminders/.crontab.lock"
check "plain: own removal goes through delete.sh"  bash -c 'grep "qr:ID=$0$" "$1" | grep -qF "/delete.sh'"'"' $0 >/dev/null"' "$PID1" "${HOME}/crontab.txt"
LINE=$(grep "qr:ID=${PID1}$" "${HOME}/crontab.txt")
sh -c "${LINE#*>/dev/null 2>&1; }"
check "plain: fired line removes itself"            bash -c '! grep -q "qr:ID=$0" "$1"' "$PID1" "${HOME}/crontab.txt"

: >"${HOME}/crontab.txt"
OUT=$(bash "${SK}/create.sh" "in 5 minutes" "последнее" 2>&1)
PID2=$(sed -n 's/^scheduled: id=\([0-9a-f]*\).*/\1/p' <<<"$OUT")
OUT=$(bash "${SK}/delete.sh" "$PID2" 2>&1); RC=$?
check "delete: the only line -> exit 0, deleted"    bash -c 'test "$0" -eq 0 && grep -q "deleted reminder" <<<"$1" && ! grep -q "qr:ID=$2" "$3"' "$RC" "$OUT" "$PID2" "${HOME}/crontab.txt"
bash "${SK}/delete.sh" "$PID2" >/dev/null 2>&1; RC=$?
check "delete: unknown id -> exit 1"                test "$RC" -eq 1

rm -f "${HOME}/crontab.txt"
OUT=$(bash "${SK}/create.sh" "in 5 minutes" "первый в пустом" 2>&1); RC=$?
check "create: no crontab yet -> exit 0, one line"  bash -c 'test "$0" -eq 0 && test "$(grep -c "qr:ID=" "$1")" -eq 1' "$RC" "${HOME}/crontab.txt"

cp "${HOME}/crontab.txt" "${TDIR}/crontab.before"
PIDF=$(sed -n 's/^scheduled: id=\([0-9a-f]*\).*/\1/p' <<<"$OUT")
touch "${HOME}/crontab.fail"
bash "${SK}/delete.sh" "$PIDF" >/dev/null 2>&1; RC=$?
check "delete: read error -> exit 1, nothing written" bash -c 'test "$0" -eq 1 && cmp -s "$1" "$2"' "$RC" "${TDIR}/crontab.before" "${HOME}/crontab.txt"
bash "${SK}/create.sh" "in 5 minutes" "не запишется" >/dev/null 2>&1; RC=$?
check "create: read error -> exit 1, nothing written" bash -c 'test "$0" -ne 0 && cmp -s "$1" "$2"' "$RC" "${TDIR}/crontab.before" "${HOME}/crontab.txt"
printf '{"message":"x","chat":"555","env":"%s"}' "$ENV" >"${HOME}/.claude-lab/shared/state/reminders/${PIDF}.json"
printf 200 >"${HOME}/curl.code"
printf 'TELEGRAM_BOT_TOKEN=111:AAHsecret\nTELEGRAM_WEBHOOK_PORT=8091\nTELEGRAM_WEBHOOK_TOKEN=whsecret\nTELEGRAM_ALLOWED_USER_IDS=555\n' >"$ENV"
bash "${SK}/wake.sh" "$PIDF" >/dev/null 2>&1
check "wake: read error -> crontab kept, logged"    bash -c 'cmp -s "$0" "$1" && grep -q "crontab not read or not rewritten, line left" "$2"' "${TDIR}/crontab.before" "${HOME}/crontab.txt" "${HOME}/.claude-lab/shared/state/reminders/wake.log"
rm -f "${HOME}/crontab.fail"

flock "$LOCKF" sleep 2 & HOLD=$!
sleep 0.3
T0=$(date +%s.%N)
bash "${SK}/create.sh" "in 5 minutes" "ждёт замок" >/dev/null 2>&1; RC=$?
T1=$(date +%s.%N)
wait "$HOLD"
check "create: waits for the crontab lock"          bash -c 'test "$0" -eq 0 && awk -v a="$1" -v b="$2" "BEGIN{exit !(b-a>=1)}"' "$RC" "$T0" "$T1"
flock "$LOCKF" sleep 2 & HOLD=$!
sleep 0.3
T0=$(date +%s.%N)
bash "${SK}/delete.sh" "0000000000000000" >/dev/null 2>&1
T1=$(date +%s.%N)
wait "$HOLD"
check "delete: waits for the crontab lock"          awk -v a="$T0" -v b="$T1" 'BEGIN{exit !(b-a>=1)}'

echo "${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
