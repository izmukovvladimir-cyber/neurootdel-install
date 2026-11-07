#!/usr/bin/env bash
# memory-offsite.sh -- nightly OFF-SERVER copy of the agents' memory to the owner's private GitHub repo.
# Installed by neurootdel-install into <lib dir>, settings from <lib dir>/guard.conf. Runs as the agent
# user from /etc/cron.d/<user>-memory-offsite hourly with --auto: the copy is made only in the 03:xx
# hour of the OWNER's clock (OWNER_TIMEZONE), after the local backup (03:30) and before the 04:00 reset.
#
# Why: memory-backup.sh keeps its archives on the same disk; a dead disk or a deleted server takes
# both. This copy lives on GitHub.
#
# Where: OFFSITE_REPO in guard.conf (git@github.com:<owner>/<repo>.git, a PRIVATE repo of the owner),
#   branch main. Auth: the deploy key ~/.ssh/offsite_ed25519 (made by neurootdel-offsite-setup; the
#   owner adds its public half to the repo as a Deploy key with write access). GitHub's host key is
#   pinned in ~/.ssh/known_hosts_offsite, StrictHostKeyChecking=yes.
#   OFFSITE_REPO empty = the copy is off: the run only records OFF, the morning watch
#   (memory-offsite-watch.sh) and neurootdel-verify tell the owner "no off-server copy".
#
# What: the same set as the local backup: each agent's .claude/{CLAUDE.md,core,memory,library},
#   their auto-memory dirs ~/.claude/projects/*/memory, ~/.claude/CLAUDE.md, ~/knowledge, the shared
#   team rules file, plus the Auditor's role and memory (~/.hermes/SOUL.md, ~/.hermes/memories).
#   Text only: secrets, sessions, keys, *.bak-*, media (pdf, images, video, audio, zip) are excluded
#   by name, files over 5 MB are skipped. Symlinks are kept as links (never followed).
#
# THE GATE, before every commit (fail closed, nothing is committed or pushed on any hit or error):
#   1. secret shapes (bot tokens, API keys, GitHub tokens, url user:pass@, Bearer literals, proxy lines)
#      are MASKED in the staging copy to <REDACTED-type>; the source is never touched. The copy is
#      therefore NOT byte-exact: it restores memory and meaning, not working credentials;
#   2. any non-text file left in the staging (a NUL byte anywhere) stops the run: the scan below
#      cannot read it;
#   3. all shapes are searched again plus private key blocks; any match, or a failed search, stops
#      the run (rc 3). Only paths and line numbers are logged, never a value.
#   The gate catches SHAPES, not meaning: a password written as free text is not seen. The narrow
#   list of what is copied is the first barrier, the gate the second.
# Push: never forced. A remote that moved ahead (someone wrote to the repo) stops the run (rc 4) and
#   is reported; a failed push is retried by the next run (an unchanged tree is pushed if not there).
#
# Status: ${STATE}/last holds ONE line "OK|ERR|OFF <epoch> <repo tag> <text>" read by the watch and the
#   verify; <repo tag> = first 12 hex of sha256 of the repo address the run pushed to ("-" when none), so an
#   OK of an earlier repo never counts for the one in guard.conf now;
#   log ${STATE}/offsite.log (paths only, never secret values).
# Stop: touch ${STATE}/STOP (or remove the cron file). Restore: git clone the repo, files are under home/.
# Exit: 0 ok / off / stopped / not the hour, 1 setup error, 2 sources unreadable, 3 gate, 4 push.
#   OFFSITE_SKIP_RC=<n>: off / STOP / a held lock exit <n> instead of 0 (neurootdel-offsite-setup uses it
#   to tell "this run copied" from "this run was skipped").
# Tests: OFFSITE_STATE (state dir), OFFSITE_REMOTE (remote URL or local bare repo, no ssh),
#        OFFSITE_DRY=1 (build and gate, no commit/push), OFFSITE_TEST_BREAK_SCAN=1 (broken pattern).
set -euo pipefail
umask 077

