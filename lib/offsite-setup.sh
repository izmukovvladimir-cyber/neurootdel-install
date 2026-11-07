#!/usr/bin/env bash
# offsite-setup.sh (as /usr/local/bin/neurootdel-offsite-setup) -- turns on the off-server copy of the
# agents' memory (memory-offsite.sh) on the owner's private GitHub repo. Installed by neurootdel-install
# into <lib dir>, settings in <lib dir>/guard.conf. Run as root:
#
#   sudo neurootdel-offsite-setup                    show the deploy key, the steps and the current state
#   sudo neurootdel-offsite-setup <repo>             point the copy at that repo and check the access
#        <repo> = git@github.com:<owner>/<name>.git or https://github.com/<owner>/<name>
#   sudo neurootdel-offsite-setup --off              turn the copy off (OFFSITE_REPO="")
#   sudo neurootdel-offsite-setup --init             only make the key and the pinned host key (installer)
#
# The key: ~/.ssh/offsite_ed25519 of the agent user (ed25519, no passphrase), made once, never printed
# except its PUBLIC half. The owner adds that public half to HIS repo: Settings -> Deploy keys -> Add
# deploy key, "Allow write access" on. A deploy key opens that one repo only.
# GitHub's ed25519 host key is pinned in ~/.ssh/known_hosts_offsite (SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU,
# published at api.github.com/meta), StrictHostKeyChecking=yes in memory-offsite.sh.
# Tests: NEUROOTDEL_GUARD_CONF, OFFSITE_SETUP_TEST=1 (no root check, commands run as the caller,
#        no network: the access check is skipped).
set -euo pipefail
umask 022

LIB="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CONF="${NEUROOTDEL_GUARD_CONF:-$LIB/guard.conf}"
[[ -f "$CONF" ]] || { echo "Нет ${CONF}: установщик не дошёл до сторожа. Запусти установщик снова." >&2; exit 2; }
# shellcheck disable=SC1090
. "$CONF"
U="${AGENT_USER:?AGENT_USER missing in guard.conf}"
H="${AGENT_HOME:?AGENT_HOME missing in guard.conf}"
TEST="${OFFSITE_SETUP_TEST:-0}"
KEY="$H/.ssh/offsite_ed25519"
KH="$H/.ssh/known_hosts_offsite"
GITHUB_HOST_KEY='github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl'

if [[ "$TEST" != 1 && $EUID -ne 0 ]]; then
    echo "Нужен root: sudo $(basename "$0") $*" >&2
    exit 2
fi
as_agent() { if [[ "$TEST" == 1 ]]; then "$@"; else runuser -u "$U" -- "$@"; fi; }

# normalize_repo <text> -- prints git@github.com:<owner>/<name>.git or fails.
normalize_repo() {
    local r=$1 re_ssh='^git@github\.com:([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$' re_https='^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/?$'
    local owner name
    if [[ "$r" =~ $re_ssh || "$r" =~ $re_https ]]; then
        owner="${BASH_REMATCH[1]}"; name="${BASH_REMATCH[2]%.git}"
        [[ -n "$name" && "$owner" != .* && "$name" != .* ]] || return 1
        printf 'git@github.com:%s/%s.git' "$owner" "$name"
        return 0
    fi
    return 1
}

# agent_read <file> -- the first line of a file in the agent's home, read AS the agent: a link the agent
# put there never makes root print a root-only file. Max 2000 bytes.
agent_read() { as_agent head -n 1 -- "$1" 2>/dev/null | head -c 2000 || true; }

# pubkey -- the public deploy key, only when it has the shape of one (else empty).
pubkey() {
    local k
    k=$(agent_read "${KEY}.pub")
    [[ "$k" =~ ^ssh-ed25519\ [A-Za-z0-9+/]+=*(\ [A-Za-z0-9._@-]*)?$ ]] && printf '%s' "$k"
    return 0
}

# ensure_key -- the deploy key and the pinned host key, made by the agent user in its own ~/.ssh.
ensure_key() {
    as_agent mkdir -p "$H/.ssh"
    as_agent chmod 700 "$H/.ssh"
    if [[ ! -f "$KEY" ]]; then
        as_agent ssh-keygen -q -t ed25519 -N '' -C "${U}-memory-offsite" -f "$KEY" >/dev/null
    fi
    if [[ "$(agent_read "$KH")" != "$GITHUB_HOST_KEY" ]]; then
        printf '%s\n' "$GITHUB_HOST_KEY" | as_agent tee "$KH" >/dev/null
        as_agent chmod 600 "$KH"
    fi
}

