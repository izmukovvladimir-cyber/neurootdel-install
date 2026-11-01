#!/usr/bin/env bash
# memory-backup.sh -- nightly LOCAL backup of the agents' memory. Installed by neurootdel-install
# into <lib dir>, settings from <lib dir>/guard.conf. Runs as the agent user from
# /etc/cron.d/<user>-memory-backup hourly with --auto: the backup is made only in the 03:xx
# hour of the OWNER's clock (OWNER_TIMEZONE), before the nightly session reset at 04:00.
#
# What: each agent's .claude/{CLAUDE.md,core,memory}, their auto-memory dirs
# ~/.claude/projects/*/memory, ~/.claude/CLAUDE.md, ~/knowledge, the shared team rules file.
# Not: secrets, sessions, .env/.key/.pem, credentials, *.bak-* copies.
# Where: $DEST/memory-YYYYmmdd-HHMM.tar.gz (dir 700, files 600), kept KEEP_DAYS days.
# Stop: touch $DEST/STOP (or remove the cron file). Restore: tar -xzf <archive> -C /some/dir.
set -euo pipefail
umask 077

LIB="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CONF="${NEUROOTDEL_GUARD_CONF:-$LIB/guard.conf}"
[[ -f "$CONF" ]] || { echo "missing: $CONF" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONF"
H="$AGENT_HOME"
if [[ "${1:-}" == "--auto" && "$(TZ="${OWNER_TIMEZONE:-Europe/Moscow}" date +%-H)" != 3 ]]; then
    exit 0
fi
DEST="${MEMBK_DEST:-$H/backups/memory}"
KEEP_DAYS="${MEMBK_KEEP_DAYS:-14}"
# Channel agents plus any other workspace with memory (richard), only those that exist.
read -r -a AGENTS <<< "${CHANNEL_AGENTS:-jarvis} richard"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERR $*"; exit 1; }

[[ "$KEEP_DAYS" =~ ^[0-9]+$ ]] || die "bad KEEP_DAYS"
mkdir -p "$DEST"
chmod 700 "$DEST"
# Work from a dir this user can always enter (sudo -u from /root left find unable to restore cwd).
cd "$DEST"
DEST="$PWD"
[[ -e "$DEST/STOP" ]] && { log "STOP present, skipped"; exit 0; }

exec 9>"$DEST/.lock"
flock -n 9 || die "another run holds $DEST/.lock"

items=()
for a in "${AGENTS[@]}"; do
    for part in CLAUDE.md core memory; do
        [[ -e "$H/.claude-lab/$a/.claude/$part" ]] && items+=(".claude-lab/$a/.claude/$part")
    done
done
for d in "$H"/.claude/projects/*/memory; do
    [[ -d "$d" ]] || continue
    proj="$(basename "$(dirname "$d")")"
    for a in "${AGENTS[@]}"; do
        if [[ "$proj" == *"--claude-lab-$a" || "$proj" == *"--claude-lab-$a--"* ]]; then
            items+=("${d#"$H"/}")
            break
        fi
    done
done
for f in .claude/CLAUDE.md knowledge .claude-lab/shared/team-rules.md; do
    [[ -e "$H/$f" ]] && items+=("$f")
done
(( ${#items[@]} > 0 )) || die "nothing to back up"

stamp="$(TZ="${OWNER_TIMEZONE:-Europe/Moscow}" date +%Y%m%d-%H%M)"
out="$DEST/memory-$stamp.tar.gz"
tmp="$(mktemp "$DEST/.memory-$stamp.XXXXXX")"
trap 'rm -f "${tmp:?}"' EXIT

rc=0
tar -C "$H" -czf "$tmp" \
    --exclude='secrets' --exclude='.ssh' --exclude='session-env' \
    --exclude='*.session' --exclude='*.session-journal' \
    --exclude='.env' --exclude='.env.*' --exclude='*.env' --exclude='*.env.*' --exclude='*.key' --exclude='*.pem' \
    --exclude='.credentials.json' --exclude='*credential*' \
    --exclude='id_rsa*' --exclude='id_ed25519*' --exclude='id_ecdsa*' --exclude='id_dsa*' \
    --exclude='__pycache__' --exclude='node_modules' --exclude='*.bak-*' \
    --warning=no-file-changed \
    "${items[@]}" || rc=$?
# GNU tar: 1 = some file changed while being read (archive still valid), 2 = fatal.
(( rc <= 1 )) || die "tar failed rc=$rc"

gzip -t "$tmp" || die "gzip integrity check failed"
listing="$(tar -tzf "$tmp")" || die "cannot list archive"
for a in "${AGENTS[@]}"; do
    [[ -f "$H/.claude-lab/$a/.claude/core/rules.md" ]] || continue
    grep -qx ".claude-lab/$a/.claude/core/rules.md" <<<"$listing" || die "archive misses $a core/rules.md"
done
if grep -Ei '(^|/)(\.env(\..*)?|[^/]*\.env(\..*)?|[^/]*\.(pem|key)|\.credentials\.json|[^/]*credential[^/]*|[^/]*\.session(-journal)?|id_(rsa|ed25519|ecdsa|dsa)[^/]*)$|(^|/)(secrets|\.ssh)/' <<<"$listing" >/dev/null; then
    die "archive would contain a secret-shaped file, not published"
fi
n="$(wc -l <<<"$listing")"

chmod 600 "$tmp"
mv -f "$tmp" "$out"
trap - EXIT

find "$DEST" -maxdepth 1 -type f -name 'memory-*.tar.gz' -mmin +"$((KEEP_DAYS * 1440))" -delete
kept="$(find "$DEST" -maxdepth 1 -type f -name 'memory-*.tar.gz' | wc -l)"
log "OK $out entries=$n bytes=$(stat -c %s "$out") tar_rc=$rc kept=$kept"