LIB="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CONF="${NEUROOTDEL_GUARD_CONF:-$LIB/guard.conf}"
[[ -f "$CONF" ]] || { echo "missing: $CONF" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONF"
H="${AGENT_HOME:?AGENT_HOME missing in guard.conf}"
if [[ "${1:-}" == "--auto" && "$(TZ="${OWNER_TIMEZONE:-Europe/Moscow}" date +%-H)" != 3 ]]; then
    exit 0
fi

STATE="${OFFSITE_STATE:-$H/backups/offsite}"
REPO_DIR="$STATE/repo"
LOG="$STATE/offsite.log"
KEY="$H/.ssh/offsite_ed25519"
KH="$H/.ssh/known_hosts_offsite"
REMOTE="${OFFSITE_REMOTE:-${OFFSITE_REPO:-}}"
read -r -a AGENTS <<< "${CHANNEL_AGENTS:-jarvis} richard"

mkdir -p "$STATE"
chmod 700 "$STATE"
log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG"; }
# status <OK|ERR|OFF> <text> -- the one line the watch and the verify read.
status() {
    local tag=-
    [[ -n "$REMOTE" ]] && tag=$(printf '%s' "$REMOTE" | sha256sum | cut -c1-12)
    printf '%s %s %s %s\n' "$1" "$(date +%s)" "$tag" "$2" >"$STATE/.last.tmp" && mv -f "$STATE/.last.tmp" "$STATE/last"
}
die() { log "ERR $1"; status ERR "$1"; echo "$1" >&2; exit "${2:-1}"; }

SKIP_RC="${OFFSITE_SKIP_RC:-0}"
[[ "$SKIP_RC" =~ ^[0-9]+$ ]] || SKIP_RC=0
[[ -e "$STATE/STOP" ]] && { log "STOP present, skipped"; exit "$SKIP_RC"; }
if [[ -z "$REMOTE" ]]; then
    log "OFF: OFFSITE_REPO is empty in $CONF, no off-server copy"
    status OFF "OFFSITE_REPO не задан"
    exit "$SKIP_RC"
fi

exec 9>"$STATE/.lock"
flock -n 9 || { log "another run holds $STATE/.lock, skipped"; exit "$SKIP_RC"; }

command -v rsync >/dev/null || die "нет rsync на сервере"
command -v git >/dev/null || die "нет git на сервере"
command -v python3 >/dev/null || die "нет python3: проверка файлов не может работать"

# An ssh remote goes through the deploy key and the pinned host key only; a local path (tests) needs none.
if [[ "$REMOTE" == git@* ]]; then
    [[ -f "$KEY" ]] || die "нет ключа $KEY: запусти sudo neurootdel-offsite-setup"
    [[ -s "$KH" ]] || die "нет закреплённого ключа GitHub $KH: запусти sudo neurootdel-offsite-setup"
    export GIT_SSH_COMMAND="ssh -i $KEY -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=20 -o UserKnownHostsFile=$KH -o StrictHostKeyChecking=yes"
fi
g() { git -C "$REPO_DIR" -c core.hooksPath=/dev/null -c core.quotePath=false "$@"; }

# ---------------------------------------------------------------- staging

prepare_repo() {
    if [[ ! -d "$REPO_DIR/.git" ]]; then
        mkdir -p "$REPO_DIR"
        git -C "$REPO_DIR" init -q -b main
        g config user.name "memory-offsite"
        g config user.email "memory-offsite@localhost"
        g remote add origin "$REMOTE"
        # A remote that already has history: stand on it, else the first push is non-fast-forward forever.
        if g fetch -q origin main 2>>"$LOG"; then
            g reset -q --hard FETCH_HEAD
            log "prepare: took the existing history of origin/main"
        fi
    fi
    # The owner may point the copy at another repo (neurootdel-offsite-setup): follow guard.conf.
    if [[ "$(g remote get-url origin 2>/dev/null || true)" != "$REMOTE" ]]; then
        g remote set-url origin "$REMOTE" 2>/dev/null || g remote add origin "$REMOTE"
        log "prepare: remote set to the repo from guard.conf"
    fi
}

# Only these may sit at the top of the staging; anything else would ride along with `git add -A`.
ALLOWED_TOP=(home README.md .git)
reset_tree() {
    local entry base keep d
    rm -rf "${REPO_DIR:?}/home"
    for entry in "$REPO_DIR"/* "$REPO_DIR"/.[!.]*; do
        [[ -e "$entry" || -L "$entry" ]] || continue
        base="$(basename "$entry")"
        keep=0
        for d in "${ALLOWED_TOP[@]}"; do [[ "$base" == "$d" ]] && keep=1 && break; done
        if (( ! keep )); then
            log "WARN removing a stray object from the staging root: $base"
            rm -rf "${REPO_DIR:?}/$base"
        fi
    done
}

# One list for rsync. Secrets, sessions, caches, backups, and media attachments (not memory: four PDFs
# in a findings dir once failed the binary gate night after night; media are dropped by name, the
# gate stays strict for any other non-text file).
EXCLUDES=(
    --exclude=secrets/          --exclude=.ssh/
    --exclude=session-env/      --exclude='*.session'
    --exclude='*.session-journal'
    --exclude=.claude.json      --exclude='*.env'
    --exclude=.env              --exclude='.env.*'
    --exclude='*.key'           --exclude='*.pem'
    --exclude='*.p12'           --exclude='*token*'
    --exclude='*credential*'    --exclude=auth.json
    --exclude=config.yaml       --exclude=.mcp.json
    --exclude='id_rsa*'         --exclude='id_ed25519*'
    --exclude='id_ecdsa*'       --exclude='id_dsa*'
    --exclude='*.sqlite'        --exclude='*.db'
    --exclude=__pycache__/      --exclude='*.pyc'
    --exclude=node_modules/     --exclude=.venv/
    --exclude=venv/             --exclude=.git/
    --exclude='*.bak-*'         --exclude='*.backup-*'
    --exclude='*.jsonl'
    --exclude='*.[pP][dD][fF]'      --exclude='*.[pP][nN][gG]'
    --exclude='*.[jJ][pP][gG]'      --exclude='*.[jJ][pP][eE][gG]'
    --exclude='*.[wW][eE][bB][pP]'  --exclude='*.[gG][iI][fF]'
    --exclude='*.[hH][eE][iI][cC]'
    --exclude='*.[mM][pP]4'         --exclude='*.[mM][oO][vV]'
    --exclude='*.[wW][eE][bB][mM]'
    --exclude='*.[mM][pP]3'         --exclude='*.[oO][gG][gG]'
    --exclude='*.[oO][gG][aA]'      --exclude='*.[wW][aA][vV]'
    --exclude='*.[mM]4[aA]'         --exclude='*.[zZ][iI][pP]'
)

collect_items() {
    local a part d proj f
    for a in "${AGENTS[@]}"; do
        for part in CLAUDE.md core memory library; do
            [[ -e "$H/.claude-lab/$a/.claude/$part" ]] && printf '%s\n' ".claude-lab/$a/.claude/$part"
        done
    done
    for d in "$H"/.claude/projects/*/memory; do
        [[ -d "$d" ]] || continue
        proj="$(basename "$(dirname "$d")")"
        for a in "${AGENTS[@]}"; do
            if [[ "$proj" == *"--claude-lab-$a" || "$proj" == *"--claude-lab-$a--"* ]]; then
                printf '%s\n' "${d#"$H"/}"
                break
            fi
        done
    done
    for f in .claude/CLAUDE.md knowledge .claude-lab/shared/team-rules.md .hermes/SOUL.md .hermes/memories; do
        [[ -e "$H/$f" ]] && printf '%s\n' "$f"
    done
    return 0
}

# ---------------------------------------------------------------- gate

# Shapes MASKED in the staging. The sk- shape needs one solid block (no dashes), else it hits
# ordinary words in file names (ask-before-sending); Anthropic keys have their own shape.
MASK_PATTERNS=(
    'telegram-bot:[0-9]{8,10}:[A-Za-z0-9_-]{35}'
    'github-token:gh[pousr]_[A-Za-z0-9]{36,}'
    'github-pat:github_pat_[A-Za-z0-9_]{50,}'
    'anthropic:sk-ant-[a-z]{2,6}[0-9]{2}-[A-Za-z0-9_-]{20,}'
    'openai-project:sk-(proj|svcacct|admin)-[A-Za-z0-9_-]{20,}'
    'openai-anthropic:(^|[^A-Za-z0-9_-])sk-(ant-|proj-)?[A-Za-z0-9]{24,}'
    'aws-key:(AKIA|ASIA)[0-9A-Z]{16}'
    'url-with-password:([a-z][a-z0-9+.-]*://)[^/[:space:]:@]+:[^/[:space:]@]+@'
    'bearer-literal:[Bb]earer [A-Za-z0-9_.-]{30,}'
    'proxy-line:([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{2,5}:[A-Za-z0-9_-]{3,}:[A-Za-z0-9_-]{3,}'
)
# These are never masked: they mean a file that must not be here at all slipped past the excludes.
# The tail is split so this very script (and its tests) never hold the literal shape.
_KEY_TAIL='PRIVATE'' KEY-----'
FATAL_PATTERNS=(
    "private-key:-----BEGIN [A-Z ]*$_KEY_TAIL"
)

# mask_secrets -- replaces shapes in the staging (placeholder without ':' so it never re-matches).
mask_secrets() {
    local masked=0 entry name pat repl f
    for entry in "${MASK_PATTERNS[@]}"; do
        name="${entry%%:*}"
        pat="${entry#*:}"
        case "$name" in
            url-with-password) repl="\1<REDACTED-$name>@" ;;
            openai-anthropic)  repl="\1<REDACTED-$name>" ;;
            *)                 repl="<REDACTED-$name>" ;;
        esac
        while IFS= read -r -d '' f; do
            sed -i -E "s#$pat#$repl#g" "$f" || return 1
            log "MASKED[$name] ${f#"$REPO_DIR"/}"
            masked=$((masked + 1))
        done < <(grep -rIElZ --exclude-dir=.git -E -e "$pat" "$REPO_DIR" 2>>"$LOG")
    done
    echo "$masked"
}

