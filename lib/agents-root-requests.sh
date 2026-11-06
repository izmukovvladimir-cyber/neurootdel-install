#!/usr/bin/env bash
# agents-root-requests.sh -- privileged request carrier for the agents (installed by the installer
# into <lib dir>, settings from <lib dir>/guard.conf). Root cron, once a minute.
#
# All agents run as ONE unprivileged user (AGENT_USER) without general sudo. An agent asks
# for a privileged action by dropping a one-line request file into REQ_DIR; this script
# claims it, validates it against a closed grammar and runs only pre-written actions.
# A request never carries a command, a path or a unit name: agent names map to units
# through a fixed table.
#
# Request grammar (one line, ASCII, <= 512 bytes, optional trailing from=<agent>):
#   restart      <jarvis|coder|richard|auditor>
#   allow-user   <jarvis|coder> <user_id>      DM for a person (USER + CHAT ids), restart queued
#   allow-chat   <jarvis|coder> <chat_id>      a group into TELEGRAM_ALLOWED_CHAT_IDS, restart queued
#   revoke-user  <jarvis|coder> <user_id>      out of USER + CHAT ids (owners never), restart queued
#   permissions  <jarvis|coder>                --dangerously-skip-permissions back into the unit
#   model        <jarvis|coder> <model>        --model in the unit (takes effect on restart)
#   model-revert <jarvis|coder>                the model before the last `model`
#   cron-restore                               missing /etc/cron.d/<user>-* and the agent crontab
#                                              from the newest backup of cron-manifest-watchdog.sh
#
# Restarts of jarvis/coder/richard go into the restart queue of agents-guard.py
# (/tmp/channel-restart-request): it waits for the end of the agent's turn and restarts
# richard last. The auditor (hermes) units are restarted here. A restart is deferred while
# the unit started less than COOLDOWN seconds ago.
#
# Paths (U = AGENT_USER):
#   requests  /var/lib/U-requests/requests   (U writes, 0770)
#   results   /var/lib/U-requests/results/<name>.result (group U reads)
#   journal   /var/log/U-root-requests.log
#   stop      touch /etc/U-root-requests.STOP
#   cron      /etc/cron.d/U-root-requests
set -euo pipefail
umask 027

LIB="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CONF="${NEUROOTDEL_GUARD_CONF:-$LIB/guard.conf}"
[[ -f "$CONF" ]] || { echo "missing: $CONF" >&2; exit 1; }

