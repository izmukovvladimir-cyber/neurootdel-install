#!/usr/bin/env bash
# Local helper of group-watch.py (runs as root next to it, installed in the guard lib dir).
#
#   group-wake.sh wake        <agent> <chat_id>          < message  POST to the agent's /hooks/agent webhook
#   group-wake.sh put         <agent> <chat_id> <name>   < file     store media in the agent's group-media dir
#   group-wake.sh transcribe  <agent> <chat_id> <name>              speech-to-text via $GW_WHISPER_URL, prints text
#   group-wake.sh feed-init   <agent> <chat_id>          < lines    start the group feed (refuses if it exists)
#   group-wake.sh feed-append <agent> <chat_id>          < lines    append new lines, dropping ids already there
#   group-wake.sh feed-last   <agent> <chat_id>                     highest id in the feed, or "none"
#
# Paths come from guard.conf (NEUROOTDEL_GUARD_CONF overrides): the agent's channel.env under
# CONFIG_ROOT holds the webhook port/token and TELEGRAM_STATE_DIR; media go to
# <TELEGRAM_STATE_DIR>/group-media, the feed to <workspace>/state/group-<id>/feed.md.
# A group is allowed only if its id is in the agent's TELEGRAM_ALLOWED_CHAT_IDS (the agent
# could not answer there otherwise). The webhook token is never printed.
set -euo pipefail
umask 077

die() { echo "group-wake: $*" >&2; exit "${2:-1}"; }

conf="${NEUROOTDEL_GUARD_CONF:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/guard.conf}"
[[ -f "$conf" ]] || die "no guard.conf at ${conf}" 3
AGENT_USER="" AGENT_HOME="" CONFIG_ROOT=""
# shellcheck disable=SC1090
. "$conf"
[[ "$AGENT_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "bad AGENT_USER in guard.conf" 3
AGENT_HOME="${AGENT_HOME:-/home/${AGENT_USER}}"
[[ -n "$CONFIG_ROOT" ]] || die "no CONFIG_ROOT in guard.conf" 3
# The agent's files are touched as the agent; GW_RUN_AS_SELF=1 (tests, never as root) keeps the current user.
run_as() {
    if [[ "${GW_RUN_AS_SELF:-0}" == "1" && "$EUID" -ne 0 ]]; then "$@"; else runuser -u "$AGENT_USER" -- "$@"; fi
}

cmd="${1:-}"
agent="${2:-}"
chat="${3:-}"
[[ "$agent" =~ ^[a-z0-9-]+$ ]] || die "bad agent name" 64
[[ "$chat" =~ ^-[0-9]+$ ]] || die "chat not allowed" 64
env_file="${CONFIG_ROOT}/${agent}/channel.env"
[[ -f "$env_file" ]] || die "no channel.env for ${agent}" 3

env_get() {
    grep -E "^${1}=" "$env_file" | head -1 | cut -d= -f2- | tr -d '"\r\n' || true
}

allowed=" $(env_get TELEGRAM_ALLOWED_CHAT_IDS | tr ',' ' ') "
[[ "$allowed" == *" ${chat} "* ]] || die "chat not allowed" 64

state_dir="$(env_get TELEGRAM_STATE_DIR)"
[[ -n "$state_dir" ]] || state_dir="${AGENT_HOME}/.claude-lab/shared/state/${agent}/telegram"
readonly media_dir="${state_dir}/group-media"
readonly feed_dir="${AGENT_HOME}/.claude-lab/${agent}/.claude/state/group-${chat#-}"

auth_cfg=""
body_file=""
cleanup() { rm -f "${auth_cfg:-/nonexistent}" "${body_file:-/nonexistent}"; }
trap cleanup EXIT

check_name() {
    [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,120}$ ]] || die "bad media name" 64
}

cmd_wake() {
    local token port resp code resp_body
    token="$(env_get TELEGRAM_WEBHOOK_TOKEN)"
    [[ -n "$token" ]] || die "no webhook token" 3
    port="$(env_get TELEGRAM_WEBHOOK_PORT)"
    [[ "$port" =~ ^[0-9]+$ ]] || die "no webhook port" 3
    auth_cfg="$(mktemp)"; body_file="$(mktemp)"
    printf 'header = "Authorization: Bearer %s"\n' "$token" > "$auth_cfg"
    python3 -c '
import json, sys
msg = sys.stdin.buffer.read().decode("utf-8", "replace")
if not msg.strip():
    sys.exit("empty message")
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump({"message": msg, "chatId": sys.argv[2]}, f, ensure_ascii=False)
' "$body_file" "$chat" || die "body build failed" 70
    resp="$(curl -sS -w $'\n%{http_code}' --connect-timeout 10 --max-time 30 -K "$auth_cfg" \
        -X POST "http://127.0.0.1:${port}/hooks/agent" -H "Content-Type: application/json" \
        --data-binary "@${body_file}" 2>&1)" || die "curl failed" 4
    code="${resp##*$'\n'}"
    resp_body="${resp%$'\n'*}"
    resp_body="${resp_body//$token/<redacted>}"
    [[ "$code" == "200" ]] || die "webhook HTTP ${code}: ${resp_body:0:300}" 5
    echo "woken (HTTP 200)"
}

