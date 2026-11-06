#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329  # globals read by sourced fns, overrides
# Tests for the off-server memory copy, no root and no network needed (the remote is a local bare repo):
#   lib/memory-offsite.sh        copy, media and secret excludes, masking, gate (binary, key block,
#                                broken search), no force push on a moved remote, OFF without a repo,
#                                STOP, --auto outside the hour, empty sources;
#   lib/memory-offsite-watch.sh  morning line to the owner: no repo (once a week), stale / never copied
#                                (once a day), fresh = silent, token only through stdin;
#   lib/offsite-setup.sh         deploy key + pinned host key, repo forms, --off, private key never shown;
#   install.sh                   OFFSITE_REPO in guard.conf (env, https form, kept on re-run, bad value),
#                                cron file of the copy and the watch.
# Run: bash tests/test_memory_offsite.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TDIR="$(mktemp -d)"
trap 'rm -rf "${TDIR:?}"' EXIT
M="${REPO}/lib/memory-offsite.sh"
W="${REPO}/lib/memory-offsite-watch.sh"
S="${REPO}/lib/offsite-setup.sh"

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

check "copy: syntax"                    bash -n "$M"
check "watch: syntax"                   bash -n "$W"
check "setup: syntax"                   bash -n "$S"
check "copy: executable"                test -x "$M"
check "watch: executable"               test -x "$W"
check "setup: executable"               test -x "$S"
check "copy: never forces a push"       not grep -qE 'push[^|]*(-f\b|--force|\+HEAD|\+refs)' "$M"

# Fixture shapes are assembled from parts so this file never holds a literal secret shape.
BOT_TOKEN="1234567890:AA$(printf 'h%.0s' {1..33})"
ANT_KEY="sk-ant-api03-$(printf 'Q%.0s' {1..40})"
OAI_KEYS=("sk-proj-ab_$(printf 'Z%.0s' {1..30})-$(printf 'Y%.0s' {1..20})" "sk-svcacct-x-$(printf 'W%.0s' {1..40})" "sk-admin-$(printf 'V%.0s' {1..10})_$(printf 'U%.0s' {1..30})")
KEY_BLOCK="-----BEGIN OPENSSH PRIVATE"" KEY-----"

H="${TDIR}/home"; ST="${TDIR}/offsite"; BARE="${TDIR}/remote.git"
mkhome() {
    rm -rf "$H" "$ST" "$BARE"
    local ws="$H/.claude-lab/jarvis/.claude"
    mkdir -p "$ws/core/hot" "$ws/memory" "$ws/library" "$ws/secrets" "$H/.claude-lab/richard/.claude/core" \
        "$H/.claude/projects/-home-x--claude-lab-jarvis--claude-dashi-plugin-claude-code/memory" \
        "$H/.claude-lab/shared" "$H/.hermes/memories" "$H/outside"
    echo "jarvis rules" >"$ws/core/rules.md"
    echo "richard rules" >"$H/.claude-lab/richard/.claude/core/rules.md"
    echo "# Jarvis" >"$ws/CLAUDE.md"
    echo "open item" >"$ws/core/hot/handoff.md"
    printf 'bot is %s here\n' "$BOT_TOKEN" >"$ws/core/leaky-note.md"
    printf 'key %s\n' "$ANT_KEY" >"$ws/memory/ant.md"
    printf 'OPENAI=%s\n' "${OAI_KEYS[@]}" >"$ws/core/oai.md"
    echo "auto memory" >"$H/.claude/projects/-home-x--claude-lab-jarvis--claude-dashi-plugin-claude-code/memory/MEMORY.md"
    echo team >"$H/.claude-lab/shared/team-rules.md"
    echo soul >"$H/.hermes/SOUL.md"; echo mem >"$H/.hermes/memories/MEMORY.md"
    echo "TOP=secret" >"$H/.hermes/.env"
    echo "s3cr3t" >"$ws/secrets/pass.txt"
    echo "X=1" >"$ws/core/.env"
    printf '\x89PNG\x00\x00' >"$ws/library/shot.PNG"
    printf '%%PDF\x00\x00' >"$ws/core/report.pdf"
    echo "outside secret body" >"$H/outside/secret.txt"
    ln -s "$H/outside/secret.txt" "$ws/core/link-out.md"
    git init -q --bare -b main "$BARE"
    write_conf "git@github.com:owner/agents-memory.git"
}
write_conf() {
    cat >"${TDIR}/guard.conf" <<EOF
AGENT_USER="neurootdel"
AGENT_HOME="${H}"
CONFIG_ROOT="${TDIR}/etc"
CHANNEL_AGENTS="jarvis"
MAIN_AGENT="jarvis"
OWNER_TG_ID="555"
OWNER_TIMEZONE="Europe/Moscow"
RICHARD_ENV="${TDIR}/richard.env"
OFFSITE_REPO="$1"
EOF
}
export NEUROOTDEL_GUARD_CONF="${TDIR}/guard.conf" OFFSITE_STATE="$ST"
copy() { RC=0; OFFSITE_REMOTE="${REMOTE-$BARE}" bash "$M" "$@" >/dev/null 2>"${TDIR}/err" || RC=$?; }
remote_head() { git --git-dir="$BARE" rev-parse -q --verify refs/heads/main 2>/dev/null || true; }
remote_files() { git --git-dir="$BARE" ls-tree -r --name-only main 2>/dev/null; }
remote_all() { git --git-dir="$BARE" log -p --all 2>/dev/null; }
status_is() { [[ "$(cut -d' ' -f1 "$ST/last" 2>/dev/null)" == "$1" ]]; }

