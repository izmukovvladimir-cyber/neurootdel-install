#!/usr/bin/env bash
# cron-manifest-watchdog.sh -- the installer's cron slots are still in place (installed by the installer).
# Daily: backs up /etc/cron.d + /etc/crontab + crontabs of the agent user and root, checks the
# manifest below, alerts ONLY when the set of missing items changes (and once on recovery).
# Alerts go through outbox-put.py (ALERT_MODE in guard.conf).
# Cron: /etc/cron.d/<user>-service-watch (hourly, self-throttled to once a day), root.
# Stop: touch /var/lib/<user>-cron-manifest/STOP
# --dry-run: check now (no throttle), print, write nothing.
set -euo pipefail
LIB="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck disable=SC1091
. "${NEUROOTDEL_GUARD_CONF:-$LIB/guard.conf}"
U="${AGENT_USER:?AGENT_USER missing in guard.conf}"

readonly PUT="$LIB/outbox-put.py"
readonly STATE_DIR="${NEUROOTDEL_MANIFEST_STATE:-/var/lib/${U}-cron-manifest}"
readonly STATE_FILE=$STATE_DIR/health.json
readonly LOG_FILE="${NEUROOTDEL_MANIFEST_LOG:-/var/log/${U}-cron-manifest.log}"
readonly BACKUP_DIR="${NEUROOTDEL_MANIFEST_BACKUP:-/var/backups/${U}-cron}"
readonly CHECK_INTERVAL_SEC=86400
readonly KEEP_BACKUPS=14
readonly L="$LIB"
readonly CD="${NEUROOTDEL_CRON_D:-/etc/cron.d}"
readonly CT_AGENT="@crontab-agent"

# "file::needle::label". File must exist AND contain needle. @crontab-agent = `crontab -u <user> -l`.
readonly -a EXPECTED=(
    "$CD/${U}-agents-reset::agents-reset.sh --auto::сброс сессий (ночной и дневной)"
    "$CD/${U}-agents-guard::agents-guard.py::сторож агентов (1/мин)"
    "$CD/${U}-memory-backup::memory-backup.sh --auto::бэкап памяти (03:30)"
    "$CD/${U}-memory-weight::memory_weight_watch.py::вес памяти агентов (04:20)"
    "$CD/${U}-service-watch::resource-watchdog.sh::сторож ресурсов (*/5)"
    "$CD/${U}-service-watch::disk-clean-old.sh::чистка старых файлов (04:30)"
    "$CD/${U}-service-watch::agents-git-autosync.sh::git-история агентов (*/30)"
    "$CD/${U}-service-watch::claude-usage-collector.py::учёт расходов (ежечасно)"
    "$CD/${U}-service-watch::cron-manifest-watchdog.sh::сторож расписания (раз в сутки)"
    "${CT_AGENT}::jarvis/scripts/rotate-warm.sh::ротация памяти"
)
readonly -a SCRIPTS=(
    "$L/agents-reset.sh" "$L/agents-guard.py" "$L/agent-handoff-flush.py" "$L/memory-backup.sh"
    "$L/resource-watchdog.sh" "$L/disk-clean-old.sh" "$L/agents-git-autosync.sh"
    "$L/claude-usage-collector.py" "$L/outbox-put.py" "$L/memory_weight_watch.py" "$L/restart_unanswered.py"
    "$L/hooks/precompact-flush.sh" "$L/cron-manifest-watchdog.sh"
)

DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1

[[ -e "$STATE_DIR/STOP" ]] && exit 0
if (( ! DRY )); then
    mkdir -p "$STATE_DIR" "$BACKUP_DIR"
    chmod 700 "$STATE_DIR" "$BACKUP_DIR"
    exec 9>"$STATE_DIR/lock"
    flock -n 9 || exit 0
fi

log() { if (( DRY )); then printf '%s\n' "$*"; else printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >>"$LOG_FILE"; fi; }