# Media ops run AS the agent user: the dir is the agent's, so root never writes or reads
# through paths the agent controls (symlink swap between mktemp and write).
cmd_put() {
    local name="${1:-}"
    check_name "$name"
    run_as /bin/bash -c '
set -euo pipefail
umask 027
mkdir -p "$1"
tmp="$(mktemp -p "$1" .incoming.XXXXXX)"
cat > "$tmp"
[[ -s "$tmp" ]] || { rm -f "$tmp"; echo "empty media" >&2; exit 64; }
mv -f "$tmp" "$1/$2"
printf "%s\n" "$1/$2"
' _ "$media_dir" "$name"
}

cmd_transcribe() {
    local name="${1:-}" url="${GW_WHISPER_URL:-}" lang="${GW_WHISPER_LANG-ru}"
    check_name "$name"
    [[ "$url" =~ ^https?://[A-Za-z0-9._:-]+(/[A-Za-z0-9._/-]*)?$ ]] || die "no speech-to-text url" 3
    local args=(-sS --fail --connect-timeout 10 --max-time 300 -F "file=@${media_dir}/${name}" -F response_format=text)
    [[ -z "$lang" ]] || args+=(-F "language=${lang}")
    run_as curl "${args[@]}" "$url"
}

# Feed ops also run as the agent user. Every line starts with "[<message_id>] " and ids only grow, so the
# last complete line is the cursor and a repeated batch is dropped (one writer: the watcher).
readonly feed_py='
import fcntl, hashlib, os, re, sys
d, mode = sys.argv[1], sys.argv[2]
os.makedirs(d, mode=0o750, exist_ok=True)
feed = os.path.join(d, "feed.md")
ID = re.compile(r"^\[(\d+)\] ")


def last_id_and_repair():
    # The feed itself is the cursor: the last COMPLETE line holds the highest id. A torn tail (crash mid-write)
    # is cut off, so a retried batch re-appends exactly the lines that were lost.
    fd = os.open(feed, os.O_RDWR | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb+") as f:
        size = f.seek(0, 2)
        if size == 0:
            return 0
        tail_start = max(0, size - 65536)
        f.seek(tail_start)
        tail = f.read()
        if not tail.endswith(b"\n"):
            cut = tail.rfind(b"\n")
            if cut < 0 and tail_start > 0:
                sys.exit("feed tail longer than 64 KiB without newline")
            f.truncate(tail_start + cut + 1 if cut >= 0 else 0)
            tail = tail[: cut + 1] if cut >= 0 else b""
        for line in reversed(tail.decode("utf-8", "replace").split("\n")):
            m = ID.match(line)
            if m:
                return int(m.group(1))
        return 0


with open(os.path.join(d, ".lock"), "w") as lk:
    fcntl.flock(lk, fcntl.LOCK_EX)
    if mode == "last":
        print(last_id_and_repair() if os.path.exists(feed) else "none")
        sys.exit(0)
    # Integrity trailer "#END <count> <sha256 of everything before it>": a cut batch never gets written,
    # so a half line can not be stored and then deduped forever.
    raw = sys.stdin.buffer.read()
    body, sep, trailer = raw.rstrip(b"\n").rpartition(b"\n")
    body = body + sep if sep else b""
    parts = trailer.decode("ascii", "replace").split()
    if not raw.endswith(b"\n") or len(parts) != 3 or parts[0] != "#END":
        sys.exit("batch without integrity trailer")
    if hashlib.sha256(body).hexdigest() != parts[2]:
        sys.exit("batch checksum mismatch")
    lines = [l for l in body.decode("utf-8").split("\n") if l]
    if len(lines) != int(parts[1]):
        sys.exit("batch line count mismatch")
    if any(not ID.match(l) for l in lines):
        sys.exit("line without [id] prefix")
    if mode == "init":
        if os.path.exists(feed):
            sys.exit("feed already exists, refusing to overwrite")
        tmp = feed + ".tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o640)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write("".join(l + "\n" for l in lines))
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, feed)  # atomic: the feed either exists complete or not at all
        last = max((int(ID.match(l).group(1)) for l in lines), default=0)
        print(f"appended {len(lines)} last_id {last}")
        sys.exit(0)
    if not os.path.exists(feed):
        sys.exit("feed not initialised")
    last = last_id_and_repair()
    new = []
    for l in lines:
        i = int(ID.match(l).group(1))
        if i > last:
            new.append(l)
            last = i
    fd = os.open(feed, os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW)
    with os.fdopen(fd, "a", encoding="utf-8") as f:
        f.write("".join(l + "\n" for l in new))
        f.flush()
        os.fsync(f.fileno())
print(f"appended {len(new)} last_id {last}")
'

cmd_feed() {
    run_as /usr/bin/python3 -c "$feed_py" "$feed_dir" "$1"
}

case "$cmd" in
    wake) cmd_wake ;;
    put) cmd_put "${4:-}" ;;
    transcribe) cmd_transcribe "${4:-}" ;;
    feed-init) cmd_feed init ;;
    feed-append) cmd_feed append ;;
    feed-last) cmd_feed last ;;
    *) die "usage: wake|put|transcribe|feed-init|feed-append|feed-last <agent> <chat_id> [name]" 64 ;;
esac