# --- a clean night ------------------------------------------------------------------------------
mkhome; copy
check "copy: exit 0"                    test "$RC" -eq 0
check "copy: status OK"                 status_is OK
check "copy: status bound to the remote" test "$(cut -d' ' -f3 "$ST/last")" = "$(printf '%s' "$BARE" | sha256sum | cut -c1-12)"
check "copy: reached the remote"        test -n "$(remote_head)"
check "copy: rules.md copied"           grep -qx 'home/.claude-lab/jarvis/.claude/core/rules.md' <<<"$(remote_files)"
check "copy: richard copied"            grep -qx 'home/.claude-lab/richard/.claude/core/rules.md' <<<"$(remote_files)"
check "copy: handoff copied"            grep -q 'core/hot/handoff.md' <<<"$(remote_files)"
check "copy: auto-memory copied"        grep -q 'projects/.*/memory/MEMORY.md' <<<"$(remote_files)"
check "copy: auditor memory copied"     grep -qx 'home/.hermes/memories/MEMORY.md' <<<"$(remote_files)"
check "copy: auditor .env not copied"   not grep -q '\.env' <<<"$(remote_files)"
check "copy: secrets/ not copied"       not grep -q 'secrets/' <<<"$(remote_files)"
check "copy: media .PNG not copied"     not grep -qi 'shot.png' <<<"$(remote_files)"
check "copy: media .pdf not copied"     not grep -qi 'report.pdf' <<<"$(remote_files)"
check "copy: bot token masked"          not grep -q "$BOT_TOKEN" <<<"$(remote_all)"
check "copy: Anthropic key masked"      not grep -q "$ANT_KEY" <<<"$(remote_all)"
for k in "${OAI_KEYS[@]}"; do
    check "copy: ${k%%-*-*} ${k:3:7}.. key masked" not grep -qF -e "${k:12}" <<<"$(remote_all)"
done
check "copy: mask placeholder present"  grep -q 'REDACTED-telegram-bot' <<<"$(remote_all)"
check "copy: source left untouched"     grep -q "$BOT_TOKEN" "$H/.claude-lab/jarvis/.claude/core/leaky-note.md"
check "copy: symlink kept as a link"    grep -q 'link-out.md' <<<"$(remote_files)"
check "copy: link target never copied"  not grep -q 'outside secret body' <<<"$(remote_all)"
check "copy: log holds no secret"       not grep -qE "${BOT_TOKEN}|${ANT_KEY}" "$ST/offsite.log"
check "copy: state dir 700"             test "$(stat -c %a "$ST")" = 700
H1=$(remote_head)
copy
check "unchanged: exit 0"               test "$RC" -eq 0
check "unchanged: no new commit"        test "$(remote_head)" = "$H1"
check "unchanged: logged up to date"    grep -q 'OK up to date' "$ST/offsite.log"
echo "new decision" >>"$H/.claude-lab/jarvis/.claude/core/rules.md"; copy
check "changed: new commit pushed"      test "$(remote_head)" != "$H1"
check "changed: fast-forward only"      git --git-dir="$BARE" merge-base --is-ancestor "$H1" "$(remote_head)"

