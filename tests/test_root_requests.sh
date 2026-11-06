#!/usr/bin/env bash
# Tests for lib/agents-root-requests.sh (root request carrier, ported from a live server) with fake
# systemctl/crontab, every path re-rooted into a temp dir; plus its installer wiring. No root needed.
# Run: bash tests/test_root_requests.sh
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WD="${REPO}/lib/agents-root-requests.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "ok   $*"; }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL $*" >&2; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
OWNER=111111111
U="$(id -un)"

setup() {
    R="$(mktemp -d /tmp/rrtest.XXXXXX)"
    mkdir -p "$R"/{fake,bin,tmp,etc/systemd/system,etc/cron.d,var/log,"var/lib/${U}-requests/requests","var/lib/${U}-requests/results","var/lib/${U}-guard"}
    mkdir -p "$R/etc/plugin/jarvis" "$R/etc/plugin/coder"
    cat >"$R/guard.conf" <<EOF
AGENT_USER="${U}"
CONFIG_ROOT="$R/etc/plugin"
CHANNEL_AGENTS="jarvis coder"
OWNER_TG_ID="${OWNER}"
EOF
    for a in jarvis coder; do
        cat >"$R/etc/plugin/$a/channel.env" <<EOF
TELEGRAM_BOT_TOKEN=123:secret
TELEGRAM_ALLOWED_USER_IDS=${OWNER},222222222
TELEGRAM_ALLOWED_CHAT_IDS=${OWNER},222222222,-1001234567890
TELEGRAM_PERMISSION_ALLOWED_USER_IDS=${OWNER}
TELEGRAM_COMMAND_OWNER_IDS=${OWNER},333333333
EOF
        chmod 0640 "$R/etc/plugin/$a/channel.env"
        echo "ExecStart=/bin/bash /usr/local/lib/x/channel-start.sh channel-$a claude --model opus --dangerously-skip-permissions --dangerously-load-development-channels server:dashi-channel" \
            >"$R/etc/systemd/system/channel-$a.service"
    done
    for u in claude-richard hermes-auditor hermes-auditor-bridge; do echo "ExecStart=/bin/true" >"$R/etc/systemd/system/$u.service"; done
    local old=$(( $(date +%s) - 1000 ))
    for u in channel-jarvis channel-coder claude-richard hermes-auditor hermes-auditor-bridge; do echo "$old" >"$R/fake/start-$u"; done
    cat >"$R/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
F="$NEUROOTDEL_RR_ROOT/fake"; echo "$*" >>"$F/calls"
case "$1" in
  show) u="${!#}"
        [[ -e "$F/show-fail" ]] && exit 1
        if [[ "$3" == "ActiveEnterTimestamp" ]]; then echo "@$(cat "$F/start-$u")"
        elif [[ -e "$F/stale-$u" ]]; then cat "$F/stale-$u"
        else grep -m1 '^ExecStart=' "$NEUROOTDEL_RR_ROOT/etc/systemd/system/$u.service" | cut -d= -f2-; fi ;;
  is-active) [[ -e "$F/down-$2" ]] && echo failed || echo active ;;
  restart) date +%s >"$F/start-$2" ;;
  daemon-reload) [[ -e "$F/reload-fail" ]] && exit 1; : ;;
esac
EOF
    cat >"$R/bin/crontab" <<'EOF'