ROOT=""
SYSTEMCTL=/usr/bin/systemctl
CRONTAB=/usr/bin/crontab
AUD_SLEEP=5
NOW_OVERRIDE=""
if [[ "${NEUROOTDEL_RR_TEST:-0}" == "1" ]]; then
    # Test mode only: every system path is re-rooted and every binary is a fake.
    ROOT="${NEUROOTDEL_RR_ROOT:?NEUROOTDEL_RR_ROOT required in test mode}"
    [[ "$ROOT" == /tmp/* || "$ROOT" == /home/* ]] || { echo "bad NEUROOTDEL_RR_ROOT" >&2; exit 2; }
    SYSTEMCTL="${NEUROOTDEL_RR_SYSTEMCTL:?}"; CRONTAB="${NEUROOTDEL_RR_CRONTAB:?}"
    AUD_SLEEP=0; NOW_OVERRIDE="${NEUROOTDEL_RR_NOW:-}"
else
    # guard.conf is sourced by root: it must be root's and not writable by anyone else.
    [[ "$(stat -c '%U' -- "$CONF")" == root && ! -L "$CONF" ]] || { echo "refused: $CONF is not root's" >&2; exit 1; }
    (( (8#$(stat -c '%a' -- "$CONF") & 8#022) == 0 )) || { echo "refused: $CONF is group/world writable" >&2; exit 1; }
fi
# shellcheck disable=SC1090
. "$CONF"
REQ_USER="${AGENT_USER:?AGENT_USER missing in guard.conf}"
[[ "$REQ_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { echo "bad AGENT_USER" >&2; exit 1; }
[[ "${CONFIG_ROOT:-}" =~ ^/[A-Za-z0-9._/-]+$ ]] || { echo "bad CONFIG_ROOT" >&2; exit 1; }

readonly BASE="$ROOT/var/lib/${REQ_USER}-requests"
readonly REQ_DIR="$BASE/requests"
readonly RES_DIR="$BASE/results"
readonly STATE="$ROOT/var/lib/${REQ_USER}-root-requests"
readonly QDIR="$STATE/queue"
readonly VDIR="$STATE/verify"
readonly PREV_DIR="$STATE/model-prev"
readonly REJ_DIR="$STATE/rejected"
readonly LOG="$ROOT/var/log/${REQ_USER}-root-requests.log"
readonly STOP="$ROOT/etc/${REQ_USER}-root-requests.STOP"
readonly GUARD_Q="$ROOT/tmp/channel-restart-request"
readonly GUARD_STATE="$ROOT/var/lib/${REQ_USER}-guard"
readonly GUARD_CLAIM="$ROOT/tmp/.channel-restart-request.claim-root"
readonly UNIT_DIR="$ROOT/etc/systemd/system"
readonly ENV_DIR="$CONFIG_ROOT"
readonly CRON_DIR="$ROOT/etc/cron.d"
readonly CRON_BAK="$ROOT/var/backups/${REQ_USER}-cron"

readonly COOLDOWN=120        # no restart of the same agent more often than this
readonly EXPIRE=1800         # a request not done within this is dropped as EXPIRED
readonly VERIFY_MAX=1200     # guard queue restart must show up within this
readonly MAX_PER_TICK=20
# Never revoked: the owner from guard.conf; owner ids in the env are checked per request.
readonly PROTECTED_IDS="${OWNER_TG_ID:-}"

declare -A UNIT=([jarvis]=channel-jarvis [coder]=channel-coder [richard]=claude-richard [auditor]=hermes-auditor)
readonly RE_AGENT_ANY='^(jarvis|coder|richard|auditor)$'
readonly RE_AGENT_CH='^(jarvis|coder)$'
readonly RE_UID='^[0-9]{5,15}$'
readonly RE_CHAT='^-?[0-9]{5,20}$'
readonly RE_MODEL='^(opus|sonnet|haiku|claude-(opus|sonnet|haiku|fable)-[0-9]+([.-][0-9]+)*)$'
readonly RE_NAME='^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'

now() { if [[ -n "$NOW_OVERRIDE" ]]; then echo "$NOW_OVERRIDE"; else date +%s; fi; }
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '%s %s\n' "$(ts)" "$*" >>"$LOG"; }

result() {  # $1 request name, rest = text
    local f="$RES_DIR/$1.result"; shift
    printf '%s %s\n' "$(ts)" "$*" >>"$f"
    chmod 0640 "$f"; chgrp "$REQ_USER" "$f" 2>/dev/null || true
}

finish() {  # $1 item path, $2 name, $3 status, $4 message
    log "$3 [$2] $4"
    result "$2" "$3 $4"
    rm -f -- "$1"
}

# The auditor units this server has (installer: hermes-auditor + hermes-auditor-bridge).
auditor_units() {
    local u out=""
    for u in hermes-auditor hermes-auditor-bridge hermes-auditor-swarm-bridge; do
        [[ -f "$UNIT_DIR/$u.service" ]] && out="$out $u"
    done
    echo "${out# }"
}

# ---------- request validation ----------

# Echo the normalized request or return 1. Grammar is closed: anything else is refused.
validate_line() {
    local line="$1" kind from="" n
    [[ "$line" =~ ^[a-z0-9.=\ -]{1,200}$ ]] || return 1
    local -a t
    read -r -a t <<<"$line"
    n=${#t[@]}
    (( n >= 1 )) || return 1
    if [[ "${t[n-1]}" =~ ^from=(.*)$ ]]; then
        from="${BASH_REMATCH[1]}"
        [[ "$from" =~ $RE_AGENT_ANY ]] || return 1
        unset 't[n-1]'; n=$((n - 1))
    fi
    kind="${t[0]}"
    case "$kind" in
        restart)                      (( n == 2 )) && [[ "${t[1]}" =~ $RE_AGENT_ANY ]] || return 1 ;;
        allow-user|revoke-user)       (( n == 3 )) && [[ "${t[1]}" =~ $RE_AGENT_CH ]] && [[ "${t[2]}" =~ $RE_UID ]] || return 1 ;;
        allow-chat)                   (( n == 3 )) && [[ "${t[1]}" =~ $RE_AGENT_CH ]] && [[ "${t[2]}" =~ $RE_CHAT ]] || return 1 ;;
        permissions|model-revert)     (( n == 2 )) && [[ "${t[1]}" =~ $RE_AGENT_CH ]] || return 1 ;;
        model)                        (( n == 3 )) && [[ "${t[1]}" =~ $RE_AGENT_CH ]] && [[ "${t[2]}" =~ $RE_MODEL ]] || return 1 ;;
        cron-restore)                 (( n == 1 )) || return 1 ;;
        *) return 1 ;;
    esac
    local out="${t[*]:0:n}"
    [[ -n "$from" ]] && out="$out from=$from"
    echo "$out"
}

reject() {  # $1 name (already validated or a placeholder), $2 why
    log "REJECT [$1] $2"
    [[ "$1" =~ $RE_NAME ]] && result "$1" "REJECT $2"
    return 0
}

# Move every request out of the agent-writable dir into the root-only queue, then
# validate the claimed copy (nobody but root can touch it there) and rewrite it as
# a root-owned file holding only the normalized line.
intake() {
    local f base dest seq=0 owner links size line norm
    [[ -d "$REQ_DIR" && ! -L "$REQ_DIR" ]] || { log "ERROR request dir missing or symlink: $REQ_DIR"; return 0; }
    for f in "$REQ_DIR"/* "$REQ_DIR"/.[!.]*; do
        [[ -e "$f" || -L "$f" ]] || continue
        base="${f##*/}"
        [[ "$base" == *.tmp ]] && continue   # writer has not renamed it into place yet
        seq=$((seq + 1))
        (( seq <= MAX_PER_TICK )) || break
        if ! [[ "$base" =~ $RE_NAME ]]; then
            mv -f -T -- "$f" "$REJ_DIR/badname-$(now)-$seq" 2>/dev/null || true
            reject "-" "bad request file name"
            continue
        fi
        dest="$QDIR/.in-$(now)-$seq-$base"
        mv -T -- "$f" "$dest" 2>/dev/null || { log "ERROR cannot claim [$base]"; continue; }
        if [[ -L "$dest" || ! -f "$dest" ]]; then
            mv -f -T -- "$dest" "$REJ_DIR/$(now)-$seq-$base" 2>/dev/null || true
            reject "$base" "not a regular file"; continue
        fi
        read -r owner links size < <(stat -c '%U %h %s' -- "$dest")
        if [[ "$owner" != "$REQ_USER" ]]; then rm -f -- "$dest"; reject "$base" "owner $owner, expected $REQ_USER"; continue; fi
        if [[ "$links" != 1 ]]; then rm -f -- "$dest"; reject "$base" "hard links: $links"; continue; fi
        if (( size > 512 )); then rm -f -- "$dest"; reject "$base" "too big: $size bytes"; continue; fi
        line="$(head -c 512 -- "$dest" | head -n1 | tr -d '\r')"
        rm -f -- "$dest"
        if ! norm="$(validate_line "$line")"; then reject "$base" "unknown or malformed request"; continue; fi
        printf '%s\n' "$norm" >"$QDIR/$(now)-$seq-$base"
        log "ACCEPT [$base] $norm"
        result "$base" "ACCEPT $norm"
    done
}