# --- gate: fail closed -------------------------------------------------------------------------
mkhome; copy; H1=$(remote_head)
printf 'data\x00\x01' >"$H/.claude-lab/jarvis/.claude/core/blob.bin"; copy
check "binary: exit 3"                  test "$RC" -eq 3
check "binary: status ERR"              status_is ERR
check "binary: nothing pushed"          test "$(remote_head)" = "$H1"
check "binary: path in the log"         grep -q 'BINARY home/.claude-lab/jarvis/.claude/core/blob.bin' "$ST/offsite.log"
rm "$H/.claude-lab/jarvis/.claude/core/blob.bin"
printf '%s\nabc\n' "$KEY_BLOCK" >"$H/.claude-lab/jarvis/.claude/core/oops.md"; copy
check "key block: exit 3"               test "$RC" -eq 3
check "key block: nothing pushed"       test "$(remote_head)" = "$H1"
check "key block: logged by path only"  grep -q 'SECRET\[private-key\] .*oops.md:1' "$ST/offsite.log"
rm "$H/.claude-lab/jarvis/.claude/core/oops.md"
RC=0; OFFSITE_TEST_BREAK_SCAN=1 OFFSITE_REMOTE="$BARE" bash "$M" >/dev/null 2>&1 || RC=$?
check "broken search: exit 3"           test "$RC" -eq 3
check "broken search: nothing pushed"   test "$(remote_head)" = "$H1"
RC=0; OFFSITE_DRY=1 OFFSITE_REMOTE="$BARE" bash "$M" >/dev/null 2>&1 || RC=$?
check "dry run: exit 0, nothing pushed" bash -c '[[ "$0" -eq 0 && "$1" == "$2" ]]' "$RC" "$(remote_head)" "$H1"

# Names and link targets are committed too: a secret shape there stops the run, nothing of it logged.
ln -s "https://api.telegram.org/bot${BOT_TOKEN}/getMe" "$H/.claude-lab/jarvis/.claude/core/tg-link.md"; copy
check "secret in a link target: exit 3"  test "$RC" -eq 3
check "secret in a link target: not pushed" test "$(remote_head)" = "$H1"
check "secret in a link target: not logged" not grep -q "$BOT_TOKEN" "$ST/offsite.log"
rm "$H/.claude-lab/jarvis/.claude/core/tg-link.md"
: >"$H/.claude-lab/jarvis/.claude/core/x${BOT_TOKEN}.md"; copy
check "secret in a file name: exit 3"    test "$RC" -eq 3
check "secret in a file name: not pushed" test "$(remote_head)" = "$H1"
check "secret in a file name: not logged" not grep -q "${BOT_TOKEN#*:}" "$ST/offsite.log"
find "$H/.claude-lab/jarvis/.claude/core" -name '*hhhhhhhh*' -delete
copy
check "clean again: pushed"              test "$RC" -eq 0

# A .gitignore inside the memory never drops a file that passed the gate.
mkhome; printf '*\n' >"$H/.claude-lab/jarvis/.claude/core/.gitignore"; copy
check ".gitignore in memory: exit 0"     test "$RC" -eq 0
check ".gitignore in memory: rules.md on GitHub" grep -qx 'home/.claude-lab/jarvis/.claude/core/rules.md' <<<"$(remote_files)"
# rsync messages (they name files) never reach the log.
mkhome; : >"$H/.claude-lab/jarvis/.claude/core/x${BOT_TOKEN}.md"; chmod 000 "$H/.claude-lab/jarvis/.claude/core/x${BOT_TOKEN}.md"; copy
check "unreadable secret-named file: not in the log" not grep -q "${BOT_TOKEN#*:}" "$ST/offsite.log"
check "unreadable secret-named file: not pushed" test -z "$(remote_head)"
chmod 600 "$H/.claude-lab/jarvis/.claude/core/x${BOT_TOKEN}.md"
# A skipped run says so to the setup command: exit OFFSITE_SKIP_RC, never 0.
mkhome; mkdir -p "$ST"; touch "$ST/STOP"; RC=0; OFFSITE_SKIP_RC=5 OFFSITE_REMOTE="$BARE" bash "$M" >/dev/null 2>&1 || RC=$?
check "skip rc: STOP exits 5"            test "$RC" -eq 5
rm "$ST/STOP"; exec 8>"$ST/.lock"; flock -n 8
RC=0; OFFSITE_SKIP_RC=5 OFFSITE_REMOTE="$BARE" bash "$M" >/dev/null 2>&1 || RC=$?
check "skip rc: held lock exits 5"       test "$RC" -eq 5
exec 8>&-

