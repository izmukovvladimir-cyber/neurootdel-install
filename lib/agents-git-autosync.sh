#!/usr/bin/env bash
# agents-git-autosync.sh -- local git history of the agents' dirs (installed by the installer).
# Commit when something changed, NO push (there is no remote and none must be added).
# Purpose: roll back settings, rules, memory.
#
# Dirs: ~/.claude-lab/<agent>/.claude for CHANNEL_AGENTS + richard (repo owned by the agent user).
# What is tracked: whitelist .gitignore (CLAUDE.md, settings.json, core/, skills/, business/,
#   drafts/, library/, _snapshots/ with a copy of the dashi plugin settings.json).
#   Never: secrets/, .env, *.key, *.pem, *.bak*, transcripts/, .mcp.json (bearer tokens),
#   core/hot/pre-compact/, locks, node_modules, db/sqlite/session files.
# Gate before every commit (fail closed: any git error = no commit, index reset):
#   files > 2 MB and binary files are unstaged and excluded; the WHOLE index (= tree of the
#   next commit) is grepped for key/password patterns, hits are unstaged, added to
#   .git/info/exclude and reported ONCE to the guard outbox (file names only, never the match);
#   on the very first commit of a fresh repo only logged.
#   Then the index is grepped again; anything left = no commit.
# Cron: /etc/cron.d/<user>-service-watch (*/30, root). Root only, git runs as the agent user.
# Stop: touch /var/lib/<user>-autosync/STOP
# Roll back a file: runuser -u <user> -- git -C <dir> log --oneline -- <file>
#                   runuser -u <user> -- git -C <dir> checkout <sha> -- <file>
# Uninstall: rm -rf <dir>/.git <dir>/.gitignore <dir>/_snapshots
# --dry-run: show what would be committed per dir, change nothing (no repo, no state, no lock).
set -euo pipefail
LIB="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck disable=SC1091
. "${NEUROOTDEL_GUARD_CONF:-$LIB/guard.conf}"
U="${AGENT_USER:?AGENT_USER missing in guard.conf}"

ST="${NEUROOTDEL_AUTOSYNC_STATE:-/var/lib/${U}-autosync}"
LOG="${NEUROOTDEL_AUTOSYNC_LOG:-/var/log/${U}-autosync.log}"
PUT="$LIB/outbox-put.py"
H="${AGENT_HOME:?}/.claude-lab"
read -r -a AGENTS <<< "${CHANNEL_AGENTS:-jarvis} richard"
MAX_BYTES=$((2 * 1024 * 1024))
DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1

# Key / credential patterns (ERE). A false positive only costs versioning of that file.
# Names only are ever printed.
Q="[\"'[:space:]]*"
PAT="sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9_-]{32,}|[0-9]{8,10}:AA[A-Za-z0-9_-]{30,}"
PAT+="|[Bb]earer[[:space:]]+[A-Za-z0-9._~+/=-]{20,}|gh[pousr]_[A-Za-z0-9]{30,}|AKIA[0-9A-Z]{16}"
PAT+="|-----BEGIN [A-Z ]*PRIVATE KEY-----|xox[abprs]-[A-Za-z0-9-]{10,}|eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\."
# Sensitive field with ANY value of 8+ chars whose FIRST char is not a placeholder (< $ {):
# quoted values may hold any char but their quote, unquoted ones run to end of line.
# Matched case-insensitively (-i) everywhere.
PAT+="|(api_hash|api[_-]?key|apikey|secret|password|passwd|pwd|token|session_string|cookie|auth)[A-Za-z0-9_-]*${Q}[:=][[:space:]]*"
PAT+="(\"[^<\${\"][^\"]{7,}|'[^<\${'][^']{7,}|[^<\${[:space:]\"'].{7,})"

if (( ! DRY )); then
    mkdir -p "$ST"
    chmod 700 "$ST"
    [[ -e "$ST/STOP" ]] && exit 0
    exec 9>"$ST/lock"
    flock -n 9 || exit 0
fi

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG"; }
g() { local d="$1"; shift; runuser -u "$U" -- git -C "$d" -c core.quotePath=false "$@"; }
as_agent() { runuser -u "$U" -- "$@"; }