# ---------- helpers ----------

# Echo the unit's last activation as epoch; rc 1 when systemd could not be asked or the
# answer could not be parsed. An empty value (never activated) is a real 0.
unit_start() {
    local v
    v="$("$SYSTEMCTL" show -p ActiveEnterTimestamp --value "$1" 2>/dev/null)" || return 1
    if [[ -z "$v" || "$v" == "n/a" ]]; then echo 0; return 0; fi
    date -d "$v" +%s 2>/dev/null || return 1
}

unit_active() { [[ "$("$SYSTEMCTL" is-active "$1" 2>/dev/null || true)" == "active" ]]; }

in_cooldown() {  # $1 agent
    local since last=0
    since="$(unit_start "${UNIT[$1]}")" || return 0   # unknown start time: treat as cooling down
    [[ -f "$STATE/last-restart-$1" ]] && last="$(cat "$STATE/last-restart-$1")"
    (( last > since )) && since=$last
    (( $(now) - since < COOLDOWN ))
}

restart_pending() { [[ -f "$VDIR/$1" ]]; }  # handed to agents-guard, not yet seen done

# The config of $1 changed while a restart was pending: that restart may already have
# read the old config, so later restart requests must not join it (they wait for it
# to clear and then hand over a fresh one).
mark_config_changed() { if restart_pending "$1"; then : >"$VDIR/.stale-$1" || return 1; fi; return 0; }