# --- a moved remote is never forced ------------------------------------------------------------
mkhome; copy
OTHER="${TDIR}/other"; rm -rf "$OTHER"; git clone -q "$BARE" "$OTHER"
echo hand >"$OTHER/hand.md"; git -C "$OTHER" add hand.md
git -C "$OTHER" -c user.name=t -c user.email=t@t commit -q -m hand; git -C "$OTHER" push -q origin HEAD:main
H2=$(remote_head)
echo "more" >>"$H/.claude-lab/jarvis/.claude/core/rules.md"; copy
check "moved remote: exit 4"            test "$RC" -eq 4
check "moved remote: remote untouched"  test "$(remote_head)" = "$H2"
check "moved remote: status ERR"        status_is ERR
check "moved remote: says someone wrote" grep -q 'кто-то писал' "$ST/last"

# --- off, stop, hour, empty sources ------------------------------------------------------------
mkhome; write_conf ""; REMOTE="" copy
check "no repo: exit 0"                 test "$RC" -eq 0
check "no repo: status OFF"             status_is OFF
check "no repo: no staging repo"        test ! -e "$ST/repo"
mkhome; mkdir -p "$ST"; touch "$ST/STOP"; copy
check "STOP: exit 0, nothing pushed"    bash -c '[[ "$0" -eq 0 && -z "$1" ]]' "$RC" "$(remote_head)"
mkhome
for z in Etc/GMT+1 Etc/GMT+2 Etc/GMT+3; do [[ "$(TZ=$z date +%-H)" != 3 ]] && break; done
sed -i "s|^OWNER_TIMEZONE=.*|OWNER_TIMEZONE=\"$z\"|" "${TDIR}/guard.conf"; copy --auto
check "--auto off the hour: no run"     bash -c '[[ "$0" -eq 0 && ! -e "$1/last" ]]' "$RC" "$ST"
mkhome; rm -rf "$H/.claude-lab" "$H/.claude" "$H/.hermes"; mkdir -p "$H"; copy
check "empty sources: exit 2"           test "$RC" -eq 2
check "empty sources: nothing pushed"   test -z "$(remote_head)"
mkhome; REMOTE="git@github.com:owner/agents-memory.git" copy
check "ssh remote, no key: exit 1"      test "$RC" -eq 1
check "ssh remote, no key: says setup"  grep -q 'neurootdel-offsite-setup' "$ST/last"