#!/usr/bin/env bash
F="$NEUROOTDEL_RR_ROOT/fake/crontab"
if [[ "$3" == "-l" ]]; then [[ -f "$F" ]] && cat "$F" || exit 1; else cp "$3" "$F"; fi
EOF
    chmod +x "$R"/bin/*
    export NEUROOTDEL_RR_TEST=1 NEUROOTDEL_RR_ROOT="$R" NEUROOTDEL_RR_SYSTEMCTL="$R/bin/systemctl" \
        NEUROOTDEL_RR_CRONTAB="$R/bin/crontab" NEUROOTDEL_GUARD_CONF="$R/guard.conf"
    unset NEUROOTDEL_RR_NOW
}
req() { printf '%s\n' "$2" >"$R/var/lib/${U}-requests/requests/$1.tmp"; mv "$R/var/lib/${U}-requests/requests/$1.tmp" "$R/var/lib/${U}-requests/requests/$1"; }
run() { bash "$WD"; }
res() { cat "$R/var/lib/${U}-requests/results/$1.result" 2>/dev/null || true; }
has() { grep -q -- "$2" <<<"$(res "$1")"; }
calls() { cat "$R/fake/calls" 2>/dev/null || true; }
envf() { echo "$R/etc/plugin/$1/channel.env"; }
qcount() { find "$R/var/lib/${U}-root-requests/queue" -maxdepth 1 -name '[0-9]*' | wc -l; }
teardown() { rm -rf "${R:?}"; }

# 1. grammar: injection, unknown units, extra args, bad ids
setup
req r1 'restart coder; rm -rf /'
req r2 'restart sshd'
req r3 'restart ../../etc'
req r4 'restart coder extra'
req r5 'allow-user coder 12ab'
req r6 'model coder opus;id'
req r7 'restart coder from=root'
req r8 'allow-user auditor 123456'
req 'bad name' 'restart coder'
run
for n in r1 r2 r3 r4 r5 r6 r7 r8; do check "grammar rejects $n" has $n REJECT; done
check "bad file name rejected, nothing queued" test "$(qcount)" -eq 0
check "no systemctl restart on rejected input" bash -c "! grep -q restart '$R/fake/calls' 2>/dev/null"
check "guard queue untouched" test ! -e "$R/tmp/channel-restart-request"
teardown

# 2. file safety: symlink, hard link, oversized
setup
echo "secret-content" >"$R/target"
ln -s "$R/target" "$R/var/lib/${U}-requests/requests/sym"
printf 'restart coder\n' >"$R/hl"; ln "$R/hl" "$R/var/lib/${U}-requests/requests/hard"
head -c 600 /dev/zero | tr '\0' 'a' >"$R/var/lib/${U}-requests/requests/big"
run
check "symlink rejected" has sym "not a regular file"
check "symlink target untouched" test "$(cat "$R/target")" = "secret-content"
check "hard link rejected" has hard "hard links"
check "oversized rejected" has big "too big"
check "nothing queued" test "$(qcount)" -eq 0
teardown

# 3. restart via agents-guard queue + verify
setup
req rs 'restart coder from=jarvis'
run
check "restart queued in guard queue" grep -qx coder "$R/tmp/channel-restart-request"
check "restart result DONE/QUEUED" has rs QUEUED
check "verify pending" test -f "$R/var/lib/${U}-root-requests/verify/coder"
sleep 1; date +%s >"$R/fake/start-channel-coder"   # agents-guard restarted it
run
check "verify OK after real start" has rs "VERIFY OK"
req rs2 'restart coder'
run
check "second restart within 2 min deferred" has rs2 DEFER
check "deferred item kept" test "$(qcount)" -eq 1
check "guard queue still one line" test "$(wc -l <"$R/tmp/channel-restart-request")" -eq 1
rm "$R/tmp/channel-restart-request"   # agents-guard consumed it
NEUROOTDEL_RR_NOW=$(( $(date +%s) + 130 )) run
check "after cooldown it goes" has rs2 QUEUED
teardown

# 4. ordering: self-restart last; guard STOP; auditor direct
setup
req a1 'restart coder from=coder'
req a2 'restart jarvis from=coder'
run
check "other agent first" test "$(cat "$R/tmp/channel-restart-request")" = "jarvis"
check "self-restart waits while guard queue occupied" has a1 DEFER
rm "$R/tmp/channel-restart-request"
run
check "self-restart handed over next" test "$(cat "$R/tmp/channel-restart-request")" = "coder"
teardown
setup
touch "$R/var/lib/${U}-guard/QUEUE_OFF"
req g1 'restart coder'
run
check "guard queue off -> FAIL, not silent" has g1 "switched off"
teardown
setup
req au 'restart auditor'
run
check "auditor restarted both units" bash -c "grep -q 'restart hermes-auditor$' '$R/fake/calls' && grep -q 'restart hermes-auditor-bridge' '$R/fake/calls'"
check "auditor verify OK" has au "VERIFY OK"
touch "$R/fake/down-hermes-auditor-bridge"
NEUROOTDEL_RR_NOW=$(( $(date +%s) + 200 )) req au2 'restart auditor'
NEUROOTDEL_RR_NOW=$(( $(date +%s) + 200 )) run
check "auditor down after restart -> VERIFY FAIL" has au2 "VERIFY FAIL"
teardown

# 5. allow-user: already / add + restart queued / agent not installed
setup
cp "$(envf coder)" "$R/before"
req u1 'allow-user coder 222222222'
run
check "existing id -> ALREADY" has u1 "ALREADY"
check "no restart for already" test "$(qcount)" -eq 0
check "env unchanged" cmp -s "$R/before" "$(envf coder)"
req u2 'allow-user coder 777777777'
run
check "added, VERIFY OK" has u2 "VERIFY OK"
check "id in both keys" bash -c "grep -q '^TELEGRAM_ALLOWED_USER_IDS=.*,777777777$' '$(envf coder)' && grep -q '^TELEGRAM_ALLOWED_CHAT_IDS=.*,777777777$' '$(envf coder)'"
check "allow-user backup equals original" bash -c "cmp -s '$R/before' \$(ls '$(envf coder)'.bak-*-root-request-add)"
check "allow-user mode kept" test "$(stat -c %a "$(envf coder)")" = 640
check "restart queued, not direct" bash -c "test \"\$(find '$R/var/lib/${U}-root-requests/queue' -maxdepth 1 -name '[0-9]*' | wc -l)\" -eq 1 && ! grep -q '^restart' '$R/fake/calls' 2>/dev/null"
mv "$(envf jarvis)" "$R/jarvis.env"
req u3 'allow-user jarvis 777777777'
run
check "agent without channel.env -> FAIL" has u3 "not installed here"
mv "$R/jarvis.env" "$(envf jarvis)"
mv "$(envf jarvis)" "$R/jarvis.env"; ln -s "$R/before" "$(envf jarvis)"
req u4 'allow-user jarvis 777777777'
run
check "symlinked channel.env refused" has u4 "not installed here"
check "symlink target untouched" bash -c "! grep -q 777777777 '$R/before'"
teardown

# 6. revoke-user: protected / owner key / remove / absent
setup
cp "$(envf coder)" "$R/before"
req v1 "revoke-user coder ${OWNER}"
req v2 'revoke-user coder 333333333'
run
check "OWNER_TG_ID protected" has v1 REFUSED
check "command owner protected" has v2 REFUSED
check "env unchanged by refusals" cmp -s "$R/before" "$(envf coder)"
sed -i 's/^TELEGRAM_PERMISSION_ALLOWED_USER_IDS=.*/&,555555555/' "$(envf coder)"
req v3 'revoke-user coder 555555555'
run
check "permission-owner id refused" has v3 "REFUSED"
cp "$R/before" "$(envf coder)"
req v4 'revoke-user coder 222222222'
run
check "removed with backup" has v4 "changed, backup"
check "absent from both keys" bash -c "! grep -E '^TELEGRAM_ALLOWED_(USER|CHAT)_IDS=.*222222222' '$(envf coder)'"
check "other ids intact" bash -c "grep -qx 'TELEGRAM_ALLOWED_CHAT_IDS=${OWNER},-1001234567890' '$(envf coder)' && grep -q '^TELEGRAM_BOT_TOKEN=123:secret' '$(envf coder)'"
check "backup equals original" bash -c "cmp -s '$R/before' \$(ls '$(envf coder)'.bak-*-root-request-remove)"
check "mode preserved" test "$(stat -c %a "$(envf coder)")" = "$(stat -c %a "$R/before")"
check "internal restart queued" test "$(qcount)" -eq 1
rm -f "$R/tmp/channel-restart-request"
NEUROOTDEL_RR_NOW=$(( $(date +%s) + 130 )) run
check "internal restart forwarded to guard" grep -qx coder "$R/tmp/channel-restart-request"
req v5 'revoke-user coder 222222222'
NEUROOTDEL_RR_NOW=$(( $(date +%s) + 130 )) run
check "absent id -> ALREADY" has v5 "ALREADY"
echo 'TELEGRAM_ALLOWED_USER_IDS=999999999' >>"$(envf coder)"
cp "$(envf coder)" "$R/dup-before"
req v6 'revoke-user coder 999999999'
NEUROOTDEL_RR_NOW=$(( $(date +%s) + 130 )) run
check "repeated key -> FAIL, not a false VERIFY OK" has v6 "repeated"
check "repeated key: env untouched" cmp -s "$R/dup-before" "$(envf coder)"
cp "$R/before" "$(envf coder)"
printf '  TELEGRAM_ALLOWED_CHAT_IDS=222222222\n' >>"$(envf coder)"
cp "$(envf coder)" "$R/dup-before"
req v7 'revoke-user coder 222222222'
NEUROOTDEL_RR_NOW=$(( $(date +%s) + 130 )) run
check "indented repeat -> FAIL" has v7 "not plain"
check "indented repeat: env untouched" cmp -s "$R/dup-before" "$(envf coder)"
sed -i 's/^TELEGRAM_ALLOWED_USER_IDS=.*/TELEGRAM_ALLOWED_USER_IDS="222222222"/' "$(envf coder)"
sed -i '/^  TELEGRAM_ALLOWED_CHAT_IDS/d' "$(envf coder)"
cp "$(envf coder)" "$R/dup-before"
req v8 'revoke-user coder 222222222'
NEUROOTDEL_RR_NOW=$(( $(date +%s) + 130 )) run
check "quoted value -> FAIL, not ALREADY" has v8 "not a bare comma list"
check "quoted value: env untouched" cmp -s "$R/dup-before" "$(envf coder)"
cp "$R/before" "$(envf coder)"
printf ' TELEGRAM_COMMAND_OWNER_IDS=222222222\n' >>"$(envf coder)"
cp "$(envf coder)" "$R/dup-before"
req v9 'revoke-user coder 222222222'
NEUROOTDEL_RR_NOW=$(( $(date +%s) + 130 )) run
check "ambiguous owner key -> REFUSED" has v9 "REFUSED: TELEGRAM_COMMAND_OWNER_IDS"
check "ambiguous owner key: env untouched" cmp -s "$R/dup-before" "$(envf coder)"
teardown