# Does agents-guard still hold a hand-over for $1? Anything odd or unreadable counts as
# "yes" (keeps the record). Each file is opened once, O_NOFOLLOW|O_NONBLOCK, checked by
# fstat on the open fd and read with a cap, so a FIFO swapped in cannot hang the carrier.
guard_holds() {
    python3 -c '
import json, os, stat, sys
qfile, claim, state, agent = sys.argv[1:5]
def read_reg(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return None
    except OSError:
        sys.exit(0)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            sys.exit(0)
        return os.read(fd, 1 << 20).decode("utf-8", "replace")
    finally:
        os.close(fd)
for f in (qfile, claim):
    txt = read_reg(f)
    if txt is not None and (agent in txt.split() or "all" in txt.split()):
        sys.exit(0)
txt = read_reg(state)
if txt is None:
    sys.exit(1)
try:
    sys.exit(0 if agent in json.loads(txt).get("queue", {}) else 1)
except Exception:
    sys.exit(0)
' "$GUARD_Q" "$GUARD_CLAIM" "$GUARD_STATE/state.json" "$1"
}

env_has() {  # $1 file $2 key $3 id
    local line ids
    line="$(grep -m1 "^$2=" "$1" || true)"
    ids="${line#*=}"
    [[ ",$ids," == *",$3,"* ]]
}

# env_ids <file> <add|remove|check> <id> <key>... -- edit comma lists of ids in a channel.env
# (check = only the format checks below, nothing written).
# Prints "already" (nothing to do) or "changed, backup <name>". The file must be a regular
# file (no symlink); owner and mode are kept, the old file is backed up next to it.
env_ids() {
    python3 - "$@" "$(date -u +%Y%m%d%H%M%S)" <<'PY'
import os, re, shutil, stat, sys
path, op, uid, *keys = sys.argv[1:]
stamp = keys.pop()
st = os.lstat(path)
if not stat.S_ISREG(st.st_mode):
    sys.exit(f"{path} is not a regular file")
with open(path, encoding="utf-8") as fh:
    lines = fh.read().split("\n")
# A repeated or non-canonical key (indent, "export", spaces around "="): systemd may take a line
# our checks do not see. Only one plain KEY=... line per key is edited; anything else is refused.
# The owner keys are checked too: the owner protection of revoke-user reads them the same way.
# A value must be a bare comma list of ids (no quotes, spaces or comments).
for k in list(keys) + ["TELEGRAM_COMMAND_OWNER_IDS", "TELEGRAM_PERMISSION_ALLOWED_USER_IDS"]:
    defs = [line for line in lines if re.match(rf"\s*(export\s+)?{k}\s*=", line)]
    if len(defs) > 1 or (defs and not defs[0].startswith(k + "=")):
        sys.exit(f"{k} repeated or not plain KEY=value in {path}, fix by hand")
    if defs and not re.fullmatch(r"(-?[0-9]+(,-?[0-9]+)*)?", defs[0][len(k) + 1:]):
        sys.exit(f"{k} is not a bare comma list of ids in {path}, fix by hand")
if op == "check":
    sys.exit(0)
changed = False
for k in keys:
    idx = [i for i, line in enumerate(lines) if line.startswith(k + "=")]
    if not idx:
        if op == "add":
            sys.exit(f"no {k} in {path}")
        continue
    i = idx[0]
    raw = lines[i][len(k) + 1:]
    ids = [x for x in raw.split(",") if x] if raw else []
    if op == "add" and uid not in ids:
        ids.append(uid)
    elif op == "remove" and uid in ids:
        ids = [x for x in ids if x != uid]
    else:
        continue
    lines[i] = k + "=" + ",".join(ids)
    changed = True
if not changed:
    print("already")
    sys.exit(0)
bak = f"{path}.bak-{stamp}-root-request-{op}"
shutil.copy2(path, bak)
os.chown(bak, st.st_uid, st.st_gid)
tmp = f"{path}.tmp-root-request"
with open(tmp, "w", encoding="utf-8") as fh:
    fh.write("\n".join(lines))
os.chown(tmp, st.st_uid, st.st_gid)
os.chmod(tmp, st.st_mode & 0o7777)
os.replace(tmp, path)
print(f"changed, backup {os.path.basename(bak)}")
PY
}

# Hand one agent name to the agents-guard queue. The queue file is never opened:
# a complete private temp file is hard-linked onto the queue name, which fails when
# that name exists in any form (file, FIFO, symlink). rc 4 = queue busy, try later.
guard_enqueue() {  # $1 agent
    python3 -c '
import os, sys, tempfile
path, agent = sys.argv[1], sys.argv[2]
fd, tmp = tempfile.mkstemp(prefix=".rr-restart-", dir=os.path.dirname(path))
try:
    os.write(fd, (agent + "\n").encode())
    os.fchmod(fd, 0o644)
    os.close(fd)
    try:
        os.link(tmp, path)
    except FileExistsError:
        sys.exit(4)
finally:
    os.unlink(tmp)
' "$GUARD_Q" "$1"
}

queue_internal_restart() {  # $1 agent, $2 name of the request that caused it
    printf 'restart %s from=%s\n' "$1" "$1" >"$QDIR/$(now)-0-$2"
}

channel_env() {  # $1 agent: echo the env path or fail with a message
    local env="$ENV_DIR/$1/channel.env"
    [[ -f "$env" && ! -L "$env" ]] || { echo "agent $1 is not installed here (no $env)"; return 1; }
    echo "$env"
}

# ---------- actions: each echoes a message; rc 0 done, 10 defer, 1 failed ----------

act_restart() {  # $1 agent
    local agent="$1" u units base vtmp rc=0
    if [[ "$agent" == "auditor" ]]; then
        units="$(auditor_units)"
        [[ -n "$units" ]] || { echo "auditor is not installed here"; return 1; }
    elif [[ ! -f "$UNIT_DIR/${UNIT[$agent]}.service" ]]; then
        echo "${UNIT[$agent]} is not installed here"; return 1
    fi
    if [[ "$agent" != "auditor" ]] && restart_pending "$agent" && [[ ! -e "$VDIR/.stale-$agent" ]]; then
        # one restart already handed over: this request joins it and gets the same verdict
        printf '%s\n' "$ITEM_NAME" >>"$VDIR/$agent" || { echo "cannot join pending restart"; return 1; }
        echo "JOINED the pending restart of $agent (verify follows)"
        return 0
    fi
    if [[ "$agent" != "auditor" ]] && restart_pending "$agent"; then
        echo "config changed after the pending restart was handed over: waiting for it to clear, then a fresh restart"; return 10
    fi
    if in_cooldown "$agent"; then echo "cooldown ${COOLDOWN}s"; return 10; fi
    if [[ "$agent" == "auditor" ]]; then
        now >"$STATE/last-restart-$agent" || { echo "cannot write state, nothing restarted"; return 1; }
        for u in $units; do "$SYSTEMCTL" restart "$u" || { echo "systemctl restart $u failed"; return 1; }; done
        sleep "$AUD_SLEEP"
        for u in $units; do unit_active "$u" || { echo "VERIFY FAIL: $u not active"; return 1; }; done
        echo "restarted $units, VERIFY OK: active"
        return 0
    fi
    if [[ -e "$GUARD_STATE/STOP" || -e "$GUARD_STATE/QUEUE_OFF" ]]; then
        echo "agents-guard restart queue is switched off (STOP/QUEUE_OFF), nothing restarted"; return 1
    fi
    # baseline BEFORE the hand-over: any later start of the unit proves the restart
    base="$(unit_start "${UNIT[$agent]}")" || { echo "cannot read start time of ${UNIT[$agent]}, retry next tick"; return 10; }
    vtmp="$VDIR/.new-$agent"
    { printf '%s %s\n%s\n' "$base" "$(now)" "$ITEM_NAME" >"$vtmp" && mv -f -- "$vtmp" "$VDIR/$agent"; } \
        || { rm -f -- "$vtmp"; echo "cannot write verify state, nothing restarted"; return 1; }
    guard_enqueue "$agent" || rc=$?
    if (( rc == 4 )); then rm -f -- "$VDIR/$agent"; echo "agents-guard queue file is occupied, retry next tick"; return 10; fi
    if (( rc != 0 )); then rm -f -- "$VDIR/$agent"; echo "cannot hand over to agents-guard queue (rc=$rc)"; return 1; fi
    now >"$STATE/last-restart-$agent" || true
    echo "QUEUED in agents-guard queue (waits for the end of the turn, verify follows)"
    return 0
}

# allow-user / allow-chat share one path: edit the id lists, verify, queue a restart.
allow_ids() {  # $1 agent $2 id $3 label, rest = keys
    local agent="$1" id="$2" label="$3" env out rc=0 k
    shift 3
    env="$(channel_env "$agent")" || { echo "$env"; return 1; }
    mark_config_changed "$agent" || { echo "cannot write state, nothing changed"; return 1; }
    out="$(env_ids "$env" add "$id" "$@" 2>&1)" || rc=$?
    (( rc == 0 )) || { echo "edit failed: $(tr '\n' ' ' <<<"$out")"; return 1; }
    for k in "$@"; do env_has "$env" "$k" "$id" || { echo "VERIFY FAIL: $id not in $k"; return 1; }; done
    if [[ "$out" == already ]]; then echo "ALREADY: $id $label, no restart"; return 0; fi
    queue_internal_restart "$agent" "$ITEM_NAME" || { echo "$id $label ($out), VERIFY OK, but restart NOT queued: put 'restart $agent'"; return 1; }
    echo "$id $label ($out), VERIFY OK; restart of $agent queued"
}

act_allow_user() { allow_ids "$1" "$2" "can write in DM" TELEGRAM_ALLOWED_USER_IDS TELEGRAM_ALLOWED_CHAT_IDS; }
act_allow_chat() { allow_ids "$1" "$2" "allowed as chat" TELEGRAM_ALLOWED_CHAT_IDS; }

act_revoke_user() {  # $1 agent $2 uid
    local env out rc=0 p
    env="$(channel_env "$1")" || { echo "$env"; return 1; }
    for p in $PROTECTED_IDS; do [[ "$2" == "$p" ]] && { echo "REFUSED: $2 is the owner (OWNER_TG_ID)"; return 1; }; done
    out="$(env_ids "$env" check "$2" TELEGRAM_ALLOWED_USER_IDS TELEGRAM_ALLOWED_CHAT_IDS 2>&1)" || { echo "REFUSED: $(tr '\n' ' ' <<<"$out")"; return 1; }
    for p in TELEGRAM_COMMAND_OWNER_IDS TELEGRAM_PERMISSION_ALLOWED_USER_IDS; do
        env_has "$env" "$p" "$2" && { echo "REFUSED: $2 is in $p (owner)"; return 1; }
    done
    mark_config_changed "$1" || { echo "cannot write state, nothing changed"; return 1; }
    out="$(env_ids "$env" remove "$2" TELEGRAM_ALLOWED_USER_IDS TELEGRAM_ALLOWED_CHAT_IDS 2>&1)" || rc=$?
    (( rc == 0 )) || { echo "revoke edit failed: $(tr '\n' ' ' <<<"$out")"; return 1; }
    if env_has "$env" TELEGRAM_ALLOWED_USER_IDS "$2" || env_has "$env" TELEGRAM_ALLOWED_CHAT_IDS "$2"; then
        echo "VERIFY FAIL: $2 still present"; return 1
    fi
    if [[ "$out" == already ]]; then echo "ALREADY: $2 absent, no restart"; return 0; fi
    queue_internal_restart "$1" "$ITEM_NAME" || { echo "removed ($out), VERIFY OK, but restart NOT queued: put 'restart $1'"; return 1; }
    echo "removed ($out), VERIFY OK: absent from both keys; restart of $1 queued"
}

unit_file() { echo "$UNIT_DIR/channel-$1.service"; }

act_permissions() {  # $1 agent
    local uf bak
    uf="$(unit_file "$1")"
    [[ -f "$uf" && ! -L "$uf" ]] || { echo "missing $uf"; return 1; }
    if grep -q '^ExecStart=.*--dangerously-skip-permissions' "$uf"; then echo "ALREADY: flag present"; return 0; fi
    grep -qE '^ExecStart=.* claude( |$)' "$uf" || { echo "no 'claude' in ExecStart, refusing"; return 1; }
    mark_config_changed "$1" || { echo "cannot write state, nothing changed"; return 1; }
    bak="$uf.bak-$(date -u +%Y%m%d%H%M%S)-root-request-perms"
    cp -p -- "$uf" "$bak" || { echo "backup failed, nothing changed"; return 1; }
    sed -i -E '/^ExecStart=/ s/ claude( |$)/ claude --dangerously-skip-permissions\1/' "$uf" || { cp -p -- "$bak" "$uf"; echo "edit failed, unit restored"; return 1; }
    if "$SYSTEMCTL" daemon-reload && "$SYSTEMCTL" show -p ExecStart --value "channel-$1" | grep -q -- '--dangerously-skip-permissions'; then
        echo "flag added (backup ${bak##*/}); takes effect on next restart: put 'restart $1'"; return 0
    fi
    cp -p -- "$bak" "$uf"; "$SYSTEMCTL" daemon-reload
    echo "VERIFY FAIL: systemd does not show the flag, unit restored"; return 1
}

current_model() { grep -m1 '^ExecStart=' "$1" | grep -oE -- '--model [^ ]+' | head -n1 | cut -d' ' -f2; }

switch_model() {  # $1 agent $2 new model; echoes old model on success
    local uf cur bak old_re
    uf="$(unit_file "$1")"
    [[ -f "$uf" && ! -L "$uf" ]] || { echo "missing $uf"; return 1; }
    cur="$(current_model "$uf")"
    [[ "$cur" =~ $RE_MODEL ]] || { echo "current --model not recognised, refusing"; return 1; }
    if [[ "$cur" == "$2" ]]; then echo "ALREADY:$cur"; return 0; fi
    bak="$uf.bak-$(date -u +%Y%m%d%H%M%S)-root-request-model"
    cp -p -- "$uf" "$bak" || { echo "backup failed, nothing changed"; return 1; }
    old_re="${cur//./\\.}"
    sed -i -E "/^ExecStart=/ s/--model ${old_re}( |\$)/--model $2\\1/" "$uf" || { cp -p -- "$bak" "$uf"; echo "edit failed, unit restored"; return 1; }
    if "$SYSTEMCTL" daemon-reload && [[ "$(current_model "$uf")" == "$2" ]] \
        && [[ "$("$SYSTEMCTL" show -p ExecStart --value "channel-$1" | grep -oE -- '--model [^ ;]+' | head -n1 | cut -d' ' -f2)" == "$2" ]]; then
        echo "OK:$cur"; return 0
    fi
    cp -p -- "$bak" "$uf"; "$SYSTEMCTL" daemon-reload
    echo "VERIFY FAIL: model not applied, unit restored"; return 1
}

act_model() {  # $1 agent $2 model
    local r
    mark_config_changed "$1" || { echo "cannot write state, nothing changed"; return 1; }
    r="$(switch_model "$1" "$2")" || { echo "$r"; return 1; }
    if [[ "$r" == ALREADY:* ]]; then echo "ALREADY: $1 on $2"; return 0; fi
    printf '%s\n' "${r#OK:}" >"$PREV_DIR/$1" || { echo "$1: ${r#OK:} -> $2 applied, but previous model NOT recorded (model-revert impossible; old: ${r#OK:})"; return 1; }
    echo "$1: ${r#OK:} -> $2, VERIFY OK; takes effect on next restart: put 'restart $1'; undo: 'model-revert $1'"
}

act_model_revert() {  # $1 agent
    local prev r
    [[ -f "$PREV_DIR/$1" ]] || { echo "NOTHING: no previous model recorded for $1"; return 0; }
    prev="$(head -n1 "$PREV_DIR/$1")"
    [[ "$prev" =~ $RE_MODEL ]] || { echo "recorded model invalid, refusing"; return 1; }
    mark_config_changed "$1" || { echo "cannot write state, nothing changed"; return 1; }
    r="$(switch_model "$1" "$prev")" || { echo "$r"; return 1; }
    rm -f -- "$PREV_DIR/$1"
    echo "$1 back on $prev, VERIFY OK; takes effect on next restart: put 'restart $1'"
}

# Backups are written by cron-manifest-watchdog.sh (root): <CRON_BAK>/<UTC stamp>/cron.d/ and
# <stamp>/<user>-crontab. Only the installer's own slots (<user>-*) are restored, never over a file.
act_cron_restore() {
    local latest src name restored="" rc=0
    [[ -d "$CRON_BAK" && ! -L "$CRON_BAK" && "$(stat -c %U "$CRON_BAK")" == "$(stat -c %U "$STATE")" ]] \
        || { echo "backup dir $CRON_BAK missing or foreign"; return 1; }
    latest="$(find "$CRON_BAK" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | grep -E '^[0-9]{8}T[0-9]{6}Z$' | sort | tail -n1)"
    [[ -n "$latest" ]] || { echo "no cron backup found"; return 1; }
    for src in "$CRON_BAK/$latest/cron.d"/*; do
        [[ -f "$src" && ! -L "$src" ]] || continue
        name="${src##*/}"
        [[ "$name" =~ ^${REQ_USER}-[a-z0-9-]+$ ]] || continue
        [[ -e "$CRON_DIR/$name" || -L "$CRON_DIR/$name" ]] && continue   # never overwrite
        install -m 0644 -- "$src" "$CRON_DIR/$name"
        cmp -s -- "$src" "$CRON_DIR/$name" || { echo "VERIFY FAIL: $name"; rc=1; continue; }
        restored="$restored $name"
    done
    src="$CRON_BAK/$latest/${REQ_USER}-crontab"
    if ! "$CRONTAB" -u "$REQ_USER" -l >/dev/null 2>&1 && [[ -f "$src" && ! -L "$src" ]] && grep -qvE '^[[:space:]]*(#|$)' "$src"; then
        "$CRONTAB" -u "$REQ_USER" "$src" && "$CRONTAB" -u "$REQ_USER" -l >/dev/null 2>&1 \
            && restored="$restored crontab-$REQ_USER" || { echo "VERIFY FAIL: crontab $REQ_USER"; rc=1; }
    fi
    (( rc == 0 )) || return 1
    if [[ -z "$restored" ]]; then echo "NOTHING MISSING (backup $latest)"; else echo "restored from $latest:$restored"; fi
}