prev_sig="" prev_checked=0
if [[ -f "$STATE_FILE" ]]; then
    read -r prev_sig prev_checked < <(python3 - "$STATE_FILE" <<'PY' 2>/dev/null || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get("missing_sig") or "_", int(d.get("checked_at", 0)))
except Exception:
    print("_", 0)
PY
    )
fi
[[ "$prev_checked" =~ ^[0-9]+$ ]] || prev_checked=0
[[ "$prev_sig" == "_" ]] && prev_sig=""

now=$(date +%s)
if (( ! DRY && now - prev_checked < CHECK_INTERVAL_SEC )); then
    exit 0
fi

ct_neuro=$(mktemp)
trap 'rm -f "$ct_neuro"' EXIT
crontab -u "$U" -l >"$ct_neuro" 2>/dev/null || true

if (( ! DRY )); then
    dest="$BACKUP_DIR/$(date -u '+%Y%m%dT%H%M%SZ')"
    mkdir -p "$dest/cron.d"
    cp -a /etc/cron.d/. "$dest/cron.d/" 2>/dev/null || true
    cp -a /etc/crontab "$dest/etc-crontab" 2>/dev/null || true
    cp -a "$ct_neuro" "$dest/${U}-crontab"
    crontab -l >"$dest/root-crontab" 2>/dev/null || true
    log "backup written: $dest"
    mapfile -t old < <(ls -1dt "$BACKUP_DIR"/*/ 2>/dev/null | tail -n +"$((KEEP_BACKUPS + 1))")
    for o in "${old[@]}"; do
        [[ -n "$o" && -d "$o" ]] && rm -rf -- "${o:?}"
    done
else
    dest="(dry-run, no backup)"
fi

missing=()
for entry in "${EXPECTED[@]}"; do
    file="${entry%%::*}"; rest="${entry#*::}"; needle="${rest%%::*}"; label="${rest#*::}"
    src="$file"
    [[ "$file" == "$CT_AGENT" ]] && src="$ct_neuro"
    if [[ ! -f "$src" ]]; then
        missing+=("$label [нет файла $file]")
    elif ! grep -v '^[[:space:]]*#' "$src" | grep -qF -- "$needle"; then
        missing+=("$label [слот пропал в $file]")
    fi
done
for s in "${SCRIPTS[@]}"; do
    if [[ ! -f "$s" ]]; then missing+=("скрипт отсутствует: $s")
    elif [[ ! -x "$s" ]]; then missing+=("скрипт не исполняемый: $s"); fi
done

sig=""
if (( ${#missing[@]} )); then
    sig=$(printf '%s\n' "${missing[@]}" | LC_ALL=C sort | sha256sum | cut -c1-16)
fi
log "manifest check: missing=${#missing[@]} sig=${sig:-none} (prev=${prev_sig:-none})"
(( DRY )) && { printf '  - %s\n' "${missing[@]:-ничего не пропало}"; exit 0; }

if [[ "$sig" != "$prev_sig" ]]; then
    if (( ${#missing[@]} )); then
        if ! python3 "$PUT" "cron-manifest-$sig" "Сервер: пропали слоты расписания:
$(printf '• %s\n' "${missing[@]}")
Бэкап: ${dest}" >/dev/null; then
            log "ERR outbox write failed, state kept for retry"; exit 1
        fi
    elif [[ -n "$prev_sig" ]]; then
        python3 "$PUT" "cron-manifest-ok-$now" "Сервер: все слоты расписания на месте." >/dev/null \
            || { log "ERR outbox write failed, state kept for retry"; exit 1; }
    fi
fi

tmp=$(mktemp "$STATE_FILE.XXXXXX")
printf '{"missing_sig":"%s","missing_count":%s,"checked_at":%s}\n' "${sig:-_}" "${#missing[@]}" "$now" >"$tmp"
mv -f "$tmp" "$STATE_FILE"
exit 0