# binary_scan -- rc 0 clean, 1 a non-text file (paths printed), 2 unreadable. Whole files, symlinks skipped.
binary_scan() {
    python3 -I - "$REPO_DIR" <<'PY'
import os
import sys

root = sys.argv[1]
bad = []
for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
    dirnames[:] = [d for d in dirnames if not (dirpath == root and d == ".git")]
    for name in filenames:
        p = os.path.join(dirpath, name)
        if os.path.islink(p):
            continue
        try:
            with open(p, "rb") as fh:
                while chunk := fh.read(1 << 20):
                    if b"\x00" in chunk:
                        bad.append(os.path.relpath(p, root))
                        break
        except OSError as e:
            print(f"UNREADABLE {os.path.relpath(p, root)}: {e.strerror}")
            sys.exit(2)
for b in bad:
    print(f"BINARY {b}")
sys.exit(1 if bad else 0)
PY
}

# secret_scan -- prints the number of hits, or -1 when a search itself failed (grep rc >= 2).
secret_scan() {
    local hits=0 entry name pat found grc rcfile
    local -a pats=("${MASK_PATTERNS[@]}" "${FATAL_PATTERNS[@]}")
    [[ "${OFFSITE_TEST_BREAK_SCAN:-0}" == "1" ]] && pats+=('broken-on-purpose:[')
    rcfile="$(mktemp "$STATE/.scanrc.XXXXXX")" || { echo "-1"; return; }
    for entry in "${pats[@]}"; do
        name="${entry%%:*}"
        pat="${entry#*:}"
        # Only path and line number are kept: the value never reaches the log.
        while IFS= read -r found; do
            log "SECRET[$name] $found"
            hits=$((hits + 1))
        done < <({ grep -rIEn --exclude-dir=.git -o -e "$pat" "$REPO_DIR" 2>>"$LOG"; echo $? >"$rcfile"; } | cut -d: -f1,2)
        # The status comes from the file: PIPESTATUS of a process substitution is not this grep's.
        grc=$(cat "$rcfile" 2>/dev/null || echo 2)
        if (( grc >= 2 )); then
            log "ERR search of shape $name failed (grep rc=$grc)"
            rm -f "$rcfile"
            echo "-1"
            return
        fi
    done
    rm -f "$rcfile"
    echo "$hits"
}