# ---------- queue processing ----------

ITEM_NAME=""; ITEM_AGE=0

process_item() {  # $1 item path
    local item="$1" fname arrived line msg rc=0
    local -a t
    fname="${item##*/}"
    arrived="${fname%%-*}"
    ITEM_NAME="${fname#*-}"; ITEM_NAME="${ITEM_NAME#*-}"
    ITEM_AGE=$(( $(now) - arrived ))
    line="$(head -n1 -- "$item")"
    if ! line="$(validate_line "$line")"; then finish "$item" "$ITEM_NAME" FAIL "queue item invalid"; return; fi
    if (( ITEM_AGE > EXPIRE )); then finish "$item" "$ITEM_NAME" EXPIRED "$line (not done in ${EXPIRE}s)"; return; fi
    read -r -a t <<<"$line"
    case "${t[0]}" in
        restart)      msg="$(act_restart "${t[1]}")" || rc=$? ;;
        allow-user)   msg="$(act_allow_user "${t[1]}" "${t[2]}")" || rc=$? ;;
        allow-chat)   msg="$(act_allow_chat "${t[1]}" "${t[2]}")" || rc=$? ;;
        revoke-user)  msg="$(act_revoke_user "${t[1]}" "${t[2]}")" || rc=$? ;;
        permissions)  msg="$(act_permissions "${t[1]}")" || rc=$? ;;
        model)        msg="$(act_model "${t[1]}" "${t[2]}")" || rc=$? ;;
        model-revert) msg="$(act_model_revert "${t[1]}")" || rc=$? ;;
        cron-restore) msg="$(act_cron_restore)" || rc=$? ;;
    esac
    case "$rc" in
        0)  finish "$item" "$ITEM_NAME" DONE "$line: $msg" ;;
        10) # deferred: log once per item, keep it for the next tick
            if [[ ! -e "$STATE/deferred-$fname" ]]; then : >"$STATE/deferred-$fname"; log "DEFER [$ITEM_NAME] $line: $msg"; result "$ITEM_NAME" "DEFER $msg"; fi ;;
        *)  finish "$item" "$ITEM_NAME" FAIL "$line: $msg" ;;
    esac
}

