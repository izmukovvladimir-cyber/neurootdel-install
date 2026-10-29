#!/usr/bin/env bash
# resource-watchdog.sh -- RAM / swap / disk / CPU load thresholds (installed by the installer).
# Alerts go through outbox-put.py, routed by ALERT_MODE in guard.conf like the guard's own.
# Cron: /etc/cron.d/<user>-service-watch, every 5 min, root.
# State: /var/lib/<user>-resource ; log: /var/log/<user>-resource.log
# Stop: touch /var/lib/<user>-resource/STOP
# --dry-run: measure and print what would be alerted, nothing written to the outbox.
set -euo pipefail
LIB="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck disable=SC1091
. "${NEUROOTDEL_GUARD_CONF:-$LIB/guard.conf}"
U="${AGENT_USER:?AGENT_USER missing in guard.conf}"

readonly PUT="$LIB/outbox-put.py"
readonly STATE_DIR="${NEUROOTDEL_RESOURCE_STATE:-/var/lib/${U}-resource}"
readonly LOG_FILE="${NEUROOTDEL_RESOURCE_LOG:-/var/log/${U}-resource.log}"
readonly LOG_MAX_BYTES=$((5 * 1024 * 1024))
readonly ALERT_COOLDOWN_SEC=10800  # 3 h between same-metric alerts

readonly RAM_WARN_PCT=85
readonly RAM_FAIL_PCT=95
readonly SWAP_WARN_PCT=85
readonly SWAP_FAIL_PCT=95
readonly SWAP_AVAIL_RAM_MB=600
readonly SWAP_GROWTH_MB=200
readonly SWAP_GROWTH_AVAIL_MB=2048
readonly DISK_WARN_PCT=85
readonly DISK_FAIL_PCT=95
readonly LOAD_FAIL_MULT=2

DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1

(( DRY )) || mkdir -p "$STATE_DIR"
[[ -e "$STATE_DIR/STOP" ]] && exit 0

log() {
    if (( DRY )); then printf '%s\n' "$*"; return 0; fi
    if [[ -f "$LOG_FILE" ]] && (( $(stat -c %s "$LOG_FILE") > LOG_MAX_BYTES )); then
        mv -f "$LOG_FILE" "$LOG_FILE.1"
    fi
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE"
}

# State file holds "<epoch> <level>" (level 1 = WARN, 2 = FAIL). A higher level than the last
# sent one goes out at once; the same or lower level waits out the cooldown.
within_cooldown() {  # $1=metric $2=level
    local f="$STATE_DIR/resource-$1.last_alert" last lvl now
    [[ -f "$f" ]] || return 1
    read -r last lvl <"$f" 2>/dev/null || return 1
    [[ "$last" =~ ^[0-9]+$ ]] || return 1
    [[ "$lvl" =~ ^[12]$ ]] || lvl=2  # old format: treat as FAIL
    (( $2 > lvl )) && return 1
    now=$(date +%s)
    (( now - last < ALERT_COOLDOWN_SEC ))
}

alert() {  # $1=metric $2=level(1 WARN|2 FAIL) $3=text ; marks only when the item reached the outbox
    local metric="$1" level="$2" text="Сервер: $3"
    within_cooldown "$metric" "$level" && return 0
    if (( DRY )); then printf '[dry] ALERT %s L%s: %s\n' "$metric" "$level" "$text"; return 0; fi
    if python3 "$PUT" "resource-$metric" "$text" >/dev/null; then
        printf '%s %s\n' "$(date +%s)" "$level" >"$STATE_DIR/resource-$metric.last_alert"
        log "alert $metric L$level queued to outbox"
    else
        log "ERROR: outbox write failed for $metric"
    fi
}

check_ram() {
    local total avail used pct
    read -r total avail < <(free -m | awk '/^Mem:/ {print $2, $7}')
    used=$(( total - avail ))
    pct=$(( used * 100 / total ))
    log "ram: ${pct}% real-used (${used}/${total}M, avail=${avail}M)"
    if (( pct >= RAM_FAIL_PCT )); then
        alert ram 2 "ПАМЯТЬ КРИТИЧНО: ${pct}% занято (${used}M/${total}M), скоро OOM. Топ:
$(ps aux --sort=-rss | awk 'NR>1 && NR<=6 {printf "%-10s %sM  %s\n", $1, int($6/1024), $11}')"
    elif (( pct >= RAM_WARN_PCT )); then
        alert ram 1 "память греется: ${pct}% занято (${used}M/${total}M)."
    fi
}

check_swap() {
    local used total pct avail prev delta last_file reason
    read -r used total < <(free -m | awk '/^Swap:/ {print $3, $2}')
    (( total == 0 )) && { log "swap: none configured"; return 0; }
    pct=$(( used * 100 / total ))
    avail=$(free -m | awk '/^Mem:/ {print $7}')
    last_file="$STATE_DIR/resource-swap.last_used"
    prev=0
    [[ -f "$last_file" ]] && prev=$(cat "$last_file" 2>/dev/null || echo 0)
    [[ "$prev" =~ ^[0-9]+$ ]] || prev=0
    delta=$(( used - prev ))
    (( DRY )) || echo "$used" >"$last_file"
    log "swap: ${pct}% (${used}/${total}M) avail_ram=${avail}M delta=${delta}M"
    local tight=0 growing=0
    (( avail < SWAP_AVAIL_RAM_MB )) && tight=1
    (( delta >= SWAP_GROWTH_MB && avail < SWAP_GROWTH_AVAIL_MB )) && growing=1
    (( tight == 0 && growing == 0 )) && return 0
    if (( tight && growing )); then reason="RAM мало (avail=${avail}M) и свап вырос на ${delta}M за 5 мин"
    elif (( tight )); then reason="RAM мало (avail=${avail}M)"
    else reason="свап вырос на ${delta}M за 5 мин"; fi
    if (( pct >= SWAP_FAIL_PCT )); then
        alert swap 2 "СВАП КРИТИЧНО: ${pct}% (${used}M/${total}M). Причина: ${reason}."
    elif (( pct >= SWAP_WARN_PCT )); then
        alert swap 1 "свап высок: ${pct}% (${used}M/${total}M). Причина: ${reason}."
    fi
}

check_disk() {
    local pct used_total
    read -r pct used_total < <(df -h / | awk 'NR==2 {gsub("%","",$5); print $5, $3"/"$2}')
    log "disk: ${pct}% (${used_total})"
    if (( pct >= DISK_FAIL_PCT )); then
        alert disk 2 "ДИСК КРИТИЧНО: ${pct}% занято (${used_total}). Нужна чистка."
    elif (( pct >= DISK_WARN_PCT )); then
        alert disk 1 "диск заполняется: ${pct}% (${used_total})."
    fi
}

check_load() {
    local load1 cores threshold
    load1=$(awk '{print $1}' /proc/loadavg)
    cores=$(nproc)
    threshold=$(( cores * LOAD_FAIL_MULT ))
    log "load1: ${load1} (cores=${cores}, fail>=${threshold})"
    if awk -v l="$load1" -v t="$threshold" 'BEGIN { exit !(l >= t) }'; then
        alert load 2 "нагрузка CPU высокая: load1=${load1} при ${cores} ядрах (порог ${threshold}). Топ:
$(ps aux --sort=-%cpu | awk 'NR>1 && NR<=6 {printf "%-10s %s%%  %s\n", $1, $3, $11}')"
    fi
}

check_ram
check_swap
check_disk
check_load