# 7. allow-chat
setup
req c1 'allow-chat jarvis -1001234567890'
req c2 'allow-chat jarvis -1009999999999'
run
check "existing chat -> ALREADY" has c1 ALREADY
check "new chat added" has c2 "-1009999999999 allowed as chat (changed"
check "chat in env" grep -q '^TELEGRAM_ALLOWED_CHAT_IDS=.*,-1009999999999$' "$(envf jarvis)"
check "restart queued for jarvis" test "$(qcount)" -eq 1
teardown

# 8. permissions + model + model-revert
setup
req p1 'permissions coder'
run
check "flag present -> ALREADY" has p1 ALREADY
sed -i 's/ --dangerously-skip-permissions//' "$R/etc/systemd/system/channel-jarvis.service"
req p2 'permissions jarvis'
run
check "flag added" grep -q 'claude --dangerously-skip-permissions --model opus' "$R/etc/systemd/system/channel-jarvis.service"
check "daemon-reload called" grep -qx daemon-reload "$R/fake/calls"
check "unit backup kept" bash -c "ls '$R/etc/systemd/system/'channel-jarvis.service.bak-*-root-request-perms >/dev/null"
req m1 'model coder opus'
run
check "same model -> ALREADY" has m1 ALREADY
cp "$R/etc/systemd/system/channel-coder.service" "$R/unit-before"
req m2 'model coder claude-sonnet-5.5'
run
check "model switched" grep -q -- '--model claude-sonnet-5.5 --dangerously' "$R/etc/systemd/system/channel-coder.service"
check "previous model recorded" test "$(cat "$R/var/lib/${U}-root-requests/model-prev/coder")" = opus
req m3 'model-revert coder'
run
check "revert restores unit byte-for-byte" cmp -s "$R/unit-before" "$R/etc/systemd/system/channel-coder.service"
req m4 'model-revert coder'
run
check "second revert -> NOTHING" has m4 NOTHING
check "no restart by model requests" bash -c "! grep -q '^restart' '$R/fake/calls'"
teardown