# Order: everything that is not a restart, then restarts of others, then an
# agent's restart of itself (it must not be cut off in the middle of its answer).
process_queue() {
    local f line rank
    local -a items=()
    for f in "$QDIR"/[0-9]*; do [[ -f "$f" ]] && items+=("$f"); done
    (( ${#items[@]} )) || return 0
    while IFS=$'\t' read -r rank f; do
        [[ -f "$f" ]] && process_item "$f"
    done < <(
        for f in "${items[@]}"; do
            line="$(head -n1 -- "$f")"
            rank=0
            if [[ "$line" =~ ^restart\ ([a-z]+)( from=([a-z]+))?$ ]]; then
                rank=1; [[ "${BASH_REMATCH[3]}" == "${BASH_REMATCH[1]}" ]] && rank=2
            fi
            printf '%s\t%s\n' "$rank" "$f"
        done | sort -t$'\t' -k1,1n -s
    )
    for f in "$STATE"/deferred-*; do
        [[ -e "$f" ]] || continue
        [[ -e "$QDIR/${f##*/deferred-}" ]] || rm -f -- "$f"
    done
}

# A restart handed to agents-guard is proven only by a unit start later than the
# baseline taken before the hand-over. Every request joined to it gets the verdict.
# A timeout is REPORTED once but the record stays (it still blocks direct restarts)
# until the restart shows up or agents-guard provably no longer holds the hand-over.
verify_restarts() {
    local f agent base fwd started name verdict="" release held
    for f in "$VDIR"/*; do
        [[ -f "$f" ]] || continue
        agent="${f##*/}"
        [[ "$agent" =~ $RE_AGENT_ANY ]] || { rm -f -- "$f"; continue; }
        read -r base fwd <"$f"
        held=0; guard_holds "$agent" && held=1   # before the start time: a restart done in between is still seen
        started="$(unit_start "${UNIT[$agent]}")" || continue
        verdict=""; release=0
        if (( started > base )) && unit_active "${UNIT[$agent]}"; then
            verdict="VERIFY OK ${UNIT[$agent]} restarted and active"; release=1
        elif (( started > base )); then
            verdict="VERIFY FAIL ${UNIT[$agent]} restarted but not active"; release=1
        elif (( ! held )); then
            verdict="VERIFY FAIL ${UNIT[$agent]}: agents-guard dropped the restart without running it"; release=1
        elif (( $(now) - fwd > VERIFY_MAX )) && [[ ! -e "$VDIR/.timeout-$agent" ]]; then
            verdict="VERIFY TIMEOUT ${UNIT[$agent]} not restarted within ${VERIFY_MAX}s (still held by agents-guard)"
            : >"$VDIR/.timeout-$agent" || true
        fi
        [[ -n "$verdict" ]] || continue
        while read -r name; do
            [[ "$name" =~ $RE_NAME ]] || continue
            log "$verdict [$name]"; result "$name" "$verdict"
        done < <(tail -n +2 "$f")
        if (( release )); then rm -f -- "$f" "$VDIR/.stale-$agent" "$VDIR/.timeout-$agent"; fi
    done
}

main() {
    mkdir -p "$QDIR" "$VDIR" "$PREV_DIR" "$REJ_DIR"
    chmod 0700 "$STATE"
    touch "$LOG"; chmod 0640 "$LOG"; chgrp "$REQ_USER" "$LOG" 2>/dev/null || true
    exec 9>"$STATE/lock"
    flock -n 9 || exit 0
    if [[ -e "$STOP" ]]; then
        if compgen -G "$REQ_DIR/*" >/dev/null && [[ ! -e "$STATE/stop-logged" || -n "$(find "$STATE/stop-logged" -mmin +60 2>/dev/null)" ]]; then
            log "STOP flag $STOP present: requests are waiting, nothing done"; touch "$STATE/stop-logged"
        fi
        exit 0
    fi
    rm -f -- "$STATE/stop-logged"
    intake
    verify_restarts   # first: a restart that already happened is cleared before new requests
    process_queue
    find "$RES_DIR" -maxdepth 1 -type f -name '*.result' -mtime +7 -delete 2>/dev/null || true
    find "$REJ_DIR" -maxdepth 1 -mtime +7 -delete 2>/dev/null || true
}

main "$@"