# --- setup command -----------------------------------------------------------------------------
mkhome; write_conf ""
export OFFSITE_SETUP_TEST=1 OFFSITE_WATCH_STATE="${TDIR}/wst"
OUT=$(bash "$S" --init 2>&1); RC=$?
check "setup --init: key made"          test -f "$H/.ssh/offsite_ed25519" -a -f "$H/.ssh/offsite_ed25519.pub"
check "setup --init: ed25519"           grep -q '^ssh-ed25519 ' "$H/.ssh/offsite_ed25519.pub"
check "setup --init: GitHub key pinned" grep -qx 'github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl' "$H/.ssh/known_hosts_offsite"
check "setup --init: .ssh 700"          test "$(stat -c %a "$H/.ssh")" = 700
K1=$(sha256sum <"$H/.ssh/offsite_ed25519")
bash "$S" --init >/dev/null 2>&1
check "setup --init: key kept on re-run" test "$(sha256sum <"$H/.ssh/offsite_ed25519")" = "$K1"
OUT=$(bash "$S" 2>&1)
check "setup: shows the public key"     grep -qF "$(cat "$H/.ssh/offsite_ed25519.pub")" <<<"$OUT"
check "setup: says Deploy keys + write" grep -q 'Allow write access' <<<"$OUT"
check "setup: says no copy now"         grep -q 'копии вне сервера НЕТ' <<<"$OUT"
check "setup: private key never shown"  not grep -q 'PRIVATE' <<<"$OUT"
cp "$H/.ssh/offsite_ed25519.pub" "${TDIR}/pub.keep"
echo "root-only secret line" >"${TDIR}/rootfile"; ln -sfn "${TDIR}/rootfile" "$H/.ssh/offsite_ed25519.pub"
OUT=$(bash "$S" 2>&1)
check "setup: non-key .pub never printed" not grep -q 'root-only secret line' <<<"$OUT"
rm "$H/.ssh/offsite_ed25519.pub"; cp "${TDIR}/pub.keep" "$H/.ssh/offsite_ed25519.pub"
bash "$S" https://github.com/Owner-1/my.memory >/dev/null 2>&1
check "setup: https form normalized"    grep -qx 'OFFSITE_REPO="git@github.com:Owner-1/my.memory.git"' "${TDIR}/guard.conf"
bash "$S" git@github.com:owner/second.git >/dev/null 2>&1
check "setup: replaced, one line"       test "$(grep -c '^OFFSITE_REPO=' "${TDIR}/guard.conf")" -eq 1
check "setup: ssh form kept"            grep -qx 'OFFSITE_REPO="git@github.com:owner/second.git"' "${TDIR}/guard.conf"
RC=0; bash "$S" 'git@evil.com:x/y.git' >/dev/null 2>&1 || RC=$?
check "setup: foreign host refused"     test "$RC" -eq 2
RC=0; bash "$S" 'git@github.com:a/b.git";touch /tmp/x;"' >/dev/null 2>&1 || RC=$?
check "setup: injection refused"        test "$RC" -eq 2
check "setup: refused leaves conf"      grep -qx 'OFFSITE_REPO="git@github.com:owner/second.git"' "${TDIR}/guard.conf"
# Access granted (test hook): setup makes the first copy at once and says so only when it happened.
mkdir -p "$H/backups/offsite"; rm -rf "$BARE"; git init -q --bare -b main "$BARE"
OUT=$(OFFSITE_STATE="$H/backups/offsite" OFFSITE_REMOTE="$BARE" OFFSITE_SETUP_TEST_ACCESS=0 bash "$S" git@github.com:owner/second.git 2>&1); RC=$?
check "setup, access: first copy made"  bash -c '[[ "$0" -eq 0 && -n "$1" ]]' "$RC" "$(remote_head)"
check "setup, access: says it is there" grep -q 'Первая копия на GitHub лежит' <<<"$OUT"
touch "$H/backups/offsite/STOP"
RC=0; OUT=$(OFFSITE_STATE="$H/backups/offsite" OFFSITE_REMOTE="$BARE" OFFSITE_SETUP_TEST_ACCESS=0 bash "$S" git@github.com:owner/second.git 2>&1) || RC=$?
check "setup, STOP: no false success"   bash -c '[[ "$0" -eq 1 ]] && ! grep -q "лежит" <<<"$1"' "$RC" "$OUT"
rm -f "$H/backups/offsite/STOP"
# Switching to another repo drops the old repo's OK (status and the watch's last OK).
printf '%s\n' 1800000000 >"${TDIR}/wstate-last-ok"; mkdir -p "${TDIR}/wst"; mv "${TDIR}/wstate-last-ok" "${TDIR}/wst/last-ok"
RC=0; OFFSITE_WATCH_STATE="${TDIR}/wst" OFFSITE_SETUP_TEST_ACCESS=1 bash "$S" git@github.com:owner/third.git >/dev/null 2>&1 || RC=$?
check "setup, other repo, no access: exit 1" test "$RC" -eq 1
check "setup, other repo: old status dropped" test ! -e "$H/backups/offsite/last"
check "setup, other repo: watch last OK dropped" test ! -e "${TDIR}/wst/last-ok"
mkdir -p "$H/backups/offsite"; printf 'OK %s x\n' "$(date +%s)" >"$H/backups/offsite/last"
OFFSITE_WATCH_STATE="${TDIR}/wst" OFFSITE_SETUP_TEST_ACCESS=1 bash "$S" git@github.com:owner/third.git >/dev/null 2>&1 || true
check "setup, same repo again: status kept" test -e "$H/backups/offsite/last"
bash "$S" --off >/dev/null 2>&1
check "setup --off: repo emptied"       grep -qx 'OFFSITE_REPO=""' "${TDIR}/guard.conf"
check "setup: conf still sources"       bash -c '. "$0" && [[ -z "$OFFSITE_REPO" && "$AGENT_USER" == neurootdel ]]' "${TDIR}/guard.conf"
unset OFFSITE_SETUP_TEST OFFSITE_WATCH_STATE