# 9. cron-restore
setup
B="$R/var/backups/${U}-cron/20261105T102301Z/cron.d"; mkdir -p "$B"
mkdir -p "$R/var/backups/${U}-cron/20261101T102301Z/cron.d"
echo "* * * * * root guard" >"$B/${U}-agents-guard"
echo "* * * * * root new" >"$B/${U}-memory-backup"
echo "* * * * * root evil" >"$B/evil"
echo "old local" >"$R/etc/cron.d/${U}-memory-backup"
echo "0 1 * * * x" >"$R/var/backups/${U}-cron/20261105T102301Z/${U}-crontab"
req k1 'cron-restore'
run
check "missing file restored from latest" cmp -s "$B/${U}-agents-guard" "$R/etc/cron.d/${U}-agents-guard"
check "existing file not overwritten" test "$(cat "$R/etc/cron.d/${U}-memory-backup")" = "old local"
check "foreign name not restored" test ! -e "$R/etc/cron.d/evil"
check "missing crontab restored" test -f "$R/fake/crontab"
req k2 'cron-restore'
run
check "second run -> NOTHING MISSING" has k2 "NOTHING MISSING"
teardown

# 10. STOP flag and expiry
setup
touch "$R/etc/${U}-root-requests.STOP"
req s1 'restart coder'
run
check "STOP: request left in place" test -f "$R/var/lib/${U}-requests/requests/s1"
check "STOP: logged" grep -q "STOP flag" "$R/var/log/${U}-root-requests.log"
rm "$R/etc/${U}-root-requests.STOP"
date +%s >"$R/fake/start-channel-coder"   # fresh start: restart is cooling down
req s2 'restart coder'
run
check "fresh unit -> deferred" has s2 DEFER
NEUROOTDEL_RR_NOW=$(( $(date +%s) + 2000 )) run
check "stuck request expires" has s2 EXPIRED
check "expired restart not handed over" test ! -e "$R/tmp/channel-restart-request"
teardown