GITIGNORE='# agents-git-autosync: whitelist, everything else is ignored.
/*
!/.gitignore
!/CLAUDE.md
!/settings.json
!/core/
!/skills/
!/business/
!/drafts/
!/library/
!/_snapshots/
# never tracked, wherever they are
secrets/
.env
.env.*
*.env
*.key
*.pem
*.p12
*.bak*
transcripts/
core/hot/pre-compact/
*.lock
node_modules/
.mcp.json
*credentials*
*.session
*.sqlite
*.db
__pycache__/'

# Hard path rules of the index (ERE over the path relative to the repo), mirror of GITIGNORE.
KEEP_TOP='^(\.gitignore|CLAUDE\.md|settings\.json|(core|skills|business|drafts|library|_snapshots)/.+)$'
DENY='(^|/)(secrets|transcripts|node_modules|__pycache__)/|(^|/)\.env($|\.)|\.env$|\.(key|pem|p12|session|sqlite|db|lock)$|\.bak|(^|/)\.mcp\.json$|credentials|^core/hot/pre-compact/'

alert_once() {  # $1=key $2=text ; one outbox item per key, ever (until the key file is removed)
    local kf
    kf="$ST/alerted-$(printf '%s' "$1" | sha256sum | cut -c1-16)"
    [[ -e "$kf" ]] && return 0
    if python3 "$PUT" "$1" "$2" >/dev/null; then touch "$kf"; log "alert $1"; else log "ERR alert $1"; fi
}

exclude_paths() {  # $1=dir, rest=paths ; unstage + never re-add. Fails loudly.
    local d="$1"; shift
    g "$d" rm --cached -q --ignore-unmatch -- "$@" || return 1
    printf '/%s\n' "$@" | as_agent tee -a "$d/.git/info/exclude" >/dev/null || return 1
}

scan_index() {  # $1=dir $2=out file ; hit file names into $2; rc 0 ok (hits or none), 1 = scan error
    local rc=0
    g "$1" grep --cached -l -i -E -e "$PAT" >"$2" || rc=$?
    (( rc == 0 || rc == 1 ))
}

abort_dir() {  # $1=agent $2=dir $3=reason ; fail closed: nothing staged survives
    log "$1: ABORT ($3), no commit"
    g "$2" reset -q >/dev/null 2>&1 || true
    alert_once "autosync-abort-$1-$(date -u +%Y%m%d)" "Сервер, git-история $1: прогон прерван ($3), коммита нет, см. $LOG"
    return 1
}

sync_dir() {  # $1=agent
    local a="$1" d="$H/$1/.claude" plugin_settings n f fresh=0 added deleted
    local -a big=() bin=() hits=() left=()
    [[ -d "$d" ]] || { log "$a: no $d"; return 0; }
    if [[ ! -d "$d/.git" ]]; then
        g "$d" init -q -b main || { log "$a: ERR init"; return 1; }
        fresh=1
        log "$a: repo initialised"
    fi
    # Repo readable by the agent user only (handoff.md and others are 0600 in the work tree).
    if [[ "$(g "$d" config --get core.sharedRepository || true)" != "0600" ]]; then
        g "$d" config core.sharedRepository 0600 || { log "$a: ERR repo config"; return 1; }
    fi
    # As the agent: a .git the agent swapped for a symlink never gets root to chmod elsewhere.
    as_agent chmod -R go-rwx -- "$d/.git" || { log "$a: ERR repo permissions"; return 1; }
    if [[ -d "$d/.git/rebase-merge" || -d "$d/.git/rebase-apply" || -f "$d/.git/MERGE_HEAD" ]]; then
        log "$a: WARN repo in rebase/merge state, skip"; return 0
    fi
    # .gitignore is ours: rewrite when it differs.
    if [[ "$(cat "$d/.gitignore" 2>/dev/null || true)" != "$GITIGNORE" ]]; then
        printf '%s\n' "$GITIGNORE" | as_agent tee "$d/.gitignore" >/dev/null || { log "$a: ERR .gitignore"; return 1; }
    fi
    # Snapshot of the live hook settings (they live in the nested dashi plugin repo).
    plugin_settings="$d/dashi-plugin-claude-code/plugin/.claude/settings.json"
    if [[ -f "$plugin_settings" ]]; then
        as_agent mkdir -p "$d/_snapshots" && as_agent cp -p -- "$plugin_settings" "$d/_snapshots/plugin-settings.json" \
            || { log "$a: ERR plugin settings snapshot"; return 1; }
    fi
    g "$d" add -A || { abort_dir "$a" "$d" "git add"; return 1; }
    # Hard list over the WHOLE index, independent of any .gitignore (a nested one may re-include
    # a path, and .gitignore never untracks a file tracked earlier): outside the top-level
    # whitelist or a forbidden name anywhere = out of the index, whatever the content.
    g "$d" ls-files -z -c >"$tf" || { abort_dir "$a" "$d" "list index"; return 1; }
    local -a gone=()
    while IFS= read -r -d '' f; do
        if ! [[ "$f" =~ $KEEP_TOP ]] || [[ "$f" =~ $DENY ]]; then gone+=("$f"); fi
    done <"$tf"
    if (( ${#gone[@]} )); then
        g "$d" rm --cached -q --ignore-unmatch -- "${gone[@]}" || { abort_dir "$a" "$d" "untrack forbidden"; return 1; }
        log "$a: untracked ${#gone[@]} forbidden path(s)"
    fi
    # Big and binary files out of the index (binary content cannot be pattern-checked).
    g "$d" diff --cached --name-only -z --diff-filter=AM >"$tf" || { abort_dir "$a" "$d" "list staged"; return 1; }
    while IFS= read -r -d '' f; do
        [[ -f "$d/$f" ]] || continue
        if (( $(stat -c %s -- "$d/$f") > MAX_BYTES )); then big+=("$f"); fi
    done <"$tf"
    g "$d" diff --cached --numstat -z --diff-filter=AM >"$tf" || { abort_dir "$a" "$d" "numstat"; return 1; }
    while IFS=$'\t' read -r -d '' added deleted f; do
        [[ "$added" == "-" && "$deleted" == "-" ]] && bin+=("$f")
    done <"$tf"
    if (( ${#big[@]} + ${#bin[@]} )); then
        exclude_paths "$d" "${big[@]}" "${bin[@]}" || { abort_dir "$a" "$d" "exclude big/binary"; return 1; }
        log "$a: excluded big/binary: ${big[*]} ${bin[*]}"
    fi
    # Credential gate over the whole index.
    scan_index "$d" "$tf" || { abort_dir "$a" "$d" "secret scan"; return 1; }
    mapfile -t hits <"$tf"
    if (( ${#hits[@]} )); then
        exclude_paths "$d" "${hits[@]}" || { abort_dir "$a" "$d" "exclude secret hits"; return 1; }
        log "$a: credential pattern, excluded: ${hits[*]}"
        if (( ! fresh )); then
            alert_once "autosync-secret-$a-$(printf '%s\n' "${hits[@]}" | sort | sha256sum | cut -c1-12)" \
                "Сервер, git-история $a: в файлах похоже на ключ, они исключены из истории: ${hits[*]}"
        fi
    fi
    # Final re-check of the exact tree to be committed.
    scan_index "$d" "$tf" || { abort_dir "$a" "$d" "final scan"; return 1; }
    mapfile -t left <"$tf"
    (( ${#left[@]} == 0 )) || { abort_dir "$a" "$d" "pattern left after exclude"; return 1; }
    if g "$d" diff --cached --quiet; then
        return 0
    fi
    n=$(g "$d" diff --cached --name-only | wc -l)
    if g "$d" -c user.name=agents-autosync -c user.email=autosync@localhost \
           commit -q --no-verify -m "autosync $(date -u '+%Y-%m-%d %H:%M UTC'): ${n} file(s)"; then
        log "$a: commit ${n} file(s) $(g "$d" rev-parse --short HEAD)"
    else
        abort_dir "$a" "$d" "commit failed"; return 1
    fi
}

# Dry run: list what the whitelist would track, flag big/binary files and pattern hits, touch nothing.
dry_list() {  # $1=agent
    local a="$1" d="$H/$1/.claude" tmpgi tmpgd f sz total=0 cnt=0
    local -a files=()
    [[ -d "$d" ]] || { echo "$a: no $d"; return 0; }
    [[ -d "$d/.git" ]] && echo "$a: repo exists" || echo "$a: [dry] would init repo in $d"
    tmpgi=$(mktemp)
    tmpgd=$(mktemp -d)
    printf '%s\n' "$GITIGNORE" >"$tmpgi"
    git --git-dir="$tmpgd" init -q
    mapfile -d '' files < <(git --git-dir="$tmpgd" --work-tree="$d" ls-files -z --others \
        --exclude-from="$tmpgi" --exclude-standard 2>/dev/null)
    rm -rf -- "${tmpgd:?}" "${tmpgi:?}"
    for f in "${files[@]}"; do
        sz=$(stat -c %s -- "$d/$f" 2>/dev/null || echo 0)
        if (( sz > MAX_BYTES )); then echo "  [dry] $a: big, would exclude: $f ($sz B)"; continue; fi
        if ! grep -qI . -- "$d/$f" 2>/dev/null && (( sz > 0 )); then echo "  [dry] $a: binary, would exclude: $f"; continue; fi
        if grep -qiE -e "$PAT" -- "$d/$f" 2>/dev/null; then echo "  [dry] $a: CREDENTIAL PATTERN, would exclude: $f"; continue; fi
        total=$((total + sz)); cnt=$((cnt + 1))
    done
    echo "  [dry] $a: would track $cnt files, $total bytes"
}

tf=$(mktemp)
trap 'rm -f -- "$tf"' EXIT
for a in "${AGENTS[@]}"; do
    if (( DRY )); then dry_list "$a"; else sync_dir "$a" || log "$a: sync_dir failed (continuing)"; fi
done
exit 0