# --- morning watch -----------------------------------------------------------------------------
WS="${TDIR}/watch"
mkdir -p "${TDIR}/etc/jarvis"
TOKEN_J="123456789:AAHabcdefghijklmnopqrstuvwxyz0123456"
printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TOKEN_J" >"${TDIR}/etc/jarvis/channel.env"
NOW0=1800000000
watch() { OFFSITE_WATCH_DRY=1 OFFSITE_WATCH_STATE="$WS" OFFSITE_WATCH_NOW="${1:-$NOW0}" bash "$W" "${@:2}"; }
RTAG=$(printf '%s' git@github.com:owner/agents-memory.git | sha256sum | cut -c1-12)
lastline() { mkdir -p "$H/backups/offsite"; printf '%s %s %s %s\n' "$1" "$2" "${4:-$RTAG}" "$3" >"$H/backups/offsite/last"; }

mkhome; rm -rf "$WS"; write_conf ""
OUT=$(watch)
check "watch, no repo: tells the owner" grep -q 'Копии памяти агентов вне сервера нет' <<<"$OUT"
check "watch, no repo: says how"        grep -q 'sudo neurootdel-offsite-setup' <<<"$OUT"
check "watch, no repo: to the owner"    grep -q 'chat=555' <<<"$OUT"
check "watch, no repo: no em dash"      not grep -q '—' <<<"$OUT"
OUT=$(watch $((NOW0 + 86400)))
check "watch, no repo: once a week"     test -z "$OUT"
OUT=$(watch $((NOW0 + 7 * 86400)))
check "watch, no repo: again in 7 days" grep -q 'вне сервера нет' <<<"$OUT"

mkhome; rm -rf "$WS"; lastline OK $((NOW0 - 3600)) "выгружено"
OUT=$(watch)
check "watch, fresh OK: silent"         test -z "$OUT"
lastline ERR $((NOW0 + 20 * 3600)) "выгрузка на GitHub не прошла"
OUT=$(watch $((NOW0 + 24 * 3600)))
check "watch, ERR after a fresh OK: silent" test -z "$OUT"
OUT=$(watch $((NOW0 + 30 * 3600)))
check "watch, stale: tells the owner"   grep -q 'не обновлялась с' <<<"$OUT"
check "watch, stale: last error named"  grep -q 'Последняя ошибка: выгрузка на GitHub не прошла' <<<"$OUT"
check "watch, stale: names the log"     grep -q 'offsite.log' <<<"$OUT"
OUT=$(watch $((NOW0 + 31 * 3600)))
check "watch, stale: once a day"        test -z "$OUT"
OUT=$(watch $((NOW0 + 54 * 3600)))
check "watch, stale: next day again"    grep -q 'не обновлялась с' <<<"$OUT"

# An OK of another repo (address changed since) says nothing about this one; nor does its stored last OK.
mkhome; rm -rf "$WS"; lastline OK $((NOW0 - 3600)) "выгружено" "$(printf '%s' git@github.com:o/old.git | sha256sum | cut -c1-12)"
mkdir -p "$WS"; printf '%s %s\n' "$(printf '%s' git@github.com:o/old.git | sha256sum | cut -c1-12)" "$NOW0" >"$WS/last-ok"
touch -d '@'"$((NOW0 - 30 * 3600))" "${TDIR}/guard.conf"
OUT=$(watch)
check "watch, OK of another repo: not trusted" grep -q 'ни разу не выгрузилась' <<<"$OUT"
# A time from the future is not trusted (it would silence the watch for years), not even once stored.
mkhome; rm -rf "$WS"; lastline OK 4102444800 "выгружено"
OUT=$(watch $((NOW0 + 30 * 3600)))
check "watch, OK from the future: not trusted" grep -q 'ни разу\|не обновлялась' <<<"$OUT"
check "watch, future OK not stored"     not grep -q 4102444800 "$WS/last-ok" 2>/dev/null
mkhome; rm -rf "$WS" "$H/backups"; touch -d '@'"$NOW0" "${TDIR}/guard.conf"
OUT=$(watch $((NOW0 + 3600)))
check "watch, never, fresh setup: silent" test -z "$OUT"
OUT=$(watch $((NOW0 + 30 * 3600)))
check "watch, never copied: says so"    grep -q 'ни разу не выгрузилась' <<<"$OUT"