# 11. Codex r1 regressions
setup
mkfifo "$R/tmp/channel-restart-request"
req f1 'restart coder'
check "FIFO at guard queue does not hang the carrier" timeout 20 bash "$WD"
check "FIFO -> deferred, not QUEUED" has f1 DEFER
teardown
setup
req j1 'restart coder'
run
req j2 'restart coder from=jarvis'
NEUROOTDEL_RR_NOW=$(( $(date +%s) + 300 )) run
check "second restart joins the pending one" has j2 JOINED
req j3 'allow-user coder 666666666'
NEUROOTDEL_RR_NOW=$(( $(date +%s) + 300 )) run
check "allow-user during a pending restart is applied" has j3 "VERIFY OK"
check "config change marks the pending restart stale" test -e "$R/var/lib/${U}-root-requests/verify/.stale-coder"
check "guard queue got one line only" test "$(wc -l <"$R/tmp/channel-restart-request")" -eq 1
date +%s >"$R/fake/start-channel-coder"
NEUROOTDEL_RR_NOW=$(( $(date +%s) + 300 )) run
check "first requester gets VERIFY OK" has j1 "VERIFY OK"
check "joined requester gets VERIFY OK" has j2 "VERIFY OK"
teardown
setup
req q1 'restart coder'
run
date +%s >"$R/fake/start-channel-coder"; rm "$R/tmp/channel-restart-request"
run
check "restart in the same second as hand-over is verified" has q1 "VERIFY OK"
teardown
setup
req w1 'restart coder'
run
NEUROOTDEL_RR_NOW=$(( $(date +%s) + 1300 )) run
check "lost restart -> VERIFY TIMEOUT" has w1 "VERIFY TIMEOUT"
teardown
setup
cp "$R/etc/systemd/system/channel-coder.service" "$R/unit-before"
touch "$R/fake/reload-fail"
req d1 'model coder sonnet'
run
check "daemon-reload failure -> FAIL" has d1 "FAIL"
check "unit restored after reload failure" cmp -s "$R/unit-before" "$R/etc/systemd/system/channel-coder.service"
rm "$R/fake/reload-fail"
sed -i 's/--model opus/--model claude-sonnet-5.5.1/' "$R/etc/systemd/system/channel-coder.service"
grep -m1 '^ExecStart=' "$R/etc/systemd/system/channel-coder.service" | cut -d= -f2- >"$R/fake/stale-channel-coder"
req d2 'model coder claude-sonnet-5.5'
run
check "prefix of the old model is not taken as applied" has d2 "VERIFY FAIL"
rm "$R/fake/stale-channel-coder"
sed -i 's/--model claude-sonnet-5.5.1/--model opus/' "$R/etc/systemd/system/channel-coder.service"
mkdir -p "$R/var/lib/${U}-root-requests/model-prev"; chmod 500 "$R/var/lib/${U}-root-requests/model-prev"
req d3 'model coder sonnet'
run
check "unrecorded previous model -> FAIL, said so" has d3 "previous model NOT recorded"
chmod 700 "$R/var/lib/${U}-root-requests/model-prev"
teardown