# name_scan -- file names and symlink targets are committed too, and the content scans never see them:
# any secret shape there stops the run. rc 0 clean, 1 hit, 2 search failed. Nothing of the match is
# logged (the path itself is the secret), only the shape name. Runs before anything logs a path.
name_scan() {
    local entry name pat rc list hit=0
    list="$(mktemp "$STATE/.names.XXXXXX")" || return 2
    if ! { find "$REPO_DIR/home" -mindepth 1 -printf '%P\0' && find "$REPO_DIR/home" -type l -printf '%l\0'; } >"$list"; then
        rm -f "$list"; return 2
    fi
    for entry in "${MASK_PATTERNS[@]}" "${FATAL_PATTERNS[@]}"; do
        name="${entry%%:*}"
        pat="${entry#*:}"
        rc=0
        grep -qzE -e "$pat" "$list" 2>>"$LOG" || rc=$?
        if (( rc == 0 )); then log "SECRET-NAME[$name] a file name or a link target (not logged)"; hit=1
        elif (( rc >= 2 )); then rm -f "$list"; return 2; fi
    done
    rm -f "$list"
    return "$hit"
}

# ---------------------------------------------------------------- run

prepare_repo
reset_tree
mapfile -t ITEMS < <(collect_items)
(( ${#ITEMS[@]} > 0 )) || die "нечего копировать: память агентов не читается, прогон отменён" 2
mkdir -p "$REPO_DIR/home"
rsync_rc=0
# rsync messages name files, and a file name may itself be a secret (name_scan runs after the copy):
# they are counted, never logged.
rerr="$(mktemp "$STATE/.rsync.XXXXXX")"
(cd "$H" && rsync -a --relative --max-size=5m "${EXCLUDES[@]}" -- "${ITEMS[@]}" "$REPO_DIR/home/") 2>"$rerr" || rsync_rc=$?
(( rsync_rc == 0 )) || log "rsync rc=$rsync_rc, $(wc -l <"$rerr") message(s) not logged (they may hold file names)"
rm -f "$rerr"
# 24 = some source vanished while copying (a live memory dir), the copy is still whole.
(( rsync_rc == 0 || rsync_rc == 24 )) || die "копирование упало (rsync rc=$rsync_rc), прогон отменён" 2
nrules=0
for a in "${AGENTS[@]}"; do
    [[ -f "$H/.claude-lab/$a/.claude/core/rules.md" ]] || continue
    [[ -f "$REPO_DIR/home/.claude-lab/$a/.claude/core/rules.md" ]] || die "в копии нет core/rules.md агента $a, прогон отменён" 2
    nrules=$((nrules + 1))
done

cat >"$REPO_DIR/README.md" <<'EOF'
# Agents' memory, off-server copy

Written every night by memory-offsite.sh of the agents' server. Do not edit here: the next run
rebuilds the tree, and a commit made here stops the nightly copy until it is resolved.

home/ mirrors the agent user's home: each agent's CLAUDE.md, core/, memory/, library/, the auto-memory
dirs, the shared rules, the Auditor's role and memory.

Not here, by design: secrets, keys, sessions, media. Secret-shaped strings are replaced with
<REDACTED-type>, so this copy restores memory and meaning, not credentials.
EOF

nrc=0
name_scan || nrc=$?
(( nrc == 0 )) || die "проверка: имя файла или цель ссылки похожи на ключ (или поиск упал, rc=$nrc), ничего не выгружено" 3
masked=$(mask_secrets) || die "маскирование секретов упало, ничего не выгружено" 3
brc=0
binout=$(binary_scan) || brc=$?
if (( brc != 0 )); then
    while IFS= read -r line; do [[ -n "$line" ]] && log "GATE $line"; done <<<"$binout"
    die "проверка: в копии нетекстовые или нечитаемые файлы, ничего не выгружено (пути в $LOG)" 3
fi
hits=$(secret_scan)
[[ "$hits" == "-1" ]] && die "проверка: поиск секретов не отработал, ничего не выгружено" 3
(( hits == 0 )) || die "проверка: после маскирования осталось похожих на ключ мест: $hits, ничего не выгружено (пути в $LOG)" 3

nfiles=$(find "$REPO_DIR/home" \( -type f -o -type l \) | wc -l)
if [[ "${OFFSITE_DRY:-0}" == "1" ]]; then
    log "DRY items=${#ITEMS[@]} files=$nfiles masked=$masked, no commit"
    exit 0
fi

# Forced add with no ignore files: a .gitignore copied from the memory (or a global one) must never
# drop a file that passed the gate. Then the index must hold exactly what the staging holds.
g -c core.excludesFile=/dev/null add -A -f -- .
nindex=$(g ls-files -z -- home | tr -cd '\0' | wc -c)
(( nindex == nfiles )) || die "в коммит попадает не всё: файлов в копии $nfiles, в индексе $nindex, ничего не выгружено" 3
if ! g diff --cached --quiet; then
    g commit -q -m "memory copy $(TZ="${OWNER_TIMEZONE:-Europe/Moscow}" date '+%Y-%m-%d %H:%M') (files $nfiles, masked $masked)"
fi
g rev-parse -q --verify HEAD >/dev/null || die "нет коммита для выгрузки" 1

# Push only on top of what GitHub has: never forced, never merged.
if g fetch -q origin main 2>>"$LOG"; then
    behind=$(g rev-list --count HEAD..FETCH_HEAD) || die "не удалось сравнить с GitHub" 4
    if (( behind > 0 )); then
        die "в репозиторий на GitHub кто-то писал (на $behind коммит(ов) впереди): выгрузка остановлена, сама ничего не сливает" 4
    fi
    ahead=$(g rev-list --count FETCH_HEAD..HEAD) || die "не удалось сравнить с GitHub" 4
    if (( ahead == 0 )); then
        log "OK up to date, files=$nfiles agents_rules=$nrules"
        status OK "без изменений, файлов $nfiles"
        exit 0
    fi
fi
# A failed fetch (empty repo has no main yet, or the network) falls through to the push; a real
# divergence is then refused by GitHub, never forced.
if g push -q origin HEAD:refs/heads/main 2>>"$LOG"; then
    log "OK pushed $(g rev-parse --short HEAD) files=$nfiles masked=$masked agents_rules=$nrules"
    status OK "выгружено, файлов $nfiles"
    exit 0
fi
die "выгрузка на GitHub не прошла (ключ не добавлен в репозиторий как Deploy key с записью, сеть или репозиторий ушёл вперёд); следующая ночь повторит" 4