mkhome; rm -rf "$WS"; mkdir -p "$WS"; touch "$WS/STOP"; write_conf ""
OUT=$(watch)
check "watch: STOP = silent"            test -z "$OUT"
rm -f "$WS/STOP"
# 09:xx on the owner's clock only
N9=$(TZ=Europe/Moscow date -d '2027-01-15 09:40' +%s); N10=$(TZ=Europe/Moscow date -d '2027-01-15 10:40' +%s)
rm -rf "$WS"; OUT=$(watch "$N10" --auto)
check "watch --auto 10:40: silent"      test -z "$OUT"
rm -rf "$WS"; OUT=$(watch "$N9" --auto)
check "watch --auto 09:40: runs"        grep -q 'вне сервера нет' <<<"$OUT"
# Real send path with a stub curl: token only through stdin.
BIN="${TDIR}/bin"; mkdir -p "$BIN"
cat >"${BIN}/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${TDIR}/curl.argv"; cat >>"${TDIR}/curl.stdin"; echo '{"ok":true}'
EOF
chmod +x "${BIN}/curl"
rm -rf "$WS"; OUT=$(PATH="${BIN}:${PATH}" OFFSITE_WATCH_STATE="$WS" OFFSITE_WATCH_NOW="$NOW0" bash "$W")
check "watch send: token not in argv"   not grep -q 'AAHabc' "${TDIR}/curl.argv"
check "watch send: token via stdin"     grep -q "bot${TOKEN_J}/sendMessage" "${TDIR}/curl.stdin"
check "watch send: token not printed"   not grep -q 'AAHabc' <<<"$OUT"
check "watch send: marked as sent"      test -f "$WS/sent-off"

# --- installer: guard.conf key and cron --------------------------------------------------------
export INSTALL_SH_SOURCED_FOR_TESTING=1 PYTHONDONTWRITEBYTECODE=1 NEUROOTDEL_TEMPLATES_DIR="${REPO}/templates"
# shellcheck disable=SC1091
source "${REPO}/install.sh"
set +e
warn() { printf 'warn: %s\n' "$*" >>"${TDIR}/warns"; }
GC="${TDIR}/gc"
render_guard_conf "" >"$GC"
check "conf: empty by default"          grep -qx 'OFFSITE_REPO=""' "$GC"
NEUROOTDEL_BACKUP_REPO="https://github.com/own/mem.git" render_guard_conf "" >"${GC}.1"
check "conf: https form -> ssh"         grep -qx 'OFFSITE_REPO="git@github.com:own/mem.git"' "${GC}.1"
render_guard_conf "${GC}.1" >"${GC}.2"
check "conf: kept on re-run"            grep -qx 'OFFSITE_REPO="git@github.com:own/mem.git"' "${GC}.2"
NEUROOTDEL_BACKUP_REPO="" render_guard_conf "${GC}.1" >"${GC}.3"
check "conf: empty env clears"          grep -qx 'OFFSITE_REPO=""' "${GC}.3"
: >"${TDIR}/warns"
NEUROOTDEL_BACKUP_REPO='git@github.com:x/y.git$(id)' render_guard_conf "" >"${GC}.4"
check "conf: bad value -> off + warn"   bash -c 'grep -qx "OFFSITE_REPO=\"\"" "$0" && grep -q BACKUP_REPO "$1"' "${GC}.4" "${TDIR}/warns"
check "conf: sources with the key"      bash -c '. "$0" && [[ "$OFFSITE_REPO" == git@github.com:own/mem.git ]]' "${GC}.1"
CRONF=$(declare -f install_memory_offsite)
check "cron: copy as the agent user"    grep -q 'memory-offsite.sh --auto' <<<"$CRONF"
check "cron: watch as root"             grep -q 'root /bin/bash ${GUARD_LIB_DIR}/memory-offsite-watch.sh --auto' <<<"$CRONF"
check "cron: key made at install"       grep -q 'offsite-setup.sh" --init' <<<"$CRONF"
check "install_guard calls it"          grep -q 'install_memory_offsite' <<<"$(declare -f install_guard)"
check "setup command name"              test "$OFFSITE_SETUP_BIN" = /usr/local/bin/neurootdel-offsite-setup

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