# 12. Codex r2 regressions
setup
req t1 'restart coder'
run
NEUROOTDEL_RR_NOW=$(( $(date +%s) + 1300 )) run
check "timeout reported" has t1 "VERIFY TIMEOUT"
check "timeout keeps the pending record" test -f "$R/var/lib/${U}-root-requests/verify/coder"
req t2 'restart coder from=jarvis'
NEUROOTDEL_RR_NOW=$(( $(date +%s) + 1400 )) run
check "restart after timeout joins the kept record" has t2 "JOINED"
check "timeout reported once" test "$(grep -c 'VERIFY TIMEOUT' "$R/var/lib/${U}-requests/results/t1.result")" -eq 1
rm "$R/tmp/channel-restart-request"; echo '{"queue": {}}' >"$R/var/lib/${U}-guard/state.json"
NEUROOTDEL_RR_NOW=$(( $(date +%s) + 1500 )) run
check "dropped by guard -> VERIFY FAIL, record released" bash -c "grep -q 'dropped the restart' '$R/var/lib/${U}-requests/results/t1.result' && test ! -f '$R/var/lib/${U}-root-requests/verify/coder'"
teardown
setup
req s1 'restart coder'
run
echo '{"queue": {"coder": 1}}' >"$R/var/lib/${U}-guard/state.json"; rm "$R/tmp/channel-restart-request"
req s2 'model coder sonnet'
run
req s3 'restart coder'
run
check "restart after config change does not join the old one" has s3 "config changed"
date +%s >"$R/fake/start-channel-coder"; echo '{"queue": {}}' >"$R/var/lib/${U}-guard/state.json"
NEUROOTDEL_RR_NOW=$(( $(date +%s) + 130 )) run
check "old restart verified" has s1 "VERIFY OK"
check "fresh restart handed over after it" has s3 QUEUED
check "stale marker cleared" test ! -e "$R/var/lib/${U}-root-requests/verify/.stale-coder"
teardown
setup
touch "$R/fake/show-fail"
req e1 'restart coder'
run
check "unreadable start time -> no hand-over" bash -c "test ! -e '$R/tmp/channel-restart-request'"
check "unreadable start time -> deferred" has e1 DEFER
rm "$R/fake/show-fail"
NEUROOTDEL_RR_NOW=$(( $(date +%s) + 10 )) run
check "goes once systemd answers" has e1 QUEUED
teardown

# 13. Codex r3 regressions
setup
req h1 'restart coder'
run
rm "$R/tmp/channel-restart-request"; mkfifo "$R/tmp/channel-restart-request"
check "FIFO at queue path while verifying does not hang" timeout 20 bash "$WD"
check "FIFO counts as still held (record kept)" test -f "$R/var/lib/${U}-root-requests/verify/coder"
rm "$R/tmp/channel-restart-request"
echo '{"queue": {}}' >"$R/var/lib/${U}-guard/state.json"; date +%s >"$R/fake/start-channel-coder"
run
check "guard done + new start -> VERIFY OK, not dropped" bash -c "grep -q 'VERIFY OK' '$R/var/lib/${U}-requests/results/h1.result' && ! grep -q dropped '$R/var/lib/${U}-requests/results/h1.result'"
teardown
setup
req x1 'restart coder'
run
rm "$R/tmp/channel-restart-request"; echo '{"queue": {"coder": 1}}' >"$R/var/lib/${U}-guard/state.json"
mkdir -p "$R/var/lib/${U}-root-requests/model-prev"; chmod 500 "$R/var/lib/${U}-root-requests/model-prev"
req x2 'model coder sonnet'
run
check "prev not recorded -> FAIL" has x2 "NOT recorded"
check "stale marked before the change" test -e "$R/var/lib/${U}-root-requests/verify/.stale-coder"
req x3 'restart coder'
run
check "restart after failed-but-applied change does not join" has x3 "config changed"
chmod 700 "$R/var/lib/${U}-root-requests/model-prev"
teardown

# 14. outside test mode a guard.conf that is not root's is refused (root sources it)
setup
unset NEUROOTDEL_RR_TEST
OUT=$(bash "$WD" 2>&1 || true)
check "foreign guard.conf refused" grep -q "is not root's" <<<"$OUT"
check "nothing ran with a foreign conf" test ! -e "$R/var/lib/${U}-root-requests"
teardown