# set_repo <value> -- OFFSITE_REPO in guard.conf (root file), replaced in place or appended.
# Another repo than before: the last status and the watch's last OK belong to the OLD repo, so both
# are dropped (an OK of repo A must never stand for repo B in neurootdel-verify or the morning watch).
set_repo() {
    local v=$1 tmp
    if [[ "$v" != "${OFFSITE_REPO:-}" ]]; then
        as_agent rm -f -- "$H/backups/offsite/last"
        rm -f -- "${OFFSITE_WATCH_STATE:-/var/lib/${U}-offsite-watch}/last-ok"
    fi
    tmp=$(mktemp)
    if grep -q '^OFFSITE_REPO=' "$CONF"; then
        sed "s|^OFFSITE_REPO=.*|OFFSITE_REPO=\"${v}\"|" "$CONF" >"$tmp"
    else
        cat "$CONF" >"$tmp"
        printf 'OFFSITE_REPO="%s"\n' "$v" >>"$tmp"
    fi
    chmod 0644 "$tmp"
    if [[ "$TEST" == 1 ]]; then mv -f "$tmp" "$CONF"; else install -m 0644 -o root -g root "$tmp" "$CONF"; rm -f "$tmp"; fi
}

# access_ok <repo> -- the deploy key can reach the repo (read). Writes are proven by the first night.
access_ok() {
    [[ "$TEST" == 1 ]] && return "${OFFSITE_SETUP_TEST_ACCESS:-2}"
    as_agent env GIT_SSH_COMMAND="ssh -i $KEY -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=20 -o UserKnownHostsFile=$KH -o StrictHostKeyChecking=yes" \
        timeout 60 git ls-remote "$1" >/dev/null 2>&1
}

show_steps() {
    cat <<EOF

Копия памяти агентов вне сервера (приватный репозиторий GitHub).
1. На github.com создай ПРИВАТНЫЙ пустой репозиторий (например ${U}-memory).
2. В нём: Settings -> Deploy keys -> Add deploy key, галочка «Allow write access». Ключ (одна строка):

$(pubkey || true)

3. Здесь: sudo neurootdel-offsite-setup git@github.com:<твой-логин>/<имя-репозитория>.git
Копия уходит каждую ночь в 03:45 по твоему времени. Сломалась: утром придёт строка от агента.
EOF
}

mode="${1:-}"
case "$mode" in
    --init)
        ensure_key
        exit 0
        ;;
    --off)
        set_repo ""
        echo "Копия памяти вне сервера выключена (OFFSITE_REPO пустой). Включить: sudo neurootdel-offsite-setup <репозиторий>"
        exit 0
        ;;
    "")
        ensure_key
        show_steps
        if [[ -n "${OFFSITE_REPO:-}" ]]; then
            echo "Сейчас: копия идёт в ${OFFSITE_REPO}."
            last=$(agent_read "$H/backups/offsite/last" | tr -d '\000-\010\013-\037' | cut -d' ' -f1,4-)
            [[ -z "$last" ]] || echo "Последний прогон: ${last}"
        else
            echo "Сейчас: копии вне сервера НЕТ (репозиторий не задан)."
        fi
        exit 0
        ;;
    -*)
        echo "usage: $(basename "$0") [--init|--off|<repo>]" >&2
        exit 2
        ;;
esac

repo=$(normalize_repo "$mode") || {
    echo "Не похоже на репозиторий GitHub: ${mode}. Нужно git@github.com:<логин>/<имя>.git или https://github.com/<логин>/<имя>" >&2
    exit 2
}
ensure_key
set_repo "$repo"
echo "Копия памяти пойдёт в ${repo}."
arc=0
access_ok "$repo" || arc=$?
if (( arc == 0 )); then
    echo "Доступ по ключу есть. Делаю первую выгрузку сейчас..."
    # rc 0 only when THIS run copied (or found the copy up to date); a run skipped by STOP, a held
    # lock or an empty repo setting exits 5 here (OFFSITE_SKIP_RC), never 0.
    orc=0
    as_agent env OFFSITE_SKIP_RC=5 bash "${LIB}/memory-offsite.sh" || orc=$?
    if (( orc == 0 )); then
        echo "Первая копия на GitHub лежит. Дальше каждую ночь."
    elif (( orc == 5 )); then
        echo "Выгрузка сейчас не выполнялась (стоит стоп ${H}/backups/offsite/STOP или идёт другой прогон). Копия пойдёт ночью; проверить: sudo neurootdel-verify"
        exit 1
    else
        echo "Первая выгрузка не прошла, причина: $(agent_read "$H/backups/offsite/last" | cut -d' ' -f4-). Лог: $H/backups/offsite/offsite.log"
        exit 1
    fi
elif (( arc == 2 )); then
    echo "Проверка доступа пропущена (тест)."
else
    echo "Доступа по ключу пока НЕТ: добавь ключ ниже в этот репозиторий как Deploy key с «Allow write access» и запусти команду снова."
    show_steps
    exit 1
fi