# 15. generic: no names, ids or hosts of a real server in the carrier and its memo
check "carrier: no hardcoded user/ids" bash -c '! grep -nE "neurootdel|edgelab|svetlan|nikolai|vladimir|[0-9]{8,}" "$0"' "$WD"
check "memo: no names/ids" bash -c '! grep -inE "neurootdel|edgelab|svetlan|светлан|nikolai|николай|vladimir|владимир|[0-9]{8,}" "$0"' "${REPO}/templates/shared/TOOLS-root-requests.md"
check "installer: no NOPASSWD ALL anywhere" bash -c '! grep -rnE "NOPASSWD:[[:space:]]*ALL" "$0/install.sh" "$0/lib" "$0/templates"' "$REPO"

# 16. installer wiring: cron (root, 1/min, flock, STOP named), dirs, manifest, @ in each channel agent
export INSTALL_SH_SOURCED_FOR_TESTING=1
CRON_OUT=$(
    # shellcheck disable=SC1091
    source "${REPO}/install.sh" >/dev/null 2>&1
    set +e
    apply_install_names new
    install() { printf 'INSTALL %s\n' "$*"; }
    _install_cron_file() { printf 'FILE=%s\n%s\n' "$1" "$2"; }
    install_root_requests_cron
)
check "cron: file name"            grep -qx 'FILE=neurootdel-root-requests' <<<"$CRON_OUT"
check "cron: every minute as root" grep -qE '^\* \* \* \* \* root /usr/bin/flock -n /run/neurootdel-root-requests.lock /bin/bash /usr/local/lib/neurootdel/agents-root-requests.sh ' <<<"$CRON_OUT"
check "cron: STOP named"           grep -q 'touch /etc/neurootdel-root-requests.STOP' <<<"$CRON_OUT"
check "dirs: requests owned by the agent, 0770" grep -qx 'INSTALL -d -m 0770 -o neurootdel -g neurootdel /var/lib/neurootdel-requests/requests' <<<"$CRON_OUT"
check "dirs: results root:agent 0750" grep -qx 'INSTALL -d -m 0750 -o root -g neurootdel /var/lib/neurootdel-requests/results' <<<"$CRON_OUT"
check "cron: called from install_guard" bash -c "sed -n '/^install_guard() {/,/^}/p' '${REPO}/install.sh' | grep -qx '    install_root_requests_cron'"
check "manifest: slot expected"    grep -q 'root-requests::agents-root-requests.sh::' "${REPO}/lib/cron-manifest-watchdog.sh"
check "manifest: script expected"  grep -q '"$L/agents-root-requests.sh"' "${REPO}/lib/cron-manifest-watchdog.sh"
check "sudoers: carrier needs no sudo line" bash -c "! sed -n '/^render_sudoers() {/,/^}/p' '${REPO}/install.sh' | grep -q root-requests"

TD="$(mktemp -d /tmp/rrrefs.XXXXXX)"
REFS_RC=$(
    # shellcheck disable=SC1091
    source "${REPO}/install.sh" >/dev/null 2>&1
    set +e
    apply_install_names new
    as_agent() { "$@"; }
    step() { :; }; ok() { :; }; warn() { :; }; err() { :; }
    AGENT_HOME="$TD/home"; GUARD_LIB_DIR=/usr/local/lib/neurootdel; OPERATOR_NAME=Owner
    TEMPLATES_DIR="${REPO}/templates"; CODER_INSTALLED=1
    for a in jarvis coder; do mkdir -p "$AGENT_HOME/.claude-lab/$a/.claude"; printf '# %s\n' "$a" >"$AGENT_HOME/.claude-lab/$a/.claude/CLAUDE.md"; done
    install_team_refs >/dev/null 2>&1; echo $?
)
check "refs: rc 0"                 test "$REFS_RC" = 0
M="$TD/home/.claude-lab/shared/TOOLS-root-requests.md"
check "memo: rendered"             test -s "$M"
check "memo: placeholders filled"  bash -c '! grep -q "{{" "$0"' "$M"
check "memo: paths of this install" grep -q '/var/lib/neurootdel-requests/requests/my-req.tmp' "$M"
for a in jarvis coder; do
    check "@ memo in $a CLAUDE.md" grep -qx '@~/.claude-lab/shared/TOOLS-root-requests.md' "$TD/home/.claude-lab/$a/.claude/CLAUDE.md"
done
rm -rf "${TD:?}"

echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
