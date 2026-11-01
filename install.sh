#!/usr/bin/env bash
# neurootdel-install -- НЕЙРООТДЕЛ AI Agent installer (3-Claude architecture)
#
# Installs on a fresh Ubuntu 22.04 / 24.04 VPS:
#   - neurootdel user (dedicated, non-login-privileged); a server that already
#     has an edgelab install keeps the edgelab user and its paths
#     (see select_install_names)
#   - Node.js 22 + Python 3.12 + Claude Code CLI
#   - Jarvis: izmukovvladimir-cyber/dashi-plugin-claude-code (pinned commit, PLUGIN_COMMIT_DEFAULT) -> systemd unit channel-jarvis
#     (a server that still runs the old claude-gateway is migrated; see --rollback)
#   - Richard: izmukovvladimir-cyber/claude-code-telegram v1.6.0 -> systemd unit claude-richard
#
# Both agents share Anthropic Max OAuth from /home/neurootdel/.claude/
# Operator runs `sudo -u neurootdel -i bash -lc 'claude auth login'` once after install finishes.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/izmukovvladimir-cyber/neurootdel-install/main/install.sh -o /root/neurootdel-install.sh && sudo bash /root/neurootdel-install.sh
#   # or
#   sudo bash /root/neurootdel-install.sh
#   sudo bash /root/neurootdel-install.sh --rollback   # Jarvis back to the old claude-gateway unit
#   sudo bash /root/neurootdel-install.sh --solo # «Агент за вечер»: asks for the personal key first
#                                  # (or NEUROOTDEL_AZV_KEY=...), stops without a valid one
#
# Env overrides (non-interactive). The old EDGELAB_* names are still accepted
# when the NEUROOTDEL_* one is not set:
#   NEUROOTDEL_JARVIS_BOT_TOKEN   Jarvis Telegram bot token
#   NEUROOTDEL_JARVIS_BOT_USER    Jarvis bot @username (no @)
#   NEUROOTDEL_RICHARD_BOT_TOKEN  Richard Telegram bot token
#   NEUROOTDEL_RICHARD_BOT_USER   Richard bot @username (no @)
#   NEUROOTDEL_TG_USER_ID         Operator Telegram numeric ID
#   NEUROOTDEL_SUPERVISOR_TG_ID   Optional second trusted Telegram numeric ID (installer
#                                 supervisor) for the starter secrets rule; empty = none
#   NEUROOTDEL_USER_NAME          Operator display name (for Jarvis CLAUDE.md)
#   NEUROOTDEL_LANGUAGE           Operator language (default: Russian)
#   NEUROOTDEL_TIMEZONE           Operator timezone (default: Europe/Moscow)

set -euo pipefail

# =============================================================================
# CONSTANTS
# =============================================================================

readonly INSTALLER_VERSION="3.1.0"
readonly PLUGIN_REPO="https://github.com/izmukovvladimir-cyber/dashi-plugin-claude-code.git"
# Every install gets the SAME plugin code: one pinned commit of the fork (owner-only
# service commands, d846493). NEUROOTDEL_PLUGIN_COMMIT overrides it (40 hex chars).
readonly PLUGIN_COMMIT_DEFAULT="d846493201d02b92399404c9b2a89a6dbcd89ab5"
readonly JARVIS_UNIT="channel-jarvis"
# Pre-plugin Jarvis (v3.0.x). Kept on disk for --rollback, never deleted.
readonly LEGACY_GATEWAY_UNIT="claude-gateway"
readonly LEGACY_GATEWAY_DIR_NAME="claude-gateway"
readonly RICHARD_REPO_SPEC="git+https://github.com/izmukovvladimir-cyber/claude-code-telegram@v1.6.0"
readonly RICHARD_HOME="/opt/richard"
readonly NODE_MAJOR="22"

# Template bundle (inherited from v2.2.6 -- pinned SHAs for supply chain).
readonly TEMPLATE_REPO="https://github.com/izmukovvladimir-cyber/public-architecture-claude-code.git"
readonly TEMPLATE_SHA="93cc7ddf10c03472616a3a32ff7e6ac731ebe6f2"
readonly SUPERPOWERS_REPO="https://github.com/izmukovvladimir-cyber/superpowers.git"
readonly SUPERPOWERS_SHA="04bad33282e792ecfd1007a138331f1e6b288eed"

# 6 skills from template + 4 bundled with installer = 10 total (prod parity).
readonly SKILLS_FROM_TEMPLATE=(groq-voice markdown-new perplexity-research datawrapper excalidraw youtube-transcript)
readonly SKILLS_FROM_INSTALLER=(onboarding self-compiler quick-reminders present)

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
readonly TEMPLATES_DIR_DEFAULT="${_SCRIPT_DIR}/templates"
readonly INSTALLER_ROOT_DEFAULT="${_SCRIPT_DIR}"
unset _SCRIPT_DIR
readonly CURL_OPTS=(-fsSL --max-time 60 --retry 2 --retry-delay 3)

# =============================================================================
# INSTALL NAMES: neurootdel for new servers, edgelab kept where it already lives
# =============================================================================

# import_legacy_env -- an old EDGELAB_<X> fills NEUROOTDEL_<X> when that is unset,
# so instructions and scripts written for the old installer keep working.
import_legacy_env() {
    local old new
    for old in $(compgen -v EDGELAB_ || true); do
        new="NEUROOTDEL_${old#EDGELAB_}"
        [[ "$old" == EDGELAB_FACT_GATE_* ]] && continue   # new keys: NEUROOTDEL_ only, "" must clear
        if [[ -z "${!new:-}" && -n "${!old:-}" ]]; then
            export "${new}=${!old}"
        fi
    done
}

# env_value <SUFFIX> -- NEUROOTDEL_<SUFFIX>, else EDGELAB_<SUFFIX>, else empty.
env_value() {
    local new="NEUROOTDEL_$1" old="EDGELAB_$1"
    printf '%s' "${!new:-${!old:-}}"
}

# detect_install_names [root] -- prints "new" or "legacy".
# legacy = this server already carries an edgelab install (user, ~/.claude,
# sudoers or /etc/dashi-plugin): live agents read those paths, so a re-run
# keeps them and never creates a second user next to them.
# Order: edgelab install files > neurootdel install files > bare edgelab user.
# A neurootdel install wins only over a leftover edgelab user without files.
# [root] is a filesystem prefix for tests; empty = this server.
detect_install_names() {
    local root="${1:-}"
    if [[ -d "${root}/home/edgelab/.claude" \
          || -f "${root}/etc/sudoers.d/edgelab-agents" \
          || -d "${root}/etc/dashi-plugin" ]]; then
        echo legacy     # a live edgelab install wins over any neurootdel leftover
    elif [[ -d "${root}/home/neurootdel/.claude" || -f "${root}/etc/sudoers.d/neurootdel-agents" ]]; then
        echo new
    elif grep -q '^edgelab:' "${root}/etc/passwd" 2>/dev/null; then
        echo legacy     # bare edgelab user: still never a second user next to it
    else
        echo new
    fi
}

# apply_install_names <new|legacy> -- sets every name that differs between the two.
apply_install_names() {
    case "$1" in
        new)
            AGENT_USER="neurootdel"
            INSTALL_TAG="neurootdel-install"
            CONFIG_ROOT="/etc/vladimir-plugin"
            SUDO_ALIAS="NEUROOTDEL"
            ;;
        legacy)
            AGENT_USER="edgelab"
            INSTALL_TAG="edgelab-install"
            CONFIG_ROOT="/etc/dashi-plugin"
            SUDO_ALIAS="EDGELAB"
            ;;
        *)
            return 1
            ;;
    esac
    INSTALL_NAMES="$1"
    AGENT_HOME="/home/${AGENT_USER}"
    JARVIS_ENV_DIR="${CONFIG_ROOT}/jarvis"
    CHANNEL_CONFIRM_BIN="/usr/local/lib/${AGENT_USER}/channel-confirm.sh"
    CHANNEL_START_BIN="/usr/local/lib/${AGENT_USER}/channel-start.sh"
    # Guard scripts (agents-reset, memory-backup, watchdog, hooks) + guard.conf.
    GUARD_LIB_DIR="/usr/local/lib/${AGENT_USER}"
    # Root-owned apt wrapper: the only apt path in sudoers (plain `apt-get *` = root).
    APT_WRAPPER_BIN="/usr/local/sbin/${AGENT_USER}-apt-install"
    SUDOERS_FILE="/etc/sudoers.d/${AGENT_USER}-agents"
    LEGACY_BACKUP_ROOT="/var/backups/${INSTALL_TAG}"
    INSTALL_STATE_ROOT="/var/lib/${INSTALL_TAG}"
}

# select_install_names [root] -- one place that decides all names, run at load time.
select_install_names() {
    apply_install_names "$(detect_install_names "${1:-}")"
}

import_legacy_env
select_install_names ""   # "" = this server

TEMPLATES_DIR="${NEUROOTDEL_TEMPLATES_DIR:-$TEMPLATES_DIR_DEFAULT}"
INSTALLER_ROOT="${NEUROOTDEL_INSTALLER_ROOT:-$INSTALLER_ROOT_DEFAULT}"
TEMPLATE_CLONE_DIR=""
INSTALLER_SKILLS_DIR=""

# «Агент за вечер» (--solo): the closed part of the agent is unlocked by a personal key
# bound to this server. Without --solo none of this runs.
readonly AZV_SALT="agent-za-vecher-v1"
AZV_ACTIVATE_URL="${NEUROOTDEL_AZV_URL:-https://hooks.vladimir-izhmukov.ru/agent/activate}"
AZV_MACHINE_ID_FILE="${NEUROOTDEL_AZV_MACHINE_ID_FILE:-/etc/machine-id}"
AZV_STAGE_DIR="${NEUROOTDEL_AZV_STAGE_DIR:-${INSTALL_STATE_ROOT}/azv}"
AZV_AGENT_DIR="${NEUROOTDEL_AZV_AGENT_DIR:-${AGENT_HOME}/.claude-lab/jarvis/.claude/azv}"
SOLO=0

# =============================================================================
# TERMINAL OUTPUT
# =============================================================================

if [[ -t 1 ]]; then
    C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'
    C_BLUE='\033[0;34m'; C_BOLD='\033[1m'; C_NC='\033[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''; C_NC=''
fi

log()  { printf '%b[%s]%b %s\n' "$C_BLUE" "$(date +%H:%M:%S)" "$C_NC" "$*"; }
ok()   { printf '%b✓%b %s\n' "$C_GREEN" "$C_NC" "$*"; }
warn() { printf '%b!%b %s\n' "$C_YELLOW" "$C_NC" "$*" >&2; }
err()  { printf '%b✗%b %s\n' "$C_RED" "$C_NC" "$*" >&2; }
die()  { err "$*"; exit 1; }

step() {
    local n="$1"; shift
    printf '\n%b== Step %s: %s ==%b\n' "$C_BOLD" "$n" "$*" "$C_NC"
}

banner() {
    printf '
%b' "$C_YELLOW"
    cat <<EOF
  ==============================================================
     НЕЙРООТДЕЛ AI Agent
     neurootdel-install v${INSTALLER_VERSION} -- 3-Claude edition
  ==============================================================
EOF
    printf '%b\n' "$C_NC"
}

# =============================================================================
# HELPERS
# =============================================================================

apt_get() {
    local tries=0
    local max_tries=20
    while fuser /var/lib/dpkg/lock-frontend &>/dev/null || fuser /var/lib/apt/lists/lock &>/dev/null; do
        ((tries++))
        if (( tries > max_tries )); then
            die "Another apt/dpkg process holds the lock for too long. Aborting."
        fi
        sleep 3
    done
    DEBIAN_FRONTEND=noninteractive apt-get "$@"
}

# Tmp tracking -- mirrors v2.2.6 cleanup trap.
TMPFILES=()
TMPDIRS=()
_cleanup() {
    local f d
    for f in "${TMPFILES[@]:-}"; do
        [[ -n "$f" && -f "$f" ]] && rm -f "$f" || true
    done
    for d in "${TMPDIRS[@]:-}"; do
        [[ -n "$d" && -d "$d" ]] && rm -rf "$d" || true
    done
}
trap _cleanup EXIT

is_noninteractive() {
    [[ "$(env_value NONINTERACTIVE)" == "1" ]] || [[ ! -t 0 ]]
}

# prompt_or_env VAR ENV_NAME "prompt" [default] [--secret]
# shellcheck disable=SC2034  # out_ref is a nameref, writes propagate to caller
prompt_or_env() {
    local -n out_ref=$1
    local env_name=$2
    local prompt=$3
    local default=${4:-}
    local secret=${5:-}
    local env_val="${!env_name:-}"
    # Old name still accepted: NEUROOTDEL_X falls back to EDGELAB_X.
    if [[ -z "$env_val" && "$env_name" == NEUROOTDEL_* ]]; then
        env_val="$(env_value "${env_name#NEUROOTDEL_}")"
    fi

    if [[ -n "$env_val" ]]; then
        out_ref="$env_val"
        return 0
    fi

    if is_noninteractive; then
        # No tty (root-Claude runs the installer that way): behave like Enter.
        # An empty token keeps the value already written on this server.
        if [[ -z "$default" ]]; then
            warn "Non-interactive: ${env_name} not set -- left empty (an existing value on this server is kept)."
        fi
        out_ref="$default"
        return 0
    fi

    local answer=""
    if [[ -n "$default" ]]; then
        prompt="${prompt} [${default}]"
    fi
    prompt="${prompt}: "

    if [[ "$secret" == "--secret" ]]; then
        read -r -s -p "$prompt" answer </dev/tty
        echo ""
    else
        read -r -p "$prompt" answer </dev/tty
    fi

    if [[ -z "$answer" && -n "$default" ]]; then
        answer="$default"
    fi
    out_ref="$answer"
}

# Simple {{KEY}} -> VALUE substitution from template file into dst.
# Usage: render_template src dst KEY1 VAL1 [KEY2 VAL2 ...]
render_template() {
    local src=$1 dst=$2; shift 2
    [[ -f "$src" ]] || die "Template not found: $src"

    local tmp
    tmp=$(mktemp)
    cp "$src" "$tmp"

    while (($# >= 2)); do
        local key="$1" val="$2"; shift 2
        # Use python for safe literal replace (no regex surprises in values).
        python3 - "$tmp" "{{${key}}}" "$val" <<'PY'
import sys, pathlib
path, needle, repl = sys.argv[1], sys.argv[2], sys.argv[3]
p = pathlib.Path(path)
p.write_text(p.read_text().replace(needle, repl))
PY
    done

    mv "$tmp" "$dst"
}

as_agent() {
    sudo -u "$AGENT_USER" -H -- env -C "$AGENT_HOME" "$@"
}

# Install a file at dst owned by a specific user, 0600 by default.
install_as_user() {
    local src=$1 dst=$2 owner=$3 mode=${4:-0600}
    install -m "$mode" -o "$owner" -g "$owner" "$src" "$dst"
}

# write_as_user: copy SRC to DST owned by AGENT_USER. Works even when SRC is
# a root-owned 0600 mktemp file that the agent user cannot read.
write_as_user() {
    local src="$1" dst="$2" mode="${3:-0644}"
    local dst_dir
    dst_dir=$(dirname "$dst")
    if [[ ! -d "$dst_dir" ]]; then
        install -d -m 0755 -o "$AGENT_USER" -g "$AGENT_USER" "$dst_dir"
    fi
    install -o "$AGENT_USER" -g "$AGENT_USER" -m "$mode" "$src" "$dst"
}

# fix_owner: recursively chown to the agent user (-h affects symlinks).
fix_owner() {
    local path="$1"
    [[ -e "$path" ]] || return 0
    chown -RhP "${AGENT_USER}:${AGENT_USER}" "$path"
}

# ---------------------------------------------------------------------------
# «Агент за вечер» activation (--solo only)
# ---------------------------------------------------------------------------

# azv_machine_hash -- sha256(machine-id + product salt): what the key gets bound to.
azv_machine_hash() {
    [[ -r "$AZV_MACHINE_ID_FILE" ]] || return 1
    local mid
    mid=$(tr -d '[:space:]' < "$AZV_MACHINE_ID_FILE")
    [[ -n "$mid" ]] || return 1
    printf '%s%s' "$mid" "$AZV_SALT" | sha256sum | cut -d' ' -f1
}

# azv_archive_safe <tar.gz> -- only regular files and dirs, relative paths, no "..".
azv_archive_safe() {
    local listing names
    listing=$(tar -tvzf "$1" 2>/dev/null) || return 1
    names=$(tar -tzf "$1" 2>/dev/null) || return 1
    [[ -n "$names" ]] || return 1
    if grep -qv '^[-d]' <<<"$listing"; then
        return 1
    fi
    if grep -qE '(^/|(^|/)\.\.(/|$))' <<<"$names"; then
        return 1
    fi
}

# azv_activate -- step 0b of --solo: no valid key for this server, no install.
azv_activate() {
    step 0b "Активация личного ключа «Агент за вечер»"
    local key="" mhash body code archive msg
    prompt_or_env key NEUROOTDEL_AZV_KEY "Личный ключ (AZV-XXXX-XXXX-XXXX-XXXX)" "" --secret
    key="${key//[[:space:]]/}"
    if [[ -z "$key" ]]; then
        die "Без личного ключа установка не продолжается. Ключ пришёл в чат после оплаты. Запусти так: sudo NEUROOTDEL_AZV_KEY=<ключ> bash /root/neurootdel-install.sh --solo"
    fi
    if [[ ! "$key" =~ ^[A-Za-z0-9-]{16,40}$ ]]; then
        die "Ключ выглядит неверно, ожидается вид AZV-XXXX-XXXX-XXXX-XXXX. Скопируй его из чата целиком."
    fi
    mhash=$(azv_machine_hash) \
        || die "Не удалось прочитать ${AZV_MACHINE_ID_FILE}, без него ключ к серверу не привязать. Напиши куратору."
    archive=$(mktemp)
    TMPFILES+=("$archive")
    body=$(printf '{"key":"%s","machine_hash":"%s"}' "$key" "$mhash")
    # No --retry: a POST may already have bound the key, and 429 retries burn the limit.
    code=$(curl -sS --max-time 60 -o "$archive" -w '%{http_code}' \
        -H 'Content-Type: application/json' --data-binary "$body" \
        "$AZV_ACTIVATE_URL" 2>/dev/null) || code="000"
    case "$code" in
        200) ;;
        000)
            die "Сервер активации не отвечает. Проверь интернет на сервере и запусти установщик снова."
            ;;
        *)
            msg=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("message", ""))' \
                "$archive" 2>/dev/null || true)
            die "Активация не прошла (код ${code}). ${msg:-Напиши куратору.}"
            ;;
    esac
    azv_archive_safe "$archive" \
        || die "Архив от сервера активации повреждён. Запусти установщик снова или напиши куратору."
    rm -rf "${AZV_STAGE_DIR:?}"
    install -d -m 0700 "$AZV_STAGE_DIR"
    tar -xzf "$archive" -C "$AZV_STAGE_DIR" --no-same-owner --no-same-permissions \
        || die "Не удалось распаковать материалы. Запусти установщик снова."
    ok "Ключ принят, личные материалы агента получены"
}

# azv_install_payload -- the unlocked part goes into the agent workspace (after install_jarvis).
azv_install_payload() {
    step 9b "Раскладываю личные материалы агента"
    [[ -d "$AZV_STAGE_DIR" ]] || die "Нет материалов активации (${AZV_STAGE_DIR}). Запусти установщик с --solo снова."
    # Written as the agent user, never as root: the target is in the agent's own
    # workspace, and a symlink planted there must not turn this into a root write.
    as_agent mkdir -p -m 0755 "$AZV_AGENT_DIR" \
        || die "Не удалось создать ${AZV_AGENT_DIR}. Напиши куратору."
    tar -C "$AZV_STAGE_DIR" -cf - . | as_agent tar -xf - -C "$AZV_AGENT_DIR" --no-same-owner \
        || die "Не удалось разложить материалы в ${AZV_AGENT_DIR}. Напиши куратору."
    ok "Материалы лежат в ${AZV_AGENT_DIR}"
    azv_wire_payload
}

# azv_wire_payload -- makes the session actually use the payload: each
# azv/skills/<name>/ is symlinked into the workspace skills dir (the one the
# plugin's .claude/skills points at), and azv/soul/*.md are @-included from the
# workspace CLAUDE.md inside a marker block that is rewritten on every run.
azv_wire_payload() {
    local ws skills_dir claude_md rel src name link cur
    ws=$(dirname "$AZV_AGENT_DIR")
    skills_dir="${ws}/skills"
    claude_md="${ws}/CLAUDE.md"
    rel=$(basename "$AZV_AGENT_DIR")

    as_agent mkdir -p "$skills_dir" || die "Не удалось создать ${skills_dir}. Напиши куратору."
    for src in "${AZV_AGENT_DIR}"/skills/*/; do
        [[ -f "${src}SKILL.md" ]] || continue
        src=${src%/}
        name=$(basename "$src")
        [[ "$name" == _* ]] && continue
        link="${skills_dir}/${name}"
        if [[ -L "$link" ]]; then
            cur=$(readlink "$link")
            if [[ "$cur" != "${AZV_AGENT_DIR}/skills/"* ]]; then
                warn "Навык ${name}: ${link} уже ссылается на ${cur}, оставляю как есть."
                continue
            fi
        elif [[ -e "$link" ]]; then
            warn "Навык ${name}: в ${skills_dir} уже есть свой ${name}, оставляю как есть."
            continue
        fi
        as_agent ln -sfnT "$src" "$link" || die "Не удалось подключить навык ${name}. Напиши куратору."
    done

    local block f
    block="<!-- azv:begin (written by neurootdel-install --solo, rewritten on re-run) -->"$'\n'
    if [[ -f "${AZV_AGENT_DIR}/soul/CLAUDE.md" ]]; then
        block+="@${rel}/soul/CLAUDE.md"$'\n'
    fi
    for f in "${AZV_AGENT_DIR}"/soul/*.md; do
        [[ -f "$f" ]] || continue
        name=$(basename "$f")
        [[ "$name" == CLAUDE.md || "$name" == _* ]] && continue
        # Already pulled in by soul/CLAUDE.md itself -- do not load it twice.
        if [[ -f "${AZV_AGENT_DIR}/soul/CLAUDE.md" ]] \
                && grep -qE "^@(\./)?${name//./\\.}[[:space:]]*$" "${AZV_AGENT_DIR}/soul/CLAUDE.md"; then
            continue
        fi
        block+="@${rel}/soul/${name}"$'\n'
    done
    block+="<!-- azv:end -->"

    # Read and write as the agent user: CLAUDE.md lives in the agent's workspace.
    local current=""
    if as_agent test -f "$claude_md"; then
        current=$(as_agent cat "$claude_md") || die "Не удалось прочитать ${claude_md}. Напиши куратору."
    fi
    AZV_BLOCK="$block" python3 -c '
import os, re, sys
text, block = sys.stdin.read(), os.environ["AZV_BLOCK"]
text = re.sub(r"\n*<!-- azv:begin[^\n]*-->.*?<!-- azv:end -->\n?", "\n", text, flags=re.S).rstrip("\n")
sys.stdout.write((text + "\n\n" if text else "") + block + "\n")
' <<<"$current" | as_agent sh -c 'cat > "$1.azv-tmp" && mv -f "$1.azv-tmp" "$1"' _ "$claude_md" \
        || die "Не удалось записать ${claude_md}. Напиши куратору."
    ok "Личные навыки подключены в ${skills_dir}, душа агента подключена в ${claude_md}"
}

# ---------------------------------------------------------------------------
# Template / skill sourcing
# ---------------------------------------------------------------------------

fetch_template() {
    if [[ -n "$TEMPLATE_CLONE_DIR" && -d "$TEMPLATE_CLONE_DIR" ]]; then
        echo "$TEMPLATE_CLONE_DIR"
        return 0
    fi

    local dir
    dir=$(mktemp -d)
    TMPDIRS+=("$dir")

    log "Cloning pinned template @ ${TEMPLATE_SHA:0:8}..." >&2
    if ! git clone --quiet "$TEMPLATE_REPO" "$dir" >&2; then
        err "Failed to clone template repo from ${TEMPLATE_REPO}"
        return 1
    fi
    if ! git -C "$dir" checkout --quiet "$TEMPLATE_SHA" 2>/dev/null; then
        err "Failed to checkout SHA ${TEMPLATE_SHA}"
        return 1
    fi

    TEMPLATE_CLONE_DIR="$dir"
    echo "$dir"
}

locate_installer_skills() {
    if [[ -n "$INSTALLER_SKILLS_DIR" && -d "$INSTALLER_SKILLS_DIR" ]]; then
        echo "$INSTALLER_SKILLS_DIR"
        return 0
    fi

    if [[ -d "${INSTALLER_ROOT}/skills" ]]; then
        INSTALLER_SKILLS_DIR="${INSTALLER_ROOT}/skills"
        echo "$INSTALLER_SKILLS_DIR"
        return 0
    fi

    # curl | bash path: no local skills/ dir, clone installer repo.
    local dir
    dir=$(mktemp -d)
    TMPDIRS+=("$dir")
    log "Cloning installer bundled skills..." >&2
    if ! git clone --quiet --depth 1 "https://github.com/izmukovvladimir-cyber/neurootdel-install.git" "$dir" >&2; then
        err "Failed to clone installer repo for bundled skills."
        return 1
    fi
    if [[ ! -d "${dir}/skills" ]]; then
        err "Installer repo has no skills/ subtree."
        return 1
    fi
    INSTALLER_SKILLS_DIR="${dir}/skills"
    echo "$INSTALLER_SKILLS_DIR"
}

# install_skill_bundle SRC DST_PARENT NAME -- atomic same-fs rsync+mv.
install_skill_bundle() {
    local src="$1" dst_parent="$2" skill_name="$3"

    if [[ ! -d "$src" ]]; then
        err "install_skill_bundle: source '${src}' not found."
        return 1
    fi

    local dst="${dst_parent}/${skill_name}"
    mkdir -p "$dst_parent"

    local stage="${dst_parent}/.${skill_name}.staging.$$"
    rm -rf "$stage" 2>/dev/null || true
    mkdir -p "$stage"
    TMPDIRS+=("$stage")

    if ! rsync -a --delete "${src}/" "${stage}/${skill_name}/"; then
        rm -rf "$stage"
        err "install_skill_bundle: rsync failed for '${skill_name}'."
        return 1
    fi

    if [[ -d "$dst" ]]; then
        rm -rf "${dst}.prev" 2>/dev/null || true
        mv "$dst" "${dst}.prev"
    fi

    if ! mv "${stage}/${skill_name}" "$dst"; then
        err "install_skill_bundle: mv of staged '${skill_name}' failed."
        if [[ -d "${dst}.prev" ]]; then
            mv "${dst}.prev" "$dst" || true
            warn "Restored previous version of '${skill_name}'."
        fi
        rm -rf "$stage"
        return 1
    fi

    rm -rf "${dst}.prev" 2>/dev/null || true
    rm -rf "$stage" 2>/dev/null || true

    # Always fix ownership on the installed skill -- this guards against
    # partial-failure paths where the outer fix_owner is skipped.
    fix_owner "$dst"
    return 0
}

validate_tg_token() {
    local token=$1
    # Format: <digits>:<alphanum-dash-underscore>, at least 8:30 chars.
    [[ "$token" =~ ^[0-9]{6,}:[A-Za-z0-9_-]{30,}$ ]]
}

tg_get_me() {
    local token=$1
    curl "${CURL_OPTS[@]}" "https://api.telegram.org/bot${token}/getMe" 2>/dev/null || true
}

# =============================================================================
# PREFLIGHT
# =============================================================================

preflight() {
    step 0 "Preflight checks"

    if [[ $EUID -ne 0 ]]; then
        die "Run as root: sudo $0"
    fi

    if [[ ! -r /etc/os-release ]]; then
        die "Cannot read /etc/os-release -- unsupported OS."
    fi
    # shellcheck disable=SC1091
    . /etc/os-release

    if [[ "${ID:-}" != "ubuntu" ]]; then
        die "Unsupported OS: ID=${ID:-unknown}. Ubuntu 22.04 or 24.04 required."
    fi

    case "${VERSION_ID:-}" in
        22.04|24.04)
            ok "Ubuntu ${VERSION_ID} detected."
            ;;
        *)
            if [[ "${NEUROOTDEL_ALLOW_UNTESTED_UBUNTU:-0}" == "1" ]]; then
                warn "Ubuntu ${VERSION_ID:-?} is untested. Continuing (NEUROOTDEL_ALLOW_UNTESTED_UBUNTU=1)."
            else
                die "Ubuntu ${VERSION_ID:-?} is untested. Require 22.04 or 24.04, or set NEUROOTDEL_ALLOW_UNTESTED_UBUNTU=1."
            fi
            ;;
    esac

    if ! command -v curl &>/dev/null; then
        log "Bootstrapping curl..."
        apt_get update -qq
        apt_get install -y -qq curl
    fi

    if ! curl "${CURL_OPTS[@]}" -o /dev/null https://api.github.com/ 2>/dev/null; then
        warn "Network check to api.github.com failed. Installer may fail later."
    fi

    # When run via `curl | bash`, the script lives in /tmp and has no sibling
    # templates/ or skills/ dirs. Clone the installer repo into a tmp dir and
    # re-point TEMPLATES_DIR / INSTALLER_ROOT to that clone.
    if [[ ! -d "$TEMPLATES_DIR" ]]; then
        if ! command -v git &>/dev/null; then
            apt_get update -qq
            apt_get install -y -qq git
        fi
        local clone_dir
        clone_dir=$(mktemp -d)
        TMPDIRS+=("$clone_dir")
        log "Templates not found at ${TEMPLATES_DIR}; cloning installer repo..."
        if ! git clone --quiet --depth 1 --branch "${NEUROOTDEL_INSTALL_REF:-main}" \
                https://github.com/izmukovvladimir-cyber/neurootdel-install.git "$clone_dir"; then
            warn "Clone of branch ${NEUROOTDEL_INSTALL_REF:-main} failed; falling back to default branch."
            rm -rf "$clone_dir"
            clone_dir=$(mktemp -d)
            TMPDIRS+=("$clone_dir")
            git clone --quiet --depth 1 \
                https://github.com/izmukovvladimir-cyber/neurootdel-install.git "$clone_dir" \
                || die "Failed to clone installer repo for templates/skills."
        fi
        TEMPLATES_DIR="${clone_dir}/templates"
        INSTALLER_ROOT="$clone_dir"
        [[ -d "$TEMPLATES_DIR" ]] || die "Cloned repo has no templates/ dir."
    fi

    ok "Preflight passed."
}

# =============================================================================
# STEP 1: APT DEPENDENCIES
# =============================================================================

# _apt_touches_installed PKG... -- dry run; prints the already installed
# packages the install would upgrade or remove. Returns 1 when apt cannot
# resolve the install at all.
_apt_touches_installed() {
    local sim
    if ! sim=$(apt_get install -s -y --no-upgrade "$@" 2>/dev/null); then
        return 1
    fi
    # Removals are tagged so the upgrade allowlist below can never excuse them.
    awk '/^Inst [^ ]+ \[/ {print $2} /^Remv / {print "remove:" $2}' <<<"$sim" | sort -u | tr '\n' ' '
}

# Installed packages that may be upgraded along the way: pure python
# libraries, no services behind them (python3-venv pulls them on 24.04).
readonly APT_UPGRADE_OK=(python3-setuptools python3-pkg-resources python3-setuptools-whl python3-pip-whl python3-wheel)

# _apt_blocking "<touched list>" -- the part of the list NOT in APT_UPGRADE_OK.
_apt_blocking() {
    local pkg ok out=()
    for pkg in $1; do
        for ok in "${APT_UPGRADE_OK[@]}"; do
            if [[ "${pkg%%:*}" == "$ok" ]]; then
                continue 2
            fi
        done
        out+=("$pkg")
    done
    printf '%s' "${out[*]:-}"
}

# _apt_install_checked PKG... -- dry run, then install when it touches only
# allowlisted packages. Returns 1 (nothing installed) otherwise; the reason
# is in $APT_LAST_BLOCK.
APT_LAST_BLOCK=""
_apt_install_checked() {
    local touched blocking
    if ! touched=$(_apt_touches_installed "$@"); then
        APT_LAST_BLOCK="apt cannot resolve it"
        return 1
    fi
    blocking=$(_apt_blocking "$touched")
    if [[ -n "$blocking" ]]; then
        APT_LAST_BLOCK="$blocking"
        return 1
    fi
    log "apt: installing missing $*"
    # Called in `if` context, where set -e is off: fail loudly by hand.
    apt_get install -y -qq --no-upgrade "$@" || die "apt-get install $* failed."
    if [[ -n "${touched// /}" ]]; then
        log "apt: попутно обновлены: ${touched% }"
    fi
}

# apt_install_missing PKG... -- installs only packages that are not installed
# yet; installed ones are never upgraded (on a lived-in server an upgrade of
# systemd / udev / resolved / sudo restarts them under other people's services).
# --no-upgrade covers only the named packages, so a dry run guards their
# dependencies: a package that would upgrade/remove anything installed is
# skipped with a warning and the command to run by hand.
APT_SKIPPED=()
apt_install_missing() {
    local pkg missing=()
    for pkg in "$@"; do
        if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
            continue
        fi
        missing+=("$pkg")
    done
    if ((${#missing[@]} == 0)); then
        return 0
    fi

    if _apt_install_checked "${missing[@]}"; then
        return 0
    fi
    # Together they touch something installed: one by one, each dry-run
    # right before its own install (a set is only as safe as its own run).
    for pkg in "${missing[@]}"; do
        if ! _apt_install_checked "$pkg"; then
            APT_SKIPPED+=("$pkg")
            warn "apt: ${pkg} NOT installed -- it would upgrade/remove installed packages: ${APT_LAST_BLOCK}. If that is fine: sudo apt-get install ${pkg}"
        fi
    done
}

# Packages later steps cannot do without (checked by dpkg status, whoever
# installed them): downloads, clones, JSON, skills rsync, as_agent, the
# tmux unit, bun's unzip, crontab, Richard's venv + the embedded helpers.
APT_REQUIRED=(ca-certificates curl git jq rsync sudo tmux unzip cron)
APT_REQUIRED_PY=(python3 python3-venv)

# require_step_packages -- stop BEFORE any agent is installed when a required
# package is missing, so a failed run leaves no half-installed server and a
# re-run after the printed apt-get goes straight through.
require_step_packages() {
    local pkg missing=()
    for pkg in "${APT_REQUIRED[@]}" "${APT_REQUIRED_PY[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
            missing+=("$pkg")
        fi
    done
    if ((${#missing[@]} == 0)); then
        return 0
    fi
    err "Stopped before installing the agents: required package(s) missing: ${missing[*]}"
    err "Nothing of Jarvis/Richard is installed yet. Install them (this may upgrade other packages), then run install.sh again:"
    err "    sudo apt-get install ${missing[*]}"
    exit 1
}

install_apt_deps() {
    step 1 "Installing apt dependencies"

    apt_get update -qq
    apt_install_missing \
        ca-certificates gnupg lsb-release software-properties-common \
        sudo \
        curl wget git jq rsync \
        build-essential \
        systemd \
        logrotate \
        cron \
        unzip tmux

    # Python 3.12: native on Ubuntu 24.04. On 22.04 we need deadsnakes PPA
    # because the default python3 is 3.10 and Day 1 promises "Python 3.12+".
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${VERSION_ID:-}" in
        22.04)
            if ! command -v python3.12 >/dev/null 2>&1; then
                log "Adding deadsnakes PPA for Python 3.12 (Ubuntu 22.04)."
                add-apt-repository -y ppa:deadsnakes/ppa >/dev/null
                apt_get update -qq
            fi
            APT_REQUIRED_PY=(python3.12 python3.12-venv)
            apt_install_missing python3.12 python3.12-venv python3.12-dev python3-pip
            # Point /usr/bin/python3 -> python3.12 so `python3 --version` shows 3.12.
            update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.12 100 >/dev/null 2>&1 || true
            update-alternatives --set python3 /usr/bin/python3.12 >/dev/null 2>&1 || true
            ;;
        24.04|*)
            apt_install_missing python3 python3-venv python3-pip python3-dev
            ;;
    esac

    local py_ver
    py_ver=$(python3 --version 2>&1 | awk '{print $2}')
    ok "Base packages installed (python3=${py_ver})."
}

# =============================================================================
# STEP 2: NODE.JS 22
# =============================================================================

install_node() {
    step 2 "Installing Node.js ${NODE_MAJOR}"

    if command -v node &>/dev/null; then
        local current_major
        current_major=$(node -v 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/')
        # v22 or newer is fine and is not ours to touch (may be another
        # tool's node, e.g. a /usr/local/bin symlink).
        if [[ "$current_major" =~ ^[0-9]+$ ]] && ((current_major >= NODE_MAJOR)); then
            ok "Node.js $(node -v) already installed (>= v${NODE_MAJOR}) -- left as is."
            return 0
        fi
        warn "Node.js $(node -v) present but older than v${NODE_MAJOR}; installing v${NODE_MAJOR}."
    fi

    curl "${CURL_OPTS[@]}" "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
    apt_get install -y -qq nodejs
    ok "Node.js $(node -v) installed."
}

# check_node_for_agent -- warn only. No installer step needs node (Claude
# CLI is a native binary, the plugin runs on Bun); a node the agent cannot run
# (symlink into a 0700 /root) is reported, never replaced.
check_node_for_agent() {
    if as_agent node -v >/dev/null 2>&1; then
        return 0
    fi
    local where
    where=$(command -v node 2>/dev/null || echo "not on PATH")
    warn "node does not run as ${AGENT_USER} (${where} -> $(readlink -f "$where" 2>/dev/null || echo '?')). Left as is: the install does not need it; agents that call node will fail until it is fixed."
}

# =============================================================================
# STEP 4: CLAUDE CODE CLI
# =============================================================================

install_claude_cli() {
    step 4 "Installing Claude Code CLI (per-user for ${AGENT_USER})"

    local claude_bin="${AGENT_HOME}/.local/bin/claude"

    if [[ -x "$claude_bin" ]]; then
        ok "Claude CLI already installed at ${claude_bin}."
        # Best-effort update; never block install on update failure.
        as_agent "$claude_bin" update >/dev/null 2>&1 || warn "claude update non-zero; continuing."
        _ensure_path_export
        return 0
    fi

    local installer_tmp
    installer_tmp=$(mktemp)
    TMPFILES+=("$installer_tmp")

    curl "${CURL_OPTS[@]}" https://claude.ai/install.sh -o "$installer_tmp" \
        || die "Failed to download Claude Code installer."
    chmod 644 "$installer_tmp"

    # Run Anthropic's installer as the agent user so binary lands at ~/.local/bin/claude.
    as_agent bash "$installer_tmp"

    if [[ ! -x "$claude_bin" ]]; then
        die "Claude CLI install failed -- ${claude_bin} not found."
    fi

    local ver
    ver=$(as_agent "$claude_bin" --version 2>/dev/null || echo "unknown")
    ok "Claude CLI v${ver} installed at ${claude_bin}."

    _ensure_path_export
}

# Expose ~/.local/bin on the agent user's PATH for non-interactive SSH + systemd.
# .bashrc aborts on non-interactive shells, so prepend before the PS1 guard.
# .profile runs in full for login shells -- append is fine.
_ensure_path_export() {
    local marker="# Added by ${INSTALL_TAG}: expose ~/.local/bin"
    local export_line='export PATH="$HOME/.local/bin:$PATH"'

    local rc_entry rc placement
    for rc_entry in "${AGENT_HOME}/.bashrc:prepend" "${AGENT_HOME}/.profile:append"; do
        rc="${rc_entry%:*}"
        placement="${rc_entry##*:}"

        if [[ ! -f "$rc" ]]; then
            as_agent touch "$rc"
        fi

        if grep -Fq "$marker" "$rc" 2>/dev/null; then
            continue
        fi

        local tmp
        tmp=$(mktemp)
        TMPFILES+=("$tmp")
        if [[ "$placement" == "prepend" ]]; then
            { echo "$marker"; echo "$export_line"; echo ''; cat "$rc"; } >"$tmp"
        else
            { cat "$rc"; echo ''; echo "$marker"; echo "$export_line"; } >"$tmp"
        fi
        install -o "$AGENT_USER" -g "$AGENT_USER" -m 0644 "$tmp" "$rc"
    done
}

# =============================================================================
# STEP 4b: BUN (runtime of the Telegram channel plugin)
# =============================================================================

install_bun() {
    step 4b "Installing Bun (per-user for ${AGENT_USER})"

    local bun_bin="${AGENT_HOME}/.bun/bin/bun"
    if [[ -x "$bun_bin" ]]; then
        ok "Bun $(as_agent "$bun_bin" --version 2>/dev/null || echo '?') already installed."
        return 0
    fi

    # bun.sh/install unpacks a zip; fresh Ubuntu ships without unzip.
    if ! command -v unzip &>/dev/null; then
        apt_get install -y -qq unzip
    fi

    local installer_tmp
    installer_tmp=$(mktemp)
    TMPFILES+=("$installer_tmp")
    curl "${CURL_OPTS[@]}" https://bun.sh/install -o "$installer_tmp" \
        || die "Failed to download Bun installer."
    chmod 644 "$installer_tmp"

    # As the agent user, so the binary lands at ~/.bun/bin/bun (the unit PATH has it).
    as_agent bash "$installer_tmp" >/dev/null

    if [[ ! -x "$bun_bin" ]]; then
        die "Bun install failed -- ${bun_bin} not found."
    fi
    ok "Bun $(as_agent "$bun_bin" --version 2>/dev/null || echo '?') installed at ${bun_bin}."
}

# =============================================================================
# STEP 3: AGENT USER
# =============================================================================

ensure_agent_user() {
    step 3 "Ensuring '${AGENT_USER}' system user"
    if [[ "$INSTALL_NAMES" == "legacy" ]]; then
        log "Existing ${AGENT_USER} install found: keeping user ${AGENT_USER} and its paths (${JARVIS_ENV_DIR})."
    fi

    if id -u "$AGENT_USER" &>/dev/null; then
        ok "User '${AGENT_USER}' already exists."
    else
        useradd --create-home --shell /bin/bash "$AGENT_USER"
        ok "User '${AGENT_USER}' created."
    fi

    # Make sure home is usable.
    if [[ ! -d "$AGENT_HOME" ]]; then
        die "Home dir ${AGENT_HOME} missing after useradd."
    fi
    chown "${AGENT_USER}:${AGENT_USER}" "$AGENT_HOME"
    chmod 0755 "$AGENT_HOME"
}

# =============================================================================
# STEP 5: OPERATOR INPUTS
# =============================================================================

# Globals set by collect_inputs
JARVIS_BOT_TOKEN=""
JARVIS_BOT_USERNAME=""
RICHARD_BOT_TOKEN=""
RICHARD_BOT_USERNAME=""
TG_USER_ID=""
# Optional second trusted id (installer supervisor), NEUROOTDEL_SUPERVISOR_TG_ID; empty = none.
SUPERVISOR_TG_ID=""
OPERATOR_NAME=""
OPERATOR_LANGUAGE=""
OPERATOR_TIMEZONE=""

collect_inputs() {
    step 5 "Collecting operator inputs"

    # Interactive flow (TTY present): installer asks the student for all values.
    # Non-interactive flow (NEUROOTDEL_NONINTERACTIVE=1 or no TTY): env overrides
    # required for tokens; operator profile falls back to safe defaults.
    if ! is_noninteractive; then
        cat <<'BRIEF'

The installer will now ask a few questions. You need TWO Telegram bots ready
(create them in @BotFather beforehand) and your numeric Telegram user ID
(get it from @userinfobot). Tokens are hidden while typing.

BRIEF
    fi

    prompt_or_env OPERATOR_NAME     NEUROOTDEL_USER_NAME  "Как к вам обращаться?"                "friend"
    prompt_or_env OPERATOR_LANGUAGE NEUROOTDEL_LANGUAGE   "Язык общения (English / Russian / ...)" "Russian"
    prompt_or_env OPERATOR_TIMEZONE NEUROOTDEL_TIMEZONE   "Таймзона (IANA: Europe/Moscow, Asia/Bangkok, ...)" "Europe/Moscow"

    prompt_or_env JARVIS_BOT_TOKEN  NEUROOTDEL_JARVIS_BOT_TOKEN \
        "Jarvis bot token (from @BotFather, формат 1234567890:ABC...)" \
        "" --secret
    prompt_or_env RICHARD_BOT_TOKEN NEUROOTDEL_RICHARD_BOT_TOKEN \
        "Richard bot token (ДРУГОЙ бот, не совпадает с Jarvis)" \
        "" --secret
    prompt_or_env TG_USER_ID        NEUROOTDEL_TG_USER_ID \
        "Ваш Telegram numeric user ID (from @userinfobot)" \
        ""

    SUPERVISOR_TG_ID="$(env_value SUPERVISOR_TG_ID)"
    JARVIS_BOT_USERNAME="${NEUROOTDEL_JARVIS_BOT_USER:-}"
    RICHARD_BOT_USERNAME="${NEUROOTDEL_RICHARD_BOT_USER:-}"

    # Validate Jarvis token.
    if [[ -n "$JARVIS_BOT_TOKEN" ]]; then
        if ! validate_tg_token "$JARVIS_BOT_TOKEN"; then
            die "Jarvis token format invalid (expected '<digits>:<30+ chars>')."
        fi
        local jresp
        jresp=$(tg_get_me "$JARVIS_BOT_TOKEN")
        if [[ "$(echo "$jresp" | jq -r '.ok // false' 2>/dev/null)" == "true" ]]; then
            [[ -z "$JARVIS_BOT_USERNAME" ]] && \
                JARVIS_BOT_USERNAME=$(echo "$jresp" | jq -r '.result.username // ""')
            ok "Jarvis bot verified: @${JARVIS_BOT_USERNAME:-?}"
        else
            warn "Telegram getMe for Jarvis failed -- token will be written as-is."
        fi
    else
        log "Jarvis token empty (interactive skip / non-interactive no-env)."
    fi

    # Validate Richard token.
    if [[ -n "$RICHARD_BOT_TOKEN" ]]; then
        if ! validate_tg_token "$RICHARD_BOT_TOKEN"; then
            die "Richard token format invalid."
        fi
        if [[ "$RICHARD_BOT_TOKEN" == "$JARVIS_BOT_TOKEN" && -n "$JARVIS_BOT_TOKEN" ]]; then
            die "Richard token must differ from Jarvis token -- create a SEPARATE bot in @BotFather."
        fi
        local rresp
        rresp=$(tg_get_me "$RICHARD_BOT_TOKEN")
        if [[ "$(echo "$rresp" | jq -r '.ok // false' 2>/dev/null)" == "true" ]]; then
            [[ -z "$RICHARD_BOT_USERNAME" ]] && \
                RICHARD_BOT_USERNAME=$(echo "$rresp" | jq -r '.result.username // ""')
            ok "Richard bot verified: @${RICHARD_BOT_USERNAME:-?}"
        else
            warn "Telegram getMe for Richard failed -- token will be written as-is."
        fi
    else
        log "Richard token empty."
    fi

    if [[ -n "$TG_USER_ID" && ! "$TG_USER_ID" =~ ^[0-9]+$ ]]; then
        die "Telegram user ID must be a positive integer (got: ${TG_USER_ID})."
    fi
    if [[ -n "$SUPERVISOR_TG_ID" && ! "$SUPERVISOR_TG_ID" =~ ^[0-9]+$ ]]; then
        die "NEUROOTDEL_SUPERVISOR_TG_ID must be a positive integer (got: ${SUPERVISOR_TG_ID})."
    fi

    ok "Inputs collected: name=${OPERATOR_NAME}, tz=${OPERATOR_TIMEZONE}, lang=${OPERATOR_LANGUAGE}"
}

# =============================================================================
# STEP 6: INSTALL JARVIS
# =============================================================================

# Plugin config.json defaults (TELEGRAM_STATE_DIR/config.json), one entry per
# "section key json-value". A key is added only when it is missing: an owner
# value is never changed, a section that is not an object is left alone.
# webhook on: the agents guard nudges through it and the fallback-reply Stop hook posts to it
# (127.0.0.1 only, bearer TELEGRAM_WEBHOOK_TOKEN from channel.env).
readonly CHANNEL_CONFIG_DEFAULTS=(
    "hud enabled false"
    "webhook enabled true"
)

# _channel_config_merge <cfg> -- prints the merged JSON. rc 0 = changed,
# 1 = nothing to add, 3 = the file is not exactly one JSON object.
_channel_config_merge() {
    python3 - "$1" "${CHANNEL_CONFIG_DEFAULTS[@]}" <<'PY'
import json
import sys
from pathlib import Path

path, defaults = Path(sys.argv[1]), sys.argv[2:]
data = {}
if path.exists():
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (ValueError, UnicodeDecodeError):
        sys.exit(3)
    if not isinstance(data, dict):
        sys.exit(3)
changed = not path.exists()
for spec in defaults:
    section, key, raw = spec.split(" ", 2)
    value = json.loads(raw)
    if section not in data:
        data[section] = {key: value}
        changed = True
        continue
    sec = data[section]
    if isinstance(sec, dict):
        if key not in sec:
            sec[key] = value
            changed = True
    else:
        print(f"{section} is not an object, {section}.{key} left unset", file=sys.stderr)
print(json.dumps(data, ensure_ascii=False, indent=2))
sys.exit(0 if changed else 1)
PY
}

# ensure_channel_config_defaults <cfg> -- writes the defaults into the plugin config.
ensure_channel_config_defaults() {
    local cfg="$1" tmp rc=0 mode=0600
    tmp=$(mktemp)
    TMPFILES+=("$tmp")
    _channel_config_merge "$cfg" > "$tmp" || rc=$?
    case "$rc" in
        0)
            [[ -e "$cfg" ]] && mode=$(stat -c %a "$cfg")
            write_as_user "$tmp" "$cfg" "$mode"
            ;;
        1) ;;
        *) warn "Cannot parse ${cfg}; plugin defaults (${CHANNEL_CONFIG_DEFAULTS[*]}) not applied." ;;
    esac
}

# plugin_commit -- the pinned plugin commit (NEUROOTDEL_PLUGIN_COMMIT or the default).
plugin_commit() {
    local c
    c="$(env_value PLUGIN_COMMIT)"
    c="${c:-$PLUGIN_COMMIT_DEFAULT}"
    [[ "$c" =~ ^[0-9a-f]{40}$ ]] || die "NEUROOTDEL_PLUGIN_COMMIT must be a full 40-char commit id."
    printf '%s' "$c"
}

# checkout_plugin <plugin_root> -- the plugin at exactly the pinned commit (detached HEAD).
# A fresh install clones it; a re-run moves a clean checkout to the pin and keeps a
# checkout with local edits as it is (warning), so an owner's hand change is never lost.
checkout_plugin() {
    local root=$1 pin head
    pin="$(plugin_commit)"
    if [[ ! -d "${root}/.git" ]]; then
        as_agent git init -q "$root" || die "git init failed in ${root}."
        as_agent git -C "$root" remote add origin "$PLUGIN_REPO" || die "git remote add failed in ${root}."
    fi
    head="$(as_agent git -C "$root" rev-parse -q --verify HEAD 2>/dev/null || true)"
    if [[ "$head" == "$pin" ]]; then
        ok "Plugin already at pinned commit ${pin:0:12}."
        return 0
    fi
    if [[ -n "$head" && -n "$(as_agent git -C "$root" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
        warn "Plugin checkout ${root} has local edits -- kept at ${head:0:12}, pinned ${pin:0:12} NOT applied."
        return 0
    fi
    log "Plugin: checking out pinned commit ${pin:0:12}."
    as_agent git -C "$root" fetch -q --depth 1 origin "$pin" \
        || die "Could not fetch plugin commit ${pin} from ${PLUGIN_REPO}."
    as_agent git -C "$root" -c advice.detachedHead=false checkout -q --detach "$pin" \
        || die "Could not check out plugin commit ${pin}."
    [[ "$(as_agent git -C "$root" rev-parse HEAD)" == "$pin" ]] || die "Plugin HEAD is not the pinned commit."
}

install_jarvis() {
    step 6 "Installing Jarvis (Telegram channel plugin, systemd: ${JARVIS_UNIT})"

    local wsroot="${AGENT_HOME}/.claude-lab/jarvis/.claude"
    local plugin_root="${wsroot}/dashi-plugin-claude-code"
    local plugin_dir="${plugin_root}/plugin"
    local state_dir="${AGENT_HOME}/.claude-lab/shared/state/jarvis/telegram"
    local env_file="${JARVIS_ENV_DIR}/channel.env"

    install -d -m 0755 -o "$AGENT_USER" -g "$AGENT_USER" \
        "${AGENT_HOME}/.claude-lab" \
        "${AGENT_HOME}/.claude-lab/jarvis" \
        "$wsroot" \
        "${AGENT_HOME}/.claude-lab/shared" \
        "${AGENT_HOME}/.claude-lab/shared/state"
    install -d -m 0700 -o "$AGENT_USER" -g "$AGENT_USER" \
        "${AGENT_HOME}/.claude-lab/shared/state/jarvis" \
        "$state_dir"

    # Pinned HUD status message off: a restart re-sends it and the user reads
    # it as a duplicate reply. Only a missing key is added; an owner value is kept.
    ensure_channel_config_defaults "${state_dir}/config.json"

    # Full agent workspace (CLAUDE.md + core/USER.md + stub cold memory).
    # Existing files are kept, so a re-run never wipes the agent's memory.
    _write_agent_workspace "$wsroot"

    # The plugin lives inside the workspace: claude runs in plugin/ and picks
    # up the agent CLAUDE.md from the parent dirs.
    checkout_plugin "$plugin_root"
    [[ -f "${plugin_dir}/.mcp.json" ]] || die "Plugin checkout has no plugin/.mcp.json (${plugin_root})."
    as_agent env -C "$plugin_dir" "${AGENT_HOME}/.bun/bin/bun" install \
        || die "bun install failed in ${plugin_dir}."

    # Server that still runs the old gateway: reuse its token / allowlist.
    _collect_jarvis_channel_inputs "$env_file"

    _write_channel_env "$env_file" "$state_dir" "$wsroot"

    # Without it the folder-trust prompt sits on "No, exit", the Enter from
    # channel-confirm closes claude and the unit restarts in a loop. Both the
    # repo root (claude 2.1.x takes the git root as the project) and plugin/.
    if ! _accept_trust_dialog "${AGENT_HOME}/.claude.json" "$plugin_root" "$plugin_dir"; then
        warn "Could not mark ${plugin_root} as trusted in ${AGENT_HOME}/.claude.json -- Jarvis may stop on the trust prompt."
    fi
    # Pre-approve the channel MCP server from plugin/.mcp.json: otherwise the
    # first start shows the approval dialog, the Enter from channel-confirm
    # rejects it and claude writes disabledMcpjsonServers:["dashi-channel"].
    if ! _approve_channel_mcp "${plugin_root}/.claude/settings.local.json" "${plugin_dir}/.claude/settings.local.json"; then
        warn "Could not pre-approve dashi-channel in ${plugin_root}/.claude/settings.local.json -- Jarvis may start without the channel."
    fi

    install -d -m 0755 -o root -g root "$(dirname "$CHANNEL_CONFIRM_BIN")"
    install -m 0755 -o root -g root "${TEMPLATES_DIR}/channel-confirm.sh" "$CHANNEL_CONFIRM_BIN"
    install -m 0755 -o root -g root "${TEMPLATES_DIR}/channel-start.sh" "$CHANNEL_START_BIN"

    local unit_tmp
    unit_tmp=$(mktemp)
    TMPFILES+=("$unit_tmp")
    render_template "${TEMPLATES_DIR}/${JARVIS_UNIT}.service" "$unit_tmp" \
        USER           "$AGENT_USER" \
        HOME           "$AGENT_HOME" \
        PLUGIN_DIR     "$plugin_dir" \
        ENV_FILE       "$env_file" \
        CONFIRM_SCRIPT "$CHANNEL_CONFIRM_BIN" \
        START_SCRIPT   "$CHANNEL_START_BIN"
    install -m 0644 -o root -g root "$unit_tmp" "/etc/systemd/system/${JARVIS_UNIT}.service"

    fix_owner "${AGENT_HOME}/.claude-lab"
    ok "Jarvis installed: plugin ${plugin_dir}, env ${env_file}, unit ${JARVIS_UNIT}"
}

# Jarvis channel inputs, per field: operator answer -> current channel.env
# (render_channel_env keeps its values) -> old gateway config (first migration
# only, so a token rotated in channel.env is never replaced by the stale one).
JARVIS_ALLOWED_IDS=""
JARVIS_GROQ_KEY_FILE=""

# _env_has_value <env_file> <KEY> -- true when KEY=<non-empty> is in the file.
_env_has_value() {
    [[ -f "$1" ]] && grep -qE "^[[:space:]]*${2}=[^[:space:]]" "$1"
}

_collect_jarvis_channel_inputs() {
    local env_file=${1:-}
    local legacy_dir="${AGENT_HOME}/${LEGACY_GATEWAY_DIR_NAME}"
    local legacy_cfg="${legacy_dir}/config.json"
    local shared_groq="${AGENT_HOME}/.claude-lab/shared/secrets/groq-api-key"
    local legacy_groq="${legacy_dir}/secrets/groq-api-key"

    JARVIS_ALLOWED_IDS="$TG_USER_ID"
    JARVIS_GROQ_KEY_FILE=""
    if _env_has_value "$env_file" GROQ_API_KEY; then
        :   # key already in channel.env (maybe rotated there) -- keep it
    elif [[ -s "$shared_groq" ]]; then
        JARVIS_GROQ_KEY_FILE="$shared_groq"
    elif [[ -s "$legacy_groq" ]]; then
        JARVIS_GROQ_KEY_FILE="$legacy_groq"
    fi

    if [[ ! -f "$legacy_cfg" ]]; then
        return 0
    fi
    if [[ -z "$JARVIS_BOT_TOKEN" ]] && ! _env_has_value "$env_file" TELEGRAM_BOT_TOKEN; then
        local legacy_token
        legacy_token=$(jq -r '.agents.jarvis.bot_token // ""' "$legacy_cfg" 2>/dev/null || true)
        if [[ -z "$legacy_token" && -s "${legacy_dir}/secrets/bot-token" ]]; then
            legacy_token=$(tr -d '[:space:]' < "${legacy_dir}/secrets/bot-token")
        fi
        if [[ -n "$legacy_token" ]]; then
            if validate_tg_token "$legacy_token"; then
                JARVIS_BOT_TOKEN="$legacy_token"
                log "Jarvis bot token taken from the old gateway (${legacy_dir})."
            else
                warn "Old gateway token has an unexpected format -- not reused."
            fi
        fi
    fi
    if [[ -z "$JARVIS_ALLOWED_IDS" ]] && ! _env_has_value "$env_file" TELEGRAM_ALLOWED_USER_IDS; then
        JARVIS_ALLOWED_IDS=$(jq -r '[(.allowed_user_ids // .allowlist_user_ids // [])[] | tostring] | join(",")' \
            "$legacy_cfg" 2>/dev/null || true)
    fi
    return 0
}

# _write_channel_env <env_file> <state_dir> <workspace_root>
# root:<agent user> 0640 -- systemd reads it for the unit, the agent may read it.
_write_channel_env() {
    local env_file=$1 state_dir=$2 ws_root=$3
    local tmp
    tmp=$(mktemp)
    TMPFILES+=("$tmp")

    CHANNEL_ENV_TOKEN="$JARVIS_BOT_TOKEN" CHANNEL_ENV_CMD_TRUSTED="$(env_value COMMAND_TRUSTED_IDS)" render_channel_env \
        "$env_file" "$JARVIS_ALLOWED_IDS" "$JARVIS_GROQ_KEY_FILE" "$state_dir" "$ws_root" >"$tmp" \
        || die "Could not build ${env_file}."

    install -d -m 0755 -o root -g root "$(dirname "$JARVIS_ENV_DIR")"
    install -d -m 0750 -o root -g "$AGENT_USER" "$JARVIS_ENV_DIR"
    install -m 0640 -o root -g "$AGENT_USER" "$tmp" "$env_file"
}

# render_channel_env <existing_env|""> <user_ids_csv> <groq_key_file|""> <state_dir> <workspace_root>
# Prints the channel.env to stdout; the bot token comes in $CHANNEL_ENV_TOKEN
# (never argv). A value the operator left empty keeps what the existing file
# already holds, so a re-run without answers does not blank the bot.
render_channel_env() {
    python3 - "$@" <<'PY'
import os
import re
import sys
from pathlib import Path

import secrets

existing_path, user_ids_new, groq_file, state_dir, ws_root = sys.argv[1:6]

existing: dict[str, str] = {}
if existing_path and Path(existing_path).is_file():
    for line in Path(existing_path).read_text().splitlines():
        m = re.match(r"^\s*([A-Z_][A-Z0-9_]*)=(.*)$", line)
        if m:
            existing[m.group(1)] = m.group(2).strip().strip('"').strip("'")


def csv(value: str) -> list[str]:
    return [p.strip() for p in value.split(",") if p.strip()]


token = os.environ.get("CHANNEL_ENV_TOKEN", "").strip() or existing.get("TELEGRAM_BOT_TOKEN", "")
if token and not re.fullmatch(r"[0-9]+:[A-Za-z0-9_-]{30,}", token):
    sys.exit("channel.env: TELEGRAM_BOT_TOKEN has an unexpected format")

user_ids = csv(user_ids_new) or csv(existing.get("TELEGRAM_ALLOWED_USER_IDS", ""))
for uid in user_ids:
    if not re.fullmatch(r"[0-9]+", uid):
        sys.exit(f"channel.env: user id {uid!r} is not a number")

# DM chat id == user id. gate.ts drops every DM whose chat is not listed, so
# the owner's id always goes in; ids added by hand (groups) stay.
chat_ids = csv(existing.get("TELEGRAM_ALLOWED_CHAT_IDS", ""))
chat_ids += [uid for uid in user_ids if uid not in chat_ids]

groq = ""
if groq_file and Path(groq_file).is_file():
    groq = Path(groq_file).read_text().strip()
groq = groq or existing.get("GROQ_API_KEY", "")

managed = {
    "TELEGRAM_BOT_TOKEN": token,
    "TELEGRAM_ALLOWED_USER_IDS": ",".join(user_ids),
    "TELEGRAM_ALLOWED_CHAT_IDS": ",".join(chat_ids),
    "AGENT_ID": existing.get("AGENT_ID") or "jarvis",
    "TELEGRAM_WORKSPACE_ROOT": existing.get("TELEGRAM_WORKSPACE_ROOT") or ws_root,
    "TELEGRAM_STATE_DIR": existing.get("TELEGRAM_STATE_DIR") or state_dir,
    "TELEGRAM_WEBHOOK_HOST": existing.get("TELEGRAM_WEBHOOK_HOST") or "127.0.0.1",
    "TELEGRAM_WEBHOOK_PORT": existing.get("TELEGRAM_WEBHOOK_PORT") or "8089",
    # Bearer of the local webhook (guard nudges, fallback replies); generated once, then kept.
    "TELEGRAM_WEBHOOK_TOKEN": existing.get("TELEGRAM_WEBHOOK_TOKEN") or secrets.token_hex(24),
}
# "Allow this command?" prompts: pinned to the owner (the first id), so team
# members added to TELEGRAM_ALLOWED_USER_IDS later by hand never get them.
# A new owner answer re-pins; otherwise the pinned value is kept.
new_ids = csv(user_ids_new)
perm_ids = new_ids[0] if new_ids else (
    existing.get("TELEGRAM_PERMISSION_ALLOWED_USER_IDS", "") or (user_ids[0] if user_ids else ""))
if perm_ids:
    managed["TELEGRAM_PERMISSION_ALLOWED_USER_IDS"] = perm_ids
# Service commands (/new, /compact, /stop, /status, panel buttons...): only the owner,
# plus the trusted ids given to the installer (NEUROOTDEL_COMMAND_TRUSTED_IDS). Same
# pinning as above: a new owner answer re-pins, otherwise the existing value is kept.
trusted = csv(os.environ.get("CHANNEL_ENV_CMD_TRUSTED", ""))
for uid in trusted:
    if not re.fullmatch(r"[0-9]+", uid):
        sys.exit(f"channel.env: trusted command id {uid!r} is not a number")
old_cmd = csv(existing.get("TELEGRAM_COMMAND_OWNER_IDS", ""))
if new_ids and (not old_cmd or old_cmd[0] != new_ids[0]):
    cmd_ids = [new_ids[0]]  # a new owner: the old trusted list belonged to someone else
else:
    cmd_ids = old_cmd or (user_ids[:1] if user_ids else [])  # same owner: hand-added ids stay
cmd_ids += [t for t in trusted if t not in cmd_ids]
if cmd_ids:
    managed["TELEGRAM_COMMAND_OWNER_IDS"] = ",".join(cmd_ids)
if groq:
    managed["GROQ_API_KEY"] = groq

for key, value in managed.items():
    if re.search(r"[\s\"'\\]", value):
        sys.exit(f"channel.env: {key} contains whitespace or quotes")

out = [
    "# Jarvis Telegram channel. Written by the installer; a re-run keeps your values.",
    "# Fill the three TELEGRAM_* lines (bot token from @BotFather, your numeric id",
    "# from @userinfobot in BOTH id lines), then restart:",
    "#   sudo systemctl enable channel-jarvis && sudo systemctl restart channel-jarvis",
    "# TELEGRAM_ALLOWED_CHAT_IDS must contain your id too: without it every private",
    "# message is dropped silently. Voice needs GROQ_API_KEY=<key> (optional).",
    "# TELEGRAM_EXPECTED_BOT_ID is set at every start from the token (channel-start.sh).",
    "# Permission prompts (\"allow this command?\") go ONLY to the owner:",
    "# TELEGRAM_PERMISSION_ALLOWED_USER_IDS is set once to the first id and kept, so",
    "# team members you add to TELEGRAM_ALLOWED_USER_IDS later never get them.",
    "# Service commands (/new, /compact, /stop, /status, ...) and panel buttons obey",
    "# ONLY TELEGRAM_COMMAND_OWNER_IDS (owner + trusted ids); others get one refusal line.",
    "# Without TELEGRAM_ALLOWED_USER_IDS the plugin refuses to start.",
]
out += [f"{k}={v}" for k, v in managed.items()]
# The expected bot id is only the token prefix; channel-start.sh derives it
# at every start, a stale copy after a bot change would stop the plugin.
extras = {k: v for k, v in existing.items() if k not in managed and k != "TELEGRAM_EXPECTED_BOT_ID"}
if extras:
    out.append("# --- kept from the previous file ---")
    out += [f"{k}={v}" for k, v in extras.items()]
print("\n".join(out))
PY
}

# merge_env_file <rendered> <existing> <answer_keys_csv> -- prints the merged
# KEY=VALUE file. Answer keys: the rendered (operator) value wins unless it is
# empty. Every other key: the existing value wins (hand edits survive).
# Keys only in the existing file are kept at the end. Comments follow the
# rendered file. Exit 3: the existing file has something this parser does not
# fully understand (multi-line value, odd line, repeated key, $-interpolation)
# -- keep that file as it is.
merge_env_file() {
    python3 - "$@" <<'PY'
import re
import sys
from pathlib import Path

rendered_path, existing_path, answer_csv = sys.argv[1:4]
answer_keys = {k for k in answer_csv.split(",") if k}
line_re = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$")
# The existing file may be hand-edited: accept `export KEY = value` too.
# Anything this parser does not fully understand (a quote that does not close
# on its own line, a line that is not KEY=value) -> exit 3, file kept as is.
existing_re = re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$")
closed_re = re.compile(r"""^(?:"(?:[^"\\]|\\.)*"|'[^'\\]*')$""")

existing: dict[str, str] = {}
for line in Path(existing_path).read_text().splitlines():
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    m = existing_re.match(line)
    if not m:
        sys.exit(3)
    value = m.group(2)
    if value[:1] in ("'", '"') and not closed_re.match(value):
        sys.exit(3)
    if m.group(1) in existing:    # repeated key: which one wins is not ours to guess
        sys.exit(3)
    if "$" in value:              # interpolation depends on line order we change
        sys.exit(3)
    existing[m.group(1)] = value

out: list[str] = []
seen: set[str] = set()
for line in Path(rendered_path).read_text().splitlines():
    m = line_re.match(line)
    if not m:
        out.append(line)
        continue
    key, value = m.group(1), m.group(2)
    seen.add(key)
    if key in existing:
        if key in answer_keys:
            if not value.strip():
                value = existing[key]
        else:
            value = existing[key]
    out.append(f"{key}={value}")

extras = [(k, v) for k, v in existing.items() if k not in seen]
if extras:
    out.append("")
    out.append("# --- kept from the previous file ---")
    out += [f"{k}={v}" for k, v in extras]
print("\n".join(out))
PY
}

# _accept_trust_dialog <claude_json> <project_dir>... -- sets
# projects[<dir>].hasTrustDialogAccepted=true for each dir and takes
# dashi-channel off its disabledMcpjsonServers; keeps every other key.
_accept_trust_dialog() {
    as_agent python3 - "$@" <<'PY'
import json
import os
import shutil
import sys
import tempfile
from pathlib import Path

path, projects_to_trust = Path(sys.argv[1]), sys.argv[2:]
data: dict = {}
mode = 0o600
if path.exists():
    try:
        data = json.loads(path.read_text() or "{}")
    except json.JSONDecodeError as exc:
        sys.exit(f"{path}: not valid JSON ({exc}); left untouched")
    if not isinstance(data, dict):
        sys.exit(f"{path}: top level is not an object; left untouched")
    mode = path.stat().st_mode & 0o777
    backup = path.with_name(path.name + ".bak-install")
    if not backup.exists():
        shutil.copy2(path, backup)

projects = data.setdefault("projects", {})
if not isinstance(projects, dict):
    sys.exit(f"{path}: 'projects' is not an object; left untouched")
for project in projects_to_trust:
    entry = projects.setdefault(project, {})
    if not isinstance(entry, dict):
        sys.exit(f"{path}: projects[{project}] is not an object; left untouched")
    entry["hasTrustDialogAccepted"] = True
    disabled = entry.get("disabledMcpjsonServers")
    if isinstance(disabled, list) and "dashi-channel" in disabled:
        entry["disabledMcpjsonServers"] = [s for s in disabled if s != "dashi-channel"]
# First TUI start otherwise stops on the theme picker, which nobody answers.
data.setdefault("hasCompletedOnboarding", True)

fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".claude.json.")
with os.fdopen(fd, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
os.chmod(tmp, mode)
os.replace(tmp, path)
PY
}

# _approve_channel_mcp <settings.local.json>... -- in each file: dashi-channel
# into enabledMcpjsonServers, out of disabledMcpjsonServers (repairs a first
# start that rejected it); every other key kept. Mirrors the live agents.
_approve_channel_mcp() {
    as_agent python3 - "$@" <<'PY'
import json
import os
import sys
import tempfile
from pathlib import Path

SERVER = "dashi-channel"
for arg in sys.argv[1:]:
    path = Path(arg)
    data: dict = {}
    mode = 0o600    # new file: private; an existing one keeps its own mode
    if path.exists():
        mode = path.stat().st_mode & 0o777
        try:
            data = json.loads(path.read_text() or "{}")
        except json.JSONDecodeError as exc:
            sys.exit(f"{path}: not valid JSON ({exc}); left untouched")
        if not isinstance(data, dict):
            sys.exit(f"{path}: top level is not an object; left untouched")
    enabled = data.get("enabledMcpjsonServers", [])
    disabled = data.get("disabledMcpjsonServers", [])
    if not isinstance(enabled, list) or not isinstance(disabled, list):
        sys.exit(f"{path}: MCP server lists are not arrays; left untouched")
    if SERVER not in enabled:
        enabled.append(SERVER)
    data["enabledMcpjsonServers"] = enabled
    if SERVER in disabled:
        data["disabledMcpjsonServers"] = [s for s in disabled if s != SERVER]
    path.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".settings.local.")
    with os.fdopen(fd, "w") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")
    os.chmod(tmp, mode)
    os.replace(tmp, path)
PY
}

# _write_if_absent SRC DST MODE -- write_as_user, but an existing file wins
# (the agent's CLAUDE.md and memory survive a re-run of the installer).
_write_if_absent() {
    if [[ -e "$2" ]]; then
        return 0
    fi
    write_as_user "$@"
}

# _write_agent_workspace <wsroot> -- lays down CLAUDE.md + core/ tree for Jarvis.
# Matches prod smoke-check #5: ls ~/.claude-lab/jarvis/.claude/ must show
# CLAUDE.md, USER.md (under core/), skills/.
_write_agent_workspace() {
    local ws="$1"

    install -d -m 0755 -o "$AGENT_USER" -g "$AGENT_USER" \
        "$ws" \
        "${ws}/core" \
        "${ws}/core/hot" \
        "${ws}/core/warm" \
        "${ws}/skills" \
        "${ws}/logs"

    # CLAUDE.md (top-level)
    local claude_md_tmp
    claude_md_tmp=$(mktemp)
    TMPFILES+=("$claude_md_tmp")
    render_template "${TEMPLATES_DIR}/CLAUDE.md" "$claude_md_tmp" \
        AGENT_NAME "Jarvis" \
        AGENT_ROLE "operator's daily AI assistant" \
        USER_NAME  "$OPERATOR_NAME" \
        LANGUAGE   "$OPERATOR_LANGUAGE" \
        TIMEZONE   "$OPERATOR_TIMEZONE"
    _write_if_absent "$claude_md_tmp" "${ws}/CLAUDE.md" 0644

    # core/USER.md -- operator profile
    local user_tmp
    user_tmp=$(mktemp)
    TMPFILES+=("$user_tmp")
    cat > "$user_tmp" <<UEOF
# USER.md -- Operator profile

**Name:** ${OPERATOR_NAME}
**Timezone:** ${OPERATOR_TIMEZONE}
**Preferred language:** ${OPERATOR_LANGUAGE}

## Notes
- Edit this file freely -- the agent reads it on every start.
UEOF
    _write_if_absent "$user_tmp" "${ws}/core/USER.md" 0644

    # core/rules.md
    local rules_tmp
    rules_tmp=$(mktemp)
    TMPFILES+=("$rules_tmp")
    cat > "$rules_tmp" <<'REOF'
# Rules

- Ask before destructive operations (rm -rf, DROP TABLE, sudo on shared infra).
- Never commit secrets. Never print tokens/keys in plain text.
- On each correction: update LEARNINGS.md so the mistake does not repeat.
- Prefer small, reversible changes.

## One reply per question

- На один вопрос человека одно сообщение. Промежуточные статусы человеку не слать. Итог «готово» один раз, в конце.
- Уже ответил по теме: дополнение только если появилось новое. Повторять «готово» другими словами нельзя.
- Побудка из группы = ответ в группу, в личку тот же ответ не дублировать.
- Отправил человеку сообщение из handoff = сразу вычеркни этот пункт в handoff, в том же ходе.
- После рестарта, прежде чем отправлять что-то из handoff, открой этот чат и проверь, не ушло ли уже. Ушло = вычеркни, не повторяй.
REOF
    _write_if_absent "$rules_tmp" "${ws}/core/rules.md" 0644

    # Stub cold memory + hot/warm files so @includes in CLAUDE.md resolve.
    local stub_tmp
    stub_tmp=$(mktemp)
    TMPFILES+=("$stub_tmp")

    printf '# MEMORY.md\n\nLong-term notes.\n' > "$stub_tmp"
    _write_if_absent "$stub_tmp" "${ws}/core/MEMORY.md" 0644

    printf '# LEARNINGS.md\n\nOne line per correction.\n' > "$stub_tmp"
    _write_if_absent "$stub_tmp" "${ws}/core/LEARNINGS.md" 0644

    printf '# recent.md -- full journal (NOT in @include)\n' > "$stub_tmp"
    _write_if_absent "$stub_tmp" "${ws}/core/hot/recent.md" 0644

    printf '# handoff.md -- last 10 entries (@include)\n' > "$stub_tmp"
    _write_if_absent "$stub_tmp" "${ws}/core/hot/handoff.md" 0644

    printf '# decisions.md -- last 14 days of decisions (@include)\n' > "$stub_tmp"
    _write_if_absent "$stub_tmp" "${ws}/core/warm/decisions.md" 0644
}

# =============================================================================
# STEP 7: INSTALL RICHARD
# =============================================================================

install_richard() {
    step 7 "Installing Richard (claude-code-telegram)"

    install -d -m 0755 -o "$AGENT_USER" -g "$AGENT_USER" "$RICHARD_HOME"

    local venv="${RICHARD_HOME}/venv"
    if [[ ! -x "${venv}/bin/python" ]]; then
        sudo -u "$AGENT_USER" -H -- env -C "$RICHARD_HOME" python3 -m venv "$venv"
    fi

    sudo -u "$AGENT_USER" -H -- env -C "$RICHARD_HOME" "${venv}/bin/pip" install --upgrade pip --quiet
    sudo -u "$AGENT_USER" -H -- env -C "$RICHARD_HOME" "${venv}/bin/pip" install "$RICHARD_REPO_SPEC" --quiet

    if [[ ! -x "${venv}/bin/claude-telegram-bot" ]]; then
        die "Richard install did not produce 'claude-telegram-bot' binary in ${venv}/bin/."
    fi

    # Launcher that masks the bot token in every log line: httpx logs the
    # api.telegram.org/bot<TOKEN>/... URL at INFO and the unit sends stdout to
    # journald. Kept outside site-packages, so a pip upgrade does not undo it.
    [[ -f "${TEMPLATES_DIR}/richard-launch.py" ]] || die "Template not found: ${TEMPLATES_DIR}/richard-launch.py"
    install -d -m 0755 -o root -g root "${RICHARD_HOME}/launch"
    install -m 0644 -o root -g root "${TEMPLATES_DIR}/richard-launch.py" \
        "${RICHARD_HOME}/launch/richard_launch.py"

    # .env
    local env_tmp
    env_tmp=$(mktemp)
    render_template "${TEMPLATES_DIR}/richard.env" "$env_tmp" \
        RICHARD_BOT_TOKEN    "$RICHARD_BOT_TOKEN" \
        RICHARD_BOT_USERNAME "$RICHARD_BOT_USERNAME" \
        TG_USER_ID           "$TG_USER_ID" \
        USER                 "$AGENT_USER"
    # Re-run (migration): an Enter on the token / id questions must not
    # blank a working Richard -- merge with the existing .env, back it up.
    local richard_env="${RICHARD_HOME}/.env"
    if [[ -f "$richard_env" ]]; then
        local merged_tmp
        merged_tmp=$(mktemp)
        TMPFILES+=("$merged_tmp")
        local merge_rc=0
        merge_env_file "$env_tmp" "$richard_env" \
            TELEGRAM_BOT_TOKEN,TELEGRAM_BOT_USERNAME,ALLOWED_USERS >"$merged_tmp" \
            || merge_rc=$?
        if [[ "$merge_rc" -eq 3 ]]; then
            warn "${richard_env} has lines the installer cannot merge safely -- left as it is (edit it by hand if needed)."
            cp "$richard_env" "$merged_tmp"
        elif [[ "$merge_rc" -ne 0 ]]; then
            die "Could not merge ${richard_env}."
        fi
        if ! cmp -s "$merged_tmp" "$richard_env"; then
            install -m 0600 -o "$AGENT_USER" -g "$AGENT_USER" \
                "$richard_env" "${richard_env}.bak-$(date +%Y%m%d-%H%M%S)"
        fi
        mv "$merged_tmp" "$env_tmp"
    fi
    install_as_user "$env_tmp" "$richard_env" "$AGENT_USER" 0600
    rm -f "$env_tmp"

    # systemd unit
    local unit_tmp
    unit_tmp=$(mktemp)
    render_template "${TEMPLATES_DIR}/claude-richard.service" "$unit_tmp" \
        USER "$AGENT_USER"
    install -m 0644 -o root -g root "$unit_tmp" /etc/systemd/system/claude-richard.service
    rm -f "$unit_tmp"

    ok "Richard installed at ${RICHARD_HOME}"
}

# =============================================================================
# STEP 8: GLOBAL ~/.claude/ (OAuth creds live here, shared by Jarvis + Richard)
# =============================================================================

# Starter agent rules: one source, templates/AGENT-RULES-STARTER.md, appended
# to the global CLAUDE.md between these markers (fresh install and re-run alike).
readonly STARTER_RULES_BEGIN='<!-- agent-rules-starter:begin -->'
readonly STARTER_RULES_END='<!-- agent-rules-starter:end -->'
# Phrase of rule 4; a file that already has it carries the rules in some form.
readonly STARTER_RULES_PROBE='Понял так'

# _starter_rules_block -- prints the starter rules wrapped in the markers, with the
# trusted ids filled in: owner = TG_USER_ID (empty -> "владелец." without an id),
# supervisor = SUPERVISOR_TG_ID (empty -> its line is omitted). Ids are digits only.
_starter_rules_block() {
    local src="${TEMPLATES_DIR}/AGENT-RULES-STARTER.md" owner="${TG_USER_ID:-}" sup="${SUPERVISOR_TG_ID:-}"
    [[ -f "$src" ]] || die "Template not found: $src"
    [[ -z "$owner" || "$owner" =~ ^[0-9]+$ ]] || die "Telegram user ID must be a positive integer (got: ${owner})."
    [[ -z "$sup" || "$sup" =~ ^[0-9]+$ ]] || die "NEUROOTDEL_SUPERVISOR_TG_ID must be a positive integer (got: ${sup})."
    printf '\n%s\n' "$STARTER_RULES_BEGIN"
    awk -v owner="$owner" -v sup="$sup" '
        function put(s, key, val,    i) {
            while ((i = index(s, key)) > 0) s = substr(s, 1, i - 1) val substr(s, i + length(key))
            return s
        }
        index($0, "{{SUPERVISOR_TG_ID}}") && sup == "" { next }
        {
            line = $0
            if (owner == "") line = put(line, ", Telegram id {{OWNER_TG_ID}}", "")
            line = put(line, "{{OWNER_TG_ID}}", owner)
            line = put(line, "{{SUPERVISOR_TG_ID}}", sup)
            print line
        }' "$src"
    printf '%s\n' "$STARTER_RULES_END"
}

# ensure_starter_rules FILE -- for an already installed global CLAUDE.md:
# appends the starter rules when the file has neither the markers nor the
# rule-4 phrase. Backs the file up first and never rewrites the owner's text.
# Idempotent: a re-run finds the markers and does nothing.
ensure_starter_rules() {
    local dst
    dst=$(readlink -f -- "$1") || return 0
    [[ -f "$dst" ]] || return 0
    if grep -qF -- "$STARTER_RULES_BEGIN" "$dst" || grep -qF -- "$STARTER_RULES_PROBE" "$dst"; then
        return 0
    fi

    local tmp bak mode
    tmp=$(mktemp)
    TMPFILES+=("$tmp")
    cat -- "$dst" > "$tmp"
    # Keep the owner's last line intact when the file lacks a final newline.
    if [[ -s "$tmp" && -n "$(tail -c1 "$tmp")" ]]; then
        printf '\n' >> "$tmp"
    fi
    _starter_rules_block >> "$tmp"

    bak="${dst}.bak-$(date +%Y%m%d-%H%M%S)-starter-rules"
    cp -p -- "$dst" "$bak" || die "Cannot back up ${dst}; starter rules not added."
    mode=$(stat -c '%a' -- "$dst")
    write_as_user "$tmp" "$dst" "$mode"
    ok "Starter rules appended to ${dst} (backup: ${bak})."
}

# RED secrets rule: passwords, keys, access and internal details go out only by
# the owner's decision. Its own block, so installs made before it get it too.
readonly RED_SECRETS_BEGIN='<!-- red-secrets-rule:begin -->'

# ensure_red_secrets_rule <CLAUDE.md> -- appends templates/RED-SECRETS-RULE.md
# once (backup first); a file that already has the marker is left alone.
ensure_red_secrets_rule() {
    local dst src="${TEMPLATES_DIR}/RED-SECRETS-RULE.md"
    [[ -f "$src" ]] || die "Template not found: $src"
    dst=$(readlink -f -- "$1") || return 0
    [[ -f "$dst" ]] || return 0
    grep -qF -- "$RED_SECRETS_BEGIN" "$dst" && return 0

    local tmp bak mode
    tmp=$(mktemp)
    TMPFILES+=("$tmp")
    cat -- "$dst" > "$tmp"
    if [[ -s "$tmp" && -n "$(tail -c1 "$tmp")" ]]; then
        printf '\n' >> "$tmp"
    fi
    cat -- "$src" >> "$tmp"

    bak="${dst}.bak-$(date +%Y%m%d-%H%M%S)-red-secrets"
    cp -p -- "$dst" "$bak" || die "Cannot back up ${dst}; RED secrets rule not added."
    mode=$(stat -c '%a' -- "$dst")
    write_as_user "$tmp" "$dst" "$mode"
    ok "RED secrets rule appended to ${dst} (backup: ${bak})."
}

# ensure_secret_guard_hook <settings.json> <guard.py> -- adds the PreToolUse hook
# that stops outbound messages carrying passwords/keys/tokens; idempotent by the
# script name, every other key kept, backup before the first change.
ensure_secret_guard_hook() {
    local dst=$1 guard=$2 tmp rc=0 mode=644
    tmp=$(mktemp)
    TMPFILES+=("$tmp")
    python3 - "$dst" "$guard" "$tmp" <<'PY' || rc=$?
import json
import sys
from pathlib import Path

path, guard, out = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
MATCHER = "mcp__dashi-channel__reply|mcp__dashi-channel__edit_message|mcp__gbrain-swarm__notify"
data: dict = {}
if path.exists():
    try:
        data = json.loads(path.read_text() or "{}")
    except json.JSONDecodeError as exc:
        sys.exit(f"{path}: not valid JSON ({exc}); left untouched")
    if not isinstance(data, dict):
        sys.exit(f"{path}: top level is not an object; left untouched")
hooks = data.setdefault("hooks", {})
pre = hooks.setdefault("PreToolUse", []) if isinstance(hooks, dict) else None
if not isinstance(pre, list):
    sys.exit(f"{path}: hooks.PreToolUse is not an array; left untouched")
def wired(entry: object) -> bool:
    """An entry that runs the guard on every outbound tool."""
    if not isinstance(entry, dict) or not isinstance(entry.get("hooks"), list):
        return False
    tools = set(str(entry.get("matcher", "")).split("|"))
    runs = any(isinstance(h, dict) and h.get("type") == "command"
               and str(h.get("command", "")).strip() == f"python3 {guard}" for h in entry["hooks"])
    return runs and set(MATCHER.split("|")) <= tools
if any(wired(e) for e in pre):
    sys.exit(3)  # already wired
pre.append({"matcher": MATCHER,
            "hooks": [{"type": "command", "command": f"python3 {guard}", "timeout": 10}]})
out.write_text(json.dumps(data, indent=2) + "\n")
PY
    [[ $rc -eq 3 ]] && return 0
    [[ $rc -eq 0 ]] || return "$rc"
    if [[ -f "$dst" ]]; then
        mode=$(stat -c '%a' -- "$dst")
        [[ -f "${dst}.bak-install" ]] || cp -p -- "$dst" "${dst}.bak-install" || return 1
    fi
    write_as_user "$tmp" "$dst" "$mode"
}

setup_global_claude() {
    step 8 "Setting up ${AGENT_HOME}/.claude/ (shared OAuth dir)"

    local claude_dir="${AGENT_HOME}/.claude"
    install -d -m 0700 -o "$AGENT_USER" -g "$AGENT_USER" "$claude_dir"
    install -d -m 0755 -o "$AGENT_USER" -g "$AGENT_USER" "${claude_dir}/plugins"

    local settings_json="${claude_dir}/settings.json"
    if [[ ! -f "$settings_json" ]]; then
        local tmp
        tmp=$(mktemp)
        TMPFILES+=("$tmp")
        cat > "$tmp" <<'SJEOF'
{
  "env": {
    "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "400000"
  },
  "permissions": {
    "allow": [
      "Bash(npm:*)", "Bash(node:*)", "Bash(git:*)",
      "Bash(python3:*)", "Bash(pip3:*)",
      "Bash(cat:*)", "Bash(ls:*)", "Bash(mkdir:*)",
      "Bash(chmod:*)", "Bash(echo:*)",
      "Read", "Write", "Edit"
    ]
  }
}
SJEOF
        write_as_user "$tmp" "$settings_json" 0644
    fi

    local guard="${claude_dir}/hooks/secret-outbound-guard.py"
    [[ -f "${TEMPLATES_DIR}/secret-outbound-guard.py" ]] \
        || die "Template not found: ${TEMPLATES_DIR}/secret-outbound-guard.py"
    if ! cmp -s -- "${TEMPLATES_DIR}/secret-outbound-guard.py" "$guard"; then
        if [[ -f "$guard" ]]; then
            cp -p -- "$guard" "${guard}.bak-$(date +%Y%m%d-%H%M%S)" \
                || die "Cannot back up ${guard}; guard not updated."
        fi
        write_as_user "${TEMPLATES_DIR}/secret-outbound-guard.py" "$guard" 0755
    fi
    ensure_secret_guard_hook "$settings_json" "$guard" \
        || die "Cannot add the secret guard hook to ${settings_json}."

    local mcp_json="${claude_dir}/mcp.json"
    if [[ ! -f "$mcp_json" ]]; then
        local tmp
        tmp=$(mktemp)
        TMPFILES+=("$tmp")
        echo '{"mcpServers": {}}' > "$tmp"
        write_as_user "$tmp" "$mcp_json" 0644
    fi

    # Global CLAUDE.md -- loaded by every Claude Code session under the agent user.
    # Shared by Jarvis (chat agent) and Richard (server-doctor) so Richard is
    # not blind about the owner, language, and safety rules.
    local global_claude_md="${claude_dir}/CLAUDE.md"
    if [[ ! -f "$global_claude_md" ]]; then
        local tmp
        tmp=$(mktemp)
        TMPFILES+=("$tmp")
        render_template "${TEMPLATES_DIR}/global-CLAUDE.md" "$tmp" \
            USER       "$AGENT_USER" \
            USER_NAME  "$OPERATOR_NAME" \
            TG_ID      "$TG_USER_ID" \
            LANGUAGE   "$OPERATOR_LANGUAGE" \
            TIMEZONE   "$OPERATOR_TIMEZONE"
        _starter_rules_block >> "$tmp"
        write_as_user "$tmp" "$global_claude_md" 0644
    else
        ensure_starter_rules "$global_claude_md"
    fi
    ensure_red_secrets_rule "$global_claude_md"

    fix_owner "$claude_dir"
    ok "${claude_dir} ready."
}

# =============================================================================
# STEP 9: SKILLS (6 from template + 4 bundled = 10)
# =============================================================================

install_skills() {
    step 9 "Installing ${#SKILLS_FROM_TEMPLATE[@]} template + ${#SKILLS_FROM_INSTALLER[@]} bundled skills"

    local dst_parent="${AGENT_HOME}/.claude-lab/jarvis/.claude/skills"
    install -d -m 0755 -o "$AGENT_USER" -g "$AGENT_USER" "$dst_parent"

    local installed=()

    local tpl_dir
    if tpl_dir=$(fetch_template); then
        local tpl_skills_root="${tpl_dir}/skills"
        [[ -d "$tpl_skills_root" ]] || tpl_skills_root="$tpl_dir"

        local name
        for name in "${SKILLS_FROM_TEMPLATE[@]}"; do
            local src="${tpl_skills_root}/${name}"
            if [[ ! -d "$src" ]]; then
                warn "Template skill '${name}' missing -- skipping."
                continue
            fi
            if install_skill_bundle "$src" "$dst_parent" "$name"; then
                installed+=("$name")
            fi
        done
    else
        warn "Template fetch failed -- template skills skipped."
    fi

    local skills_src
    if skills_src=$(locate_installer_skills); then
        local name
        for name in "${SKILLS_FROM_INSTALLER[@]}"; do
            local src="${skills_src}/${name}"
            if [[ ! -d "$src" ]]; then
                warn "Bundled skill '${name}' missing -- skipping."
                continue
            fi
            if install_skill_bundle "$src" "$dst_parent" "$name"; then
                installed+=("$name")
            fi
        done
    else
        warn "Installer skills dir not found -- bundled skills skipped."
    fi

    fix_owner "$dst_parent"
    link_skills_into_plugin "$dst_parent" "${AGENT_HOME}/.claude-lab/jarvis/.claude/dashi-plugin-claude-code"
    ok "Skills installed: ${installed[*]:-<none>} (${#installed[@]}/10)"
}

# link_skills_into_plugin <skills_dir> <plugin_root>
# claude runs in <plugin_root>/plugin and takes the plugin git root as the
# project, so <workspace>/skills is never discovered. A symlink at
# <plugin_root>/.claude/skills attaches them. An existing real dir is kept.
link_skills_into_plugin() {
    local skills_dir=$1 plugin_root=$2
    local link="${plugin_root}/.claude/skills"
    [[ -d "$plugin_root" ]] || { warn "Plugin dir ${plugin_root} missing -- skills not linked into the session."; return 0; }
    if [[ -e "$link" && ! -L "$link" ]]; then
        warn "${link} is a real directory -- left as is; skills in ${skills_dir} may not be visible to Jarvis."
        return 0
    fi
    install -d -m 0755 -o "$AGENT_USER" -g "$AGENT_USER" "${plugin_root}/.claude"
    ln -sfnT "$skills_dir" "$link"
    chown -h "${AGENT_USER}:${AGENT_USER}" "$link" 2>/dev/null || true
    log "Skills linked into the session: ${link} -> ${skills_dir}"
}

# =============================================================================
# STEP 10: SUPERPOWERS PLUGIN
# =============================================================================

# merge_json_file <file> <jq filter> [jq args...] -- applies the filter to a JSON
# object file owned by the agent user and writes it back only when it changed.
# A missing file starts as {}. A file that is not one JSON object is left as it is.
# The first change is backed up to <file>.bak-install.
merge_json_file() {
    local file=$1 filter=$2
    shift 2
    local tmp mode=0644
    tmp=$(mktemp)
    TMPFILES+=("$tmp")
    if [[ -e "$file" ]]; then
        if ! jq -s -e 'length == 1 and (.[0] | type) == "object"' "$file" >/dev/null 2>&1; then
            warn "${file} is not one JSON object -- left as it is."
            return 1
        fi
        mode=$(stat -c %a "$file")
        jq "$@" "$filter" "$file" > "$tmp" || { warn "jq failed on ${file} -- left as it is."; return 1; }
        if jq -e --slurpfile new "$tmp" '. == $new[0]' "$file" >/dev/null 2>&1; then
            return 0
        fi
        [[ -e "${file}.bak-install" ]] || cp -p "$file" "${file}.bak-install"
    else
        jq -n "$@" "{} | ${filter}" > "$tmp" || { warn "jq failed for new ${file}."; return 1; }
    fi
    write_as_user "$tmp" "$file" "$mode"
}

# enable_superpowers <checkout> -- switches the plugin ON for the agent user.
# Claude Code reads enabledPlugins in ~/.claude/settings.json; plugins/config.json
# alone (what earlier versions wrote) leaves the plugin installed but off.
# The checkout is registered as a local (directory) marketplace and installed
# through the CLI; settings.json gets the same two keys directly, so the plugin
# is on even when the CLI step failed. An explicit owner "false" is kept.
enable_superpowers() {
    local sp_dir=$1
    local manifest="${sp_dir}/.claude-plugin/marketplace.json"
    local settings="${AGENT_HOME}/.claude/settings.json"
    local installed="${AGENT_HOME}/.claude/plugins/installed_plugins.json"
    local claude_bin="${AGENT_HOME}/.local/bin/claude"
    local mname pname pid

    if [[ ! -f "$manifest" ]]; then
        warn "Superpowers checkout has no .claude-plugin/marketplace.json -- plugin NOT enabled."
        return 1
    fi
    mname=$(jq -er '.name' "$manifest" 2>/dev/null) || mname=""
    pname=$(jq -er '.plugins[0].name' "$manifest" 2>/dev/null) || pname=""
    if [[ ! "$mname" =~ ^[A-Za-z0-9._-]+$ || ! "$pname" =~ ^[A-Za-z0-9._-]+$ ]]; then
        warn "Superpowers marketplace.json has no usable names -- plugin NOT enabled."
        return 1
    fi
    pid="${pname}@${mname}"

    # Settings are checked BEFORE the CLI touches them: a broken file stays as it
    # is, and an owner "false" is never turned back on by `plugin install`.
    if [[ -e "$settings" ]] && ! jq -s -e 'length == 1 and (.[0] | type) == "object"' "$settings" >/dev/null 2>&1; then
        warn "${settings} is not one JSON object -- left as it is, ${pid} NOT enabled."
        return 1
    fi
    if [[ -e "$settings" ]] && jq -e --arg id "$pid" '.enabledPlugins[$id]? == false' "$settings" >/dev/null 2>&1; then
        warn "${pid} is set to false in ${settings} by the owner -- left off."
        return 0
    fi

    if [[ -x "$claude_bin" ]]; then
        as_agent "$claude_bin" plugin marketplace add "$sp_dir" --scope user >/dev/null 2>&1 \
            || log "claude plugin marketplace add: not added (already known or CLI refused)."
        if ! jq -e --arg id "$pid" '(.plugins[$id] // []) | any(.scope? == "user")' "$installed" >/dev/null 2>&1; then
            as_agent "$claude_bin" plugin install "$pid" --scope user >/dev/null 2>&1 \
                || warn "claude plugin install ${pid} failed -- enabling through settings.json only."
        fi
    else
        warn "claude CLI not found at ${claude_bin} -- enabling through settings.json only."
    fi

    merge_json_file "$settings" '
        .enabledPlugins = (.enabledPlugins // {})
        | (if .enabledPlugins | has($id) then . else .enabledPlugins[$id] = true end)
        | .extraKnownMarketplaces = (.extraKnownMarketplaces // {})
        | (if .extraKnownMarketplaces | has($m) then .
           else .extraKnownMarketplaces[$m] = {source: {source: "directory", path: $p}} end)' \
        --arg id "$pid" --arg m "$mname" --arg p "$sp_dir" \
        || { warn "Could not write ${settings} -- ${pid} NOT enabled."; return 1; }

    if jq -e --arg id "$pid" '.enabledPlugins[$id] == true' "$settings" >/dev/null 2>&1; then
        ok "Superpowers enabled: ${pid} (enabledPlugins in ${settings})."
    else
        warn "${pid} is set to false in ${settings} by the owner -- left off."
    fi
}

install_superpowers() {
    step 10 "Installing Superpowers plugin @ ${SUPERPOWERS_SHA:0:8}"

    local plugins_dir="${AGENT_HOME}/.claude/plugins"
    local sp_dir="${plugins_dir}/superpowers"
    local cfg="${plugins_dir}/config.json"

    install -d -m 0755 -o "$AGENT_USER" -g "$AGENT_USER" "$plugins_dir"

    if [[ -d "$sp_dir" ]]; then
        log "Superpowers already present -- pinning SHA."
        as_agent git -C "$sp_dir" fetch --depth=1 origin "$SUPERPOWERS_SHA" 2>/dev/null \
            || warn "Superpowers fetch failed -- keeping existing checkout."
        as_agent git -C "$sp_dir" checkout --quiet "$SUPERPOWERS_SHA" 2>/dev/null \
            || warn "Superpowers checkout of pinned SHA failed."
    else
        as_agent git clone --quiet --depth 1 "$SUPERPOWERS_REPO" "$sp_dir" \
            || { warn "Failed to clone Superpowers -- skipping."; return 0; }
        as_agent git -C "$sp_dir" fetch --depth=1 origin "$SUPERPOWERS_SHA" 2>/dev/null \
            || warn "Superpowers fetch of pinned SHA failed -- using HEAD."
        as_agent git -C "$sp_dir" checkout --quiet "$SUPERPOWERS_SHA" 2>/dev/null \
            || warn "Superpowers checkout of pinned SHA failed -- using HEAD."
    fi

    # Switch it on (enabledPlugins). Before the legacy config.json below, whose
    # early returns must not leave the plugin installed but off.
    enable_superpowers "$sp_dir" || true

    # Defensive jq merge of plugins config.
    local tmp
    tmp=$(mktemp)
    TMPFILES+=("$tmp")
    local abs_path="$sp_dir"

    if [[ -f "$cfg" ]]; then
        if ! jq -e 'type=="object"' "$cfg" >/dev/null 2>&1; then
            local backup
            backup="${cfg}.bak.$(date +%s)"
            cp "$cfg" "$backup" 2>/dev/null || true
            warn "Existing ${cfg} is not a JSON object -- backed up to $(basename "$backup"); skipping merge."
            fix_owner "$plugins_dir"
            return 0
        fi
        if ! jq --arg p "$abs_path" \
                '.plugins = ((.plugins // {}) + {"superpowers": {"enabled": true, "path": $p}})' \
                "$cfg" > "$tmp" 2>/dev/null; then
            warn "jq merge of plugins config failed -- leaving ${cfg} untouched."
            return 0
        fi
        [[ ! -s "$tmp" ]] && { warn "jq empty output -- skipping."; return 0; }
    else
        if ! jq -n --arg p "$abs_path" \
                '{plugins: {superpowers: {enabled: true, path: $p}}}' > "$tmp" 2>/dev/null; then
            warn "Failed to write initial plugins config -- skipping."
            return 0
        fi
    fi
    write_as_user "$tmp" "$cfg" 0644

    fix_owner "$plugins_dir"
    ok "Superpowers installed at ${sp_dir}"
}

# =============================================================================
# STEP 11: SUDOERS (passwordless narrow-scope for agent self-repair)
# =============================================================================

# render_sudoers -- prints the sudoers file for the agent user to stdout.
# apt is NOT listed: `sudo apt-get *` takes -o APT::Update::Pre-Invoke::=<cmd>
# and is full root. Package installs go through ${APT_WRAPPER_BIN} only.
render_sudoers() {
    cat <<SUDOERS
# ${INSTALL_TAG} v${INSTALLER_VERSION} -- passwordless sudo for '${AGENT_USER}'.
# Scope: systemctl + journalctl for the agent units, plus package installs
# through ${APT_WRAPPER_BIN} (plain package names only, no apt options).
# claude-gateway stays listed: it is the --rollback target on migrated servers.

Cmnd_Alias ${SUDO_ALIAS}_SYSTEMCTL = \\
    /usr/bin/systemctl start claude-gateway, \\
    /usr/bin/systemctl stop claude-gateway, \\
    /usr/bin/systemctl restart claude-gateway, \\
    /usr/bin/systemctl status claude-gateway, \\
    /usr/bin/systemctl is-active claude-gateway, \\
    /usr/bin/systemctl enable claude-gateway, \\
    /usr/bin/systemctl disable claude-gateway, \\
    /usr/bin/systemctl start ${JARVIS_UNIT}, \\
    /usr/bin/systemctl stop ${JARVIS_UNIT}, \\
    /usr/bin/systemctl restart ${JARVIS_UNIT}, \\
    /usr/bin/systemctl status ${JARVIS_UNIT}, \\
    /usr/bin/systemctl is-active ${JARVIS_UNIT}, \\
    /usr/bin/systemctl enable ${JARVIS_UNIT}, \\
    /usr/bin/systemctl disable ${JARVIS_UNIT}, \\
    /usr/bin/systemctl start claude-richard, \\
    /usr/bin/systemctl stop claude-richard, \\
    /usr/bin/systemctl restart claude-richard, \\
    /usr/bin/systemctl status claude-richard, \\
    /usr/bin/systemctl is-active claude-richard, \\
    /usr/bin/systemctl enable claude-richard, \\
    /usr/bin/systemctl disable claude-richard, \\
    /usr/bin/systemctl daemon-reload

Cmnd_Alias ${SUDO_ALIAS}_JOURNAL = \\
    /usr/bin/journalctl -u claude-gateway, \\
    /usr/bin/journalctl -u claude-gateway *, \\
    /usr/bin/journalctl -u ${JARVIS_UNIT}, \\
    /usr/bin/journalctl -u ${JARVIS_UNIT} *, \\
    /usr/bin/journalctl -u claude-richard, \\
    /usr/bin/journalctl -u claude-richard *

Cmnd_Alias ${SUDO_ALIAS}_APT = ${APT_WRAPPER_BIN}

${AGENT_USER} ALL=(root) NOPASSWD: ${SUDO_ALIAS}_SYSTEMCTL, ${SUDO_ALIAS}_JOURNAL, ${SUDO_ALIAS}_APT
SUDOERS
}

install_sudoers() {
    step 11 "Granting ${AGENT_USER} narrow passwordless sudo"

    local sudoers_file="$SUDOERS_FILE"
    local tmp
    tmp=$(mktemp)
    TMPFILES+=("$tmp")

    render_sudoers > "$tmp"

    # Validate syntax before installing -- a broken sudoers can lock out sudo.
    if ! visudo -cf "$tmp" >/dev/null 2>&1; then
        err "Generated sudoers failed visudo -cf syntax check. Aborting install to avoid lockout."
        return 1
    fi

    # Wrapper first: the sudoers rule must never point at a missing or
    # user-writable file. /usr/local/sbin is root-owned.
    install -d -m 0755 -o root -g root "$(dirname "$APT_WRAPPER_BIN")"
    install -m 0755 -o root -g root "${TEMPLATES_DIR}/agent-apt-install.sh" "$APT_WRAPPER_BIN"

    install -m 0440 -o root -g root "$tmp" "$sudoers_file"
    ok "Sudoers installed at ${sudoers_file} (0440), apt only via ${APT_WRAPPER_BIN}."
}

# =============================================================================
# STEP 12: MEMORY ROTATION SCRIPTS + CRON
# =============================================================================

# Install the 4 memory-rotation scripts into the jarvis workspace and register
# them with the agent user's crontab: rotate-warm / trim-hot / compress-warm /
# memory-rotate. (ov-session-sync is not scheduled: it idles without OpenViking.)
install_memory_cron() {
    step 12 "Installing memory-rotation scripts + cron"

    local scripts_src
    if [[ -d "${INSTALLER_ROOT}/scripts" ]]; then
        scripts_src="${INSTALLER_ROOT}/scripts"
    else
        warn "scripts/ directory missing at ${INSTALLER_ROOT} -- memory cron skipped."
        return 0
    fi

    local scripts_dst="${AGENT_HOME}/.claude-lab/jarvis/scripts"
    install -d -m 0755 -o "$AGENT_USER" -g "$AGENT_USER" "$scripts_dst"

    local logs_dst="${AGENT_HOME}/.claude-lab/jarvis/logs"
    install -d -m 0755 -o "$AGENT_USER" -g "$AGENT_USER" "$logs_dst"

    local name
    local installed=()
    local required=(trim-hot rotate-warm compress-warm memory-rotate)
    for name in "${required[@]}"; do
        local src="${scripts_src}/${name}.sh"
        if [[ ! -f "$src" ]]; then
            # Every job of the block must be on cron. A partial
            # install would leave dead cron entries pointing at missing files
            # -- fail loud so the student doesn't ship a half-wired workspace.
            err "Memory script '${name}.sh' missing at ${src} -- refusing partial install."
            return 1
        fi
        install -m 0755 -o "$AGENT_USER" -g "$AGENT_USER" "$src" "${scripts_dst}/${name}.sh"
        installed+=("$name")
    done

    # Ensure cron service is enabled + running. On minimal Ubuntu images
    # (LXC, cloud) the cron package is installed but not auto-started.
    systemctl enable --now cron 2>/dev/null \
        || warn "cron service not started -- memory rotation will run after next reboot."

    # Merge cron lines with the agent user's existing crontab without clobbering it.
    # Marker lets us update on reinstall instead of duplicating entries.
    local marker="# ${INSTALL_TAG} v${INSTALLER_VERSION}: memory rotation"
    local cron_block
    # CRON_TZ pins the schedule to UTC so the Day-2 diagnostic contract
    # (04:30/05:00/06:00/21:00 UTC) fires at the same wall-clock moment
    # regardless of the host's system timezone. HOME= is set because scripts
    # rely on $HOME under `set -u`; on some minimal images cron does not
    # always export HOME to the user's actual home directory.
    cron_block=$(cat <<CRON
${marker}
CRON_TZ=UTC
HOME=${AGENT_HOME}
30 4 * * * ${scripts_dst}/rotate-warm.sh >> ${logs_dst}/memory-cron.log 2>&1
0 5 * * *  ${scripts_dst}/trim-hot.sh >> ${logs_dst}/memory-cron.log 2>&1
0 6 * * *  ${scripts_dst}/compress-warm.sh >> ${logs_dst}/memory-cron.log 2>&1
0 21 * * * ${scripts_dst}/memory-rotate.sh >> ${logs_dst}/memory-cron.log 2>&1
# ${INSTALL_TAG} memory rotation end
CRON
)

    local current_tmp new_tmp
    current_tmp=$(mktemp)
    new_tmp=$(mktemp)
    TMPFILES+=("$current_tmp" "$new_tmp")

    # Fetch current crontab (empty is fine on first run).
    crontab -u "$AGENT_USER" -l 2>/dev/null > "$current_tmp" || true

    # Strip any previous managed block so we can re-insert the current one.
    python3 - "$current_tmp" "$new_tmp" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src, encoding='utf-8') as f:
    text = f.read()
cleaned = re.sub(
    r'# (?:edgelab|neurootdel)-install v[0-9.]+: memory rotation.*?# (?:edgelab|neurootdel)-install memory rotation end\n?',
    '',
    text,
    flags=re.DOTALL,
)
open(dst, 'w', encoding='utf-8').write(cleaned.rstrip() + ('\n' if cleaned.strip() else ''))
PY

    # Append new block.
    printf '%s\n' "$cron_block" >> "$new_tmp"

    if ! crontab -u "$AGENT_USER" "$new_tmp" 2>/dev/null; then
        err "Failed to install crontab for ${AGENT_USER} -- memory rotation will not run. Day-2 self-diagnostic will flag this as a failure."
        return 1
    fi

    # Verify the block actually landed so a silent crontab discard doesn't slip through.
    if ! crontab -u "$AGENT_USER" -l 2>/dev/null | grep -q "${INSTALL_TAG} memory rotation end"; then
        err "crontab accepted the file but memory-rotation block is not visible on read-back."
        return 1
    fi

    ok "Memory cron installed: ${installed[*]}"
}

# =============================================================================
# STEP 12b: AGENT GUARD (session reset, memory backup, watchdog, hooks) -- ON
# =============================================================================

# Scripts from lib/ go to GUARD_LIB_DIR (root-owned: the watchdog runs as root and
# must never execute a file the agent can edit). guard.conf next to them carries
# the install names; it holds no secrets.

# _guard_conf_value <value> -- drops what guard.conf cannot hold (quotes, \, $, `, newlines).
_guard_conf_value() {
    printf '%s' "$1" | tr -d '"\\$`\n\r'
}

# _guard_conf_get <file> <KEY> -- a value from an existing guard.conf, empty if none.
_guard_conf_get() {
    [[ -f "$1" ]] || return 0
    sed -n "s/^${2}=\"\\([^\"]*\\)\"\$/\\1/p" "$1" | tail -n 1
}

# _env_is_set <NAME> -- NEUROOTDEL_<NAME> is set, even to "" (FACT_GATE_* keys have no
# EDGELAB_ name).
_env_is_set() {
    local new="NEUROOTDEL_$1"
    [[ -n "${!new+x}" ]]
}

# _gate_conf_pick <existing> <KEY> -- NEUROOTDEL_<KEY> if set (an empty one clears), else the
# value already in guard.conf.
_gate_conf_pick() {
    local new="NEUROOTDEL_$2"
    if _env_is_set "$2"; then printf '%s' "${!new}"; else _guard_conf_get "$1" "$2"; fi
}

# _guard_conf_has <file> <KEY> -- the key is in an existing guard.conf (even with "").
_guard_conf_has() {
    [[ -f "$1" ]] && grep -q "^${2}=" "$1"
}

# render_guard_conf [existing] -- prints guard.conf. Answers from this run win; the
# owner's own choices in an existing file (agents list, labels, alert route) are kept
# when this run gave none.
render_guard_conf() {
    local existing="${1:-}"
    local agents labels mode chat wrules wclaude fself fbots furl fenv fstyle
    agents=$(_guard_conf_get "$existing" CHANNEL_AGENTS)
    wrules="$(env_value WEIGHT_RULES_KB)"
    [[ -n "$wrules" ]] || wrules=$(_guard_conf_get "$existing" WEIGHT_RULES_KB)
    [[ -z "$wrules" || "$wrules" =~ ^[1-9][0-9]{0,4}$ ]] || { warn "WEIGHT_RULES_KB '${wrules}' is not a number -- using 30."; wrules=""; }
    wclaude="$(env_value WEIGHT_CLAUDE_KB)"
    [[ -n "$wclaude" ]] || wclaude=$(_guard_conf_get "$existing" WEIGHT_CLAUDE_KB)
    [[ -z "$wclaude" || "$wclaude" =~ ^[1-9][0-9]{0,4}$ ]] || { warn "WEIGHT_CLAUDE_KB '${wclaude}' is not a number -- using 40."; wclaude=""; }
    labels=$(_guard_conf_get "$existing" AGENT_LABELS)
    mode="$(env_value GUARD_ALERTS)"
    [[ -n "$mode" ]] || mode=$(_guard_conf_get "$existing" ALERT_MODE)
    case "${mode:-outbox}" in
        outbox|telegram|log) mode="${mode:-outbox}" ;;
        *) warn "NEUROOTDEL_GUARD_ALERTS='${mode}' is not outbox|telegram|log -- using outbox."; mode=outbox ;;
    esac
    chat="$(env_value GUARD_ALERT_CHAT_ID)"
    [[ -n "$chat" ]] || chat=$(_guard_conf_get "$existing" ALERT_TG_CHAT_ID)
    [[ -z "$chat" || "$chat" =~ ^-?[0-9]+$ ]] || { warn "Alert chat id '${chat}' is not a number -- ignored."; chat=""; }
    # Fact-check gate: the agent's own bot id is the numeric part of its token (public, not a secret).
    # Order: env (an empty one clears), then the key in guard.conf (an empty one stays empty),
    # then, only when neither has it, the id from the token.
    fself=$(_gate_conf_pick "$existing" FACT_GATE_SELF_IDS)
    if ! _env_is_set FACT_GATE_SELF_IDS && ! _guard_conf_has "$existing" FACT_GATE_SELF_IDS && [[ "${JARVIS_BOT_TOKEN:-}" =~ ^([0-9]+): ]]; then fself="${BASH_REMATCH[1]}"; fi
    [[ -z "$fself" || "$fself" =~ ^[0-9]+([\ ,]+[0-9]+)*$ ]] || { warn "FACT_GATE_SELF_IDS '${fself}' is not a list of ids -- ignored."; fself=""; }
    fbots=$(_gate_conf_pick "$existing" FACT_GATE_BOT_IDS)
    if ! _env_is_set FACT_GATE_BOT_IDS && ! _guard_conf_has "$existing" FACT_GATE_BOT_IDS && [[ "${RICHARD_BOT_TOKEN:-}" =~ ^([0-9]+): ]]; then fbots="${BASH_REMATCH[1]}"; fi
    [[ -z "$fbots" || "$fbots" =~ ^[0-9]+([\ ,]+[0-9]+)*$ ]] || { warn "FACT_GATE_BOT_IDS '${fbots}' is not a list of ids -- ignored."; fbots=""; }
    furl=$(_gate_conf_pick "$existing" FACT_GATE_CHIP_URL)
    [[ -z "$furl" || "$furl" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?/?$ ]] || { warn "FACT_GATE_CHIP_URL '${furl}' is not http(s)://host[:port] -- chip off."; furl=""; }
    fenv=$(_gate_conf_pick "$existing" FACT_GATE_CHIP_ENV)
    [[ -z "$fenv" || "$fenv" =~ ^/[A-Za-z0-9._/-]+$ ]] || { warn "FACT_GATE_CHIP_ENV '${fenv}' is not an absolute path -- chip off."; fenv=""; }
    fstyle=$(_gate_conf_pick "$existing" FACT_GATE_STYLE_BANNED)
    cat <<EOF
# ${INSTALL_TAG} v${INSTALLER_VERSION}: settings of the agent guard scripts. No secrets here.
# A re-run of the installer rewrites this file and keeps CHANNEL_AGENTS, AGENT_LABELS,
# ALERT_MODE, ALERT_TG_CHAT_ID and the WEIGHT_* caps unless new values are given.
# WEIGHT_RULES_KB / WEIGHT_CLAUDE_KB: caps of core/rules.md and CLAUDE.md in the nightly
#                        memory weight watch (journals handoff/decisions: 15 KB, fixed).
# ALERT_MODE: outbox   = alerts are JSON files in /var/lib/${AGENT_USER}-guard/outbox
#                        (read them: python3 ${GUARD_LIB_DIR}/agents-guard.py --drain),
#                        plus the log /var/log/${AGENT_USER}-guard.log;
#             telegram = the same, and each alert is also sent by the Richard bot
#                        (token from RICHARD_ENV) to ALERT_TG_CHAT_ID (default: owner);
#             log      = only the log.
# FACT_GATE_* (hooks/fact-check-gate.py, the check of a reply/edit before it is sent; kept on re-run):
#   (an env NEUROOTDEL_FACT_GATE_<KEY> wins, set to "" it clears the key)
#   SELF_IDS     the agent's own Telegram bot id(s) (default: from the Jarvis bot token);
#   BOT_IDS      other bot accounts never taken for a person (default: the Richard bot id);
#   CHIP_URL     optional Telegram user-account chip, http://host:port (empty = tag check and
#                ready-post exception off, the gate makes no network calls);
#   CHIP_ENV     file with CHIP_API_TOKEN=... readable by the agent (needed with CHIP_URL);
#   STYLE_BANNED optional comma-separated banned words, «word*» = stem (empty = no style check).
AGENT_USER="$(_guard_conf_value "$AGENT_USER")"
AGENT_HOME="$(_guard_conf_value "$AGENT_HOME")"
LIB_DIR="$(_guard_conf_value "$GUARD_LIB_DIR")"
CONFIG_ROOT="$(_guard_conf_value "$CONFIG_ROOT")"
CHANNEL_AGENTS="$(_guard_conf_value "${agents:-jarvis}")"
MAIN_AGENT="jarvis"
AGENT_LABELS="$(_guard_conf_value "${labels:-jarvis=Jarvis}")"
OWNER_NAME="$(_guard_conf_value "$OPERATOR_NAME")"
OWNER_TG_ID="$(_guard_conf_value "$TG_USER_ID")"
OWNER_TIMEZONE="$(_guard_conf_value "${OPERATOR_TIMEZONE:-Europe/Moscow}")"
RICHARD_UNIT="claude-richard"
RICHARD_ENV="$(_guard_conf_value "${RICHARD_HOME}/.env")"
ALERT_MODE="${mode}"
ALERT_TG_CHAT_ID="$(_guard_conf_value "$chat")"
WEIGHT_RULES_KB="${wrules:-30}"
WEIGHT_CLAUDE_KB="${wclaude:-40}"
FACT_GATE_SELF_IDS="$(_guard_conf_value "$fself")"
FACT_GATE_BOT_IDS="$(_guard_conf_value "$fbots")"
FACT_GATE_CHIP_URL="$(_guard_conf_value "$furl")"
FACT_GATE_CHIP_ENV="$(_guard_conf_value "$fenv")"
FACT_GATE_STYLE_BANNED="$(_guard_conf_value "$fstyle")"
EOF
}

# _install_cron_file <name> <body> -- /etc/cron.d/<name>, root 0644, written atomically.
_install_cron_file() {
    local name=$1 body=$2 tmp
    tmp=$(mktemp)
    TMPFILES+=("$tmp")
    printf '%s\n' "$body" > "$tmp"
    install -m 0644 -o root -g root "$tmp" "/etc/cron.d/${name}"
}

# add_hook <settings.json> <event> <matcher|""> <command> <timeout> [own-marker]
# Adds one command hook unless an entry with the same matcher already runs the same
# command (owner hooks are kept). own-regex matches OUR earlier command of that event
# as a whole (anchored); such a command is replaced, so a changed port leaves one hook.
# An owner command that merely calls the same script never matches the full pattern.
add_hook() {
    local file=$1 ev=$2 matcher=$3 cmd=$4 to=$5 own=${6:-}
    merge_json_file "$file" '
        .hooks = (.hooks // {})
        | .hooks[$ev] = ((.hooks[$ev] // [])
            | (if $own == "" then .
               else map(if (.hooks | type) == "array"
                        then .hooks |= map(select(((.command? // "") | test($own) and . != $cmd) | not))
                        else . end)
                    | map(select((.hooks | type) != "array" or (.hooks | length) > 0))
               end)
            | if any(.[]?; ((.matcher // "") == $m) and any((.hooks // [])[]?; .command? == $cmd)) then .
              else . + [((if $m == "" then {} else {matcher: $m} end)
                         + {hooks: [{type: "command", command: $cmd, timeout: ($to | tonumber)}]})]
              end)' \
        --arg ev "$ev" --arg m "$matcher" --arg cmd "$cmd" --arg to "$to" --arg own "$own"
}

# _re_escape <text> -- the text as a literal inside a jq (Oniguruma) regex.
_re_escape() {
    printf '%s' "$1" | sed 's/[][\\.*^$+?(){}|]/\\&/g'
}

# setup_agent_hooks -- every hook goes into a settings.json the session REALLY reads:
#   user  ~/.claude/settings.json (every session of the agent user, Richard's too: his
#         cwd is the home dir): compact reminder, dangerous-command and protected-file stops,
#         command log, review reminder;
#   main agent: <plugin>/plugin/.claude/settings.json (claude runs with cwd plugin/):
#         correction capture, auto-recall, critical thinking, fact-check gate, fallback reply,
#         lessons at start, pre-compaction flush.
# A file under <workspace>/.claude/settings.json would never load: claude does not run there.
setup_agent_hooks() {
    step 12 "Switching the agent hooks on (user + plugin settings.json)"

    local lib="$GUARD_LIB_DIR" hooks="${GUARD_LIB_DIR}/hooks"
    local user_settings="${AGENT_HOME}/.claude/settings.json"
    local ws="${AGENT_HOME}/.claude-lab/jarvis/.claude"
    local plugin_dir="${ws}/dashi-plugin-claude-code/plugin"
    local plugin_settings="${plugin_dir}/.claude/settings.json"
    local fact_state="${AGENT_HOME}/.claude-lab/shared/state/jarvis/factcheck"
    local fail=0

    add_hook "$user_settings" SessionStart compact "python3 ${lib}/compact-open-items-reminder.py" 20 || fail=1
    add_hook "$user_settings" SessionStart startup "python3 ${lib}/compact-open-items-reminder.py" 20 || fail=1
    add_hook "$user_settings" PreToolUse Bash "python3 ${hooks}/block-dangerous.py" 10 || fail=1
    add_hook "$user_settings" PreToolUse 'Edit|Write|MultiEdit' "bash ${hooks}/protect-files.sh" 10 || fail=1
    add_hook "$user_settings" PreToolUse Bash "bash ${hooks}/log-commands.sh" 5 || fail=1
    add_hook "$user_settings" PostToolUse 'Edit|Write|MultiEdit' "bash ${hooks}/review-reminder.sh" 5 || fail=1
    merge_json_file "$user_settings" '.env = (.env // {}) | (if .env | has("CLAUDE_CODE_AUTO_COMPACT_WINDOW") then . else .env.CLAUDE_CODE_AUTO_COMPACT_WINDOW = "400000" end)' || fail=1

    if [[ -d "$plugin_dir" ]]; then
        as_agent mkdir -p "${plugin_dir}/.claude" "$fact_state" || fail=1
        local port
        port=$(sed -n 's/^TELEGRAM_WEBHOOK_PORT=\([0-9]*\)$/\1/p' "${JARVIS_ENV_DIR}/channel.env" 2>/dev/null | tail -n 1)
        add_hook "$plugin_settings" UserPromptSubmit "" "python3 ${hooks}/correction-detector.py ${ws}" 10 || fail=1
        add_hook "$plugin_settings" UserPromptSubmit "" "python3 ${hooks}/auto-recall.py jarvis" 10 || fail=1
        add_hook "$plugin_settings" UserPromptSubmit "" "python3 ${hooks}/critical-check.py" 5 || fail=1
        # The gate checks edits too; an entry of an earlier install (matcher reply only) is moved to the new matcher.
        local fact_cmd="python3 ${hooks}/fact-check-gate.py ${fact_state}"
        merge_json_file "$plugin_settings" '
            if (.hooks.PreToolUse | type) == "array" then
                .hooks.PreToolUse |= (map(if .matcher == $old and (.hooks | type) == "array"
                                          then .hooks |= map(select(.command? != $cmd)) else . end)
                                      | map(select((.hooks | type) != "array" or (.hooks | length) > 0)))
            else . end' --arg old mcp__dashi-channel__reply --arg cmd "$fact_cmd" || fail=1
        add_hook "$plugin_settings" PreToolUse 'mcp__dashi-channel__reply|mcp__dashi-channel__edit_message' "$fact_cmd" 10 || fail=1
        add_hook "$plugin_settings" Stop "" "TELEGRAM_FALLBACK_REPLY_URL='http://127.0.0.1:${port:-8089}/hooks/fallback-reply' ${AGENT_HOME}/.bun/bin/bun '${plugin_dir}/scripts/fallback-reply-hook.ts'" 30 \
            "^TELEGRAM_FALLBACK_REPLY_URL='http://127\\.0\\.0\\.1:[0-9]+/hooks/fallback-reply' $(_re_escape "${AGENT_HOME}/.bun/bin/bun") '$(_re_escape "${plugin_dir}/scripts/fallback-reply-hook.ts")'\$" || fail=1
        add_hook "$plugin_settings" SessionStart "" "python3 ${hooks}/learnings-engine.py ${ws} top" 10 || fail=1
        add_hook "$plugin_settings" PreCompact 'manual|auto' "bash ${hooks}/precompact-flush.sh jarvis" 40 || fail=1
    else
        warn "Plugin dir ${plugin_dir} missing -- main agent hooks NOT set."
        fail=1
    fi

    if [[ "$fail" -ne 0 ]]; then
        err "Some hooks were NOT switched on -- see the warnings above."
        return 1
    fi
    ok "Hooks on: ${user_settings} (all sessions), ${plugin_settings} (main agent)."
}

# install_agents_guard_cron -- the root watchdog, once a minute (stall, login, limit,
# owner unanswered, restart queue). Alerts follow ALERT_MODE in guard.conf.
install_agents_guard_cron() {
    install -d -m 0700 -o root -g root "/var/lib/${AGENT_USER}-guard"
    _install_cron_file "${AGENT_USER}-agents-guard" "$(cat <<CRON
# ${INSTALL_TAG} v${INSTALLER_VERSION}: agents guard (stall/login/limit/owner unanswered/restart queue).
# Stop: touch /var/lib/${AGENT_USER}-guard/STOP ; alerts: python3 ${GUARD_LIB_DIR}/agents-guard.py --drain
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
* * * * * root /usr/bin/python3 ${GUARD_LIB_DIR}/agents-guard.py >/dev/null 2>>/var/log/${AGENT_USER}-guard.err
CRON
)"
}

# install_memory_weight_cron -- the nightly weight watch of the always-loaded memory (rule 5b).
# Hourly; --auto weighs only in the 04:xx hour of the owner's clock (OWNER_TIMEZONE in guard.conf),
# after the 04:00 session reset, so the server timezone and clock changes do not matter.
install_memory_weight_cron() {
    install -d -m 0700 -o root -g root "/var/lib/${AGENT_USER}-memory-weight"
    _install_cron_file "${AGENT_USER}-memory-weight" "$(cat <<CRON
# ${INSTALL_TAG} v${INSTALLER_VERSION}: memory weight watch (rule 5b): handoff/decisions > 15 KB,
# core/rules.md > WEIGHT_RULES_KB, CLAUDE.md > WEIGHT_CLAUDE_KB (guard.conf) -> one signal to the agent a day.
# Stop: touch /var/lib/${AGENT_USER}-memory-weight/STOP ; remove this file to uninstall.
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
20 * * * * root /usr/bin/python3 ${GUARD_LIB_DIR}/memory_weight_watch.py --auto >> /var/log/${AGENT_USER}-memory-weight.log 2>&1
CRON
)"
}

# install_service_watch_cron <shared_state> -- the small watchdogs, all on from the start.
# Alerts of the root ones go through outbox-put.py (ALERT_MODE in guard.conf).
install_service_watch_cron() {
    local st=$1 u="$AGENT_USER" lib="$GUARD_LIB_DIR"
    as_agent mkdir -p "${st}/disk-clean" "${st}/claude-usage" "${st}/command-log" "${st}/review-reminder" \
        || die "Could not create watchdog state dirs as ${u}."
    _install_cron_file "${u}-service-watch" "$(cat <<CRON
# ${INSTALL_TAG} v${INSTALLER_VERSION}: service watchdogs. Remove this file to uninstall all five.
# Stops: resource   touch /var/lib/${u}-resource/STOP
#        disk-clean touch ${st}/disk-clean/STOP
#        manifest   touch /var/lib/${u}-cron-manifest/STOP
#        autosync   touch /var/lib/${u}-autosync/STOP
#        usage      touch ${st}/claude-usage/STOP   (report: python3 ${lib}/claude-usage-digest.py)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/5 * * * * root /usr/bin/flock -n /run/${u}-resource.lock /bin/bash ${lib}/resource-watchdog.sh >/dev/null 2>>/var/log/${u}-resource.err
*/10 * * * * ${u} /bin/bash ${lib}/disk-clean-old.sh >/dev/null 2>>${st}/disk-clean/cron.err
23 * * * * root /bin/bash ${lib}/cron-manifest-watchdog.sh >/dev/null 2>>/var/log/${u}-cron-manifest.err
*/30 * * * * root /usr/bin/flock -n /run/${u}-autosync.lock /bin/bash ${lib}/agents-git-autosync.sh >/dev/null 2>>/var/log/${u}-autosync.err
17 * * * * ${u} [ -e ${st}/claude-usage/STOP ] || /usr/bin/timeout 900 /usr/bin/python3 ${lib}/claude-usage-collector.py >/dev/null 2>&1
CRON
)"
}

install_guard() {
    step 12 "Installing agent guard: session reset, memory backup, watchdog (cron ON)"

    local src="${INSTALLER_ROOT}/lib"
    [[ -d "$src" ]] || die "lib/ directory missing at ${INSTALLER_ROOT} -- guard scripts cannot be installed."

    install -d -m 0755 -o root -g root "$GUARD_LIB_DIR"
    install -d -m 0755 -o root -g root "${GUARD_LIB_DIR}/hooks"
    local f
    for f in "$src"/*.py "$src"/*.sh "$src"/hooks/*.py "$src"/hooks/*.sh; do
        [[ -f "$f" ]] || continue
        install -m 0755 -o root -g root "$f" "${GUARD_LIB_DIR}/${f#"$src"/}"
    done

    local conf="${GUARD_LIB_DIR}/guard.conf" conf_tmp
    conf_tmp=$(mktemp)
    TMPFILES+=("$conf_tmp")
    render_guard_conf "$conf" > "$conf_tmp"
    install -m 0644 -o root -g root "$conf_tmp" "$conf"

    # State and backup dirs live in the agent's home: created BY the agent user, so a
    # path the agent swapped for a symlink never hands it a root-owned target.
    local shared_state="${AGENT_HOME}/.claude-lab/shared/state"
    as_agent mkdir -p "${shared_state}/agents-reset" "${shared_state}/quiet-restart" \
        "${AGENT_HOME}/backups/memory" \
        || die "Could not create guard state dirs as ${AGENT_USER}."
    as_agent chmod 0700 "${shared_state}/agents-reset" "${shared_state}/quiet-restart" \
        "${AGENT_HOME}/backups" "${AGENT_HOME}/backups/memory" || true

    systemctl enable --now cron 2>/dev/null \
        || warn "cron service not started -- guard jobs will run after next reboot."

    local reset_state="${shared_state}/agents-reset"
    _install_cron_file "${AGENT_USER}-agents-reset" "$(cat <<CRON
# ${INSTALL_TAG} v${INSTALLER_VERSION}: session reset of the channel agents (agents-reset.sh).
# Every 10 min; --auto picks the run by the owner's clock (OWNER_TIMEZONE in guard.conf),
# so the server timezone does not matter: nightly 04:00, by context size 06:00-22:59.
# Stop: touch ${reset_state}/STOP ; remove this file to uninstall. Log: ${reset_state}/agents-reset.log
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
*/10 * * * * ${AGENT_USER} /usr/bin/flock -n ${reset_state}/run.lock /bin/bash ${GUARD_LIB_DIR}/agents-reset.sh --auto >> ${reset_state}/cron.log 2>&1
CRON
)"

    local bk="${AGENT_HOME}/backups/memory"
    _install_cron_file "${AGENT_USER}-memory-backup" "$(cat <<CRON
# ${INSTALL_TAG} v${INSTALLER_VERSION}: nightly local backup of the agents' memory (memory-backup.sh).
# Hourly; --auto backs up only at 03:30 by the owner's clock, before the 04:00 reset.
# Stop: touch ${bk}/STOP (or delete this file).
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
30 * * * * ${AGENT_USER} /bin/bash ${GUARD_LIB_DIR}/memory-backup.sh --auto >> ${bk}/backup.log 2>&1
CRON
)"

    install_agents_guard_cron
    install_service_watch_cron "$shared_state"
    install_memory_weight_cron
    ok "Guard installed in ${GUARD_LIB_DIR}; cron: /etc/cron.d/${AGENT_USER}-{agents-reset,memory-backup,agents-guard,service-watch,memory-weight}"
}

# =============================================================================
# STEP 12c: GROUP WATCH (wakes the agent on group messages) -- files always, ON only with a chip
# =============================================================================

# The channel plugin does not see group updates. lib/group-watch.py reads a group through a
# Telegram user-account chip and wakes the agent via its webhook. The installer has no chip,
# so the unit is only written; one instance is enabled when this run names a group and a chip:
#   NEUROOTDEL_GROUP_WATCH_CHAT_ID  group id (-100...)       NEUROOTDEL_GROUP_WATCH_CHIP  http://127.0.0.1:<port>
# optional: _NAME (instance, default main), _TITLE, _AGENT (default jarvis), _BOT_ID (default: from the
# agent's bot token), _BOT_USERNAME, _CHIP_ENV_FILE, _ALL_HUMAN (0|1, default 0), _NAME_REGEX,
# _PEER_BOT_IDS, _IGNORE_IDS, _BOT_WAKES_PER_HOUR, _WHISPER_URL, _FEED (0|1), _STAGING_UID.
# Stop: touch /var/lib/<user>-group-watch/<name>/STOP, or systemctl disable --now <user>-group-watch@<name>.

# _gw_clean <value> -- one line for a systemd EnvironmentFile: no quotes, backslashes, $, backticks, newlines.
_gw_clean() {
    printf '%s' "$1" | tr -d '"\\$`\n\r'
}

# _gw_quoted <value> -- a value written in single quotes (systemd keeps it literal, backslashes too).
_gw_quoted() {
    printf '%s' "$1" | tr -d "'\n\r"
}

# _gw_bot_id <channel.env> -- the numeric part of the bot token (the bot's public id); the token is never printed.
_gw_bot_id() {
    [[ -f "$1" ]] || return 0
    sed -n 's/^TELEGRAM_BOT_TOKEN=["]\{0,1\}\([0-9][0-9]*\):.*/\1/p' "$1" | tail -n 1
}

# _gw_bot_username <agent> <channel.env> -- the bot's @username without @: NEUROOTDEL_GROUP_WATCH_BOT_USERNAME,
# else this run's Jarvis answer (agent jarvis only), else getMe with the agent's own token (never printed).
_gw_bot_username() {
    local agent=$1 envf=$2 user token resp
    user="$(env_value GROUP_WATCH_BOT_USERNAME)"
    if [[ -z "$user" && "$agent" == jarvis ]]; then
        user="${JARVIS_BOT_USERNAME:-}"
    fi
    if [[ -z "$user" && -f "$envf" ]]; then
        token=$(sed -n 's/^TELEGRAM_BOT_TOKEN=["]\{0,1\}\([^"]*\)["]\{0,1\}$/\1/p' "$envf" | tail -n 1)
        if [[ -n "$token" ]] && validate_tg_token "$token"; then
            resp=$(tg_get_me "$token")
            user=$(printf '%s' "$resp" | jq -r 'if .ok == true then (.result.username // "") else "" end' 2>/dev/null || true)
        fi
    fi
    printf '%s' "${user#@}"
}

# render_group_watch_unit -- the template unit, one instance per group.
render_group_watch_unit() {
    local conf_dir=$1
    cat <<EOF
# ${INSTALL_TAG} v${INSTALLER_VERSION}: group watcher (lib/group-watch.py), one instance per group.
# Settings: ${conf_dir}/%i.env. Stop: touch /var/lib/${AGENT_USER}-group-watch/%i/STOP
# or: systemctl disable --now ${AGENT_USER}-group-watch@%i
[Unit]
Description=Group watcher %i: wakes the agent on messages in a Telegram group (user-account chip)
After=network-online.target
Wants=network-online.target
ConditionPathExists=${conf_dir}/%i.env

[Service]
Type=simple
EnvironmentFile=${conf_dir}/%i.env
Environment=PYTHONUNBUFFERED=1
ExecStart=/usr/bin/python3 ${GUARD_LIB_DIR}/group-watch.py
Restart=on-failure
RestartSec=30
# 2 = settings incomplete: fix the env file instead of restarting forever.
RestartPreventExitStatus=2
# Group texts in the state dir stay private to root.
UMask=0077
PrivateTmp=yes
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF
}

# render_group_watch_env <name> <chat_id> <chip> -- the instance's env file from NEUROOTDEL_GROUP_WATCH_*.
# Prints nothing and returns 1 when a value is malformed.
render_group_watch_env() {
    local name=$1 chat=$2 chip=$3
    local agent title bot_id bot_user chip_env all_human name_re peers ignore bot_cap whisper feed staging_uid
    agent="$(env_value GROUP_WATCH_AGENT)"; agent="${agent:-jarvis}"
    title="$(_gw_quoted "$(env_value GROUP_WATCH_TITLE)")"
    bot_id="$(env_value GROUP_WATCH_BOT_ID)"
    [[ -n "$bot_id" ]] || bot_id="$(_gw_bot_id "${CONFIG_ROOT}/${agent}/channel.env")"
    bot_user="$(_gw_bot_username "$agent" "${CONFIG_ROOT}/${agent}/channel.env")"
    chip_env="$(_gw_clean "$(env_value GROUP_WATCH_CHIP_ENV_FILE)")"
    all_human="$(env_value GROUP_WATCH_ALL_HUMAN)"; all_human="${all_human:-0}"
    name_re="$(_gw_quoted "$(env_value GROUP_WATCH_NAME_REGEX)")"
    peers="$(env_value GROUP_WATCH_PEER_BOT_IDS)"
    ignore="$(env_value GROUP_WATCH_IGNORE_IDS)"
    bot_cap="$(env_value GROUP_WATCH_BOT_WAKES_PER_HOUR)"; bot_cap="${bot_cap:-6}"
    whisper="$(env_value GROUP_WATCH_WHISPER_URL)"
    feed="$(env_value GROUP_WATCH_FEED)"; feed="${feed:-0}"
    staging_uid="$(env_value GROUP_WATCH_STAGING_UID)"
    [[ -n "$staging_uid" ]] || staging_uid="$(id -u "$AGENT_USER" 2>/dev/null || true)"
    local bad=""
    [[ "$name" =~ ^[a-z0-9-]{1,32}$ ]] || bad+=" NAME"
    [[ "$chat" =~ ^-[0-9]+$ ]] || bad+=" CHAT_ID"
    [[ "$chip" =~ ^http://[A-Za-z0-9.-]+(:[0-9]+)?/?$ ]] || bad+=" CHIP"
    [[ "$agent" =~ ^[a-z0-9-]+$ ]] || bad+=" AGENT"
    [[ "$bot_id" =~ ^[0-9]+$ ]] || bad+=" BOT_ID"
    [[ "$bot_user" =~ ^[A-Za-z0-9_]{3,64}$ ]] || bad+=" BOT_USERNAME"   # the tag is the default call: required
    [[ "$all_human" =~ ^[01]$ ]] || bad+=" ALL_HUMAN"
    [[ "$feed" =~ ^[01]$ ]] || bad+=" FEED"
    [[ "$peers" =~ ^[0-9,\ ]*$ ]] || bad+=" PEER_BOT_IDS"
    [[ "$ignore" =~ ^[0-9,\ ]*$ ]] || bad+=" IGNORE_IDS"
    [[ "$bot_cap" =~ ^[0-9]+$ ]] || bad+=" BOT_WAKES_PER_HOUR"
    [[ -z "$whisper" || "$whisper" =~ ^https?://[A-Za-z0-9._:-]+(/[A-Za-z0-9._/-]*)?$ ]] || bad+=" WHISPER_URL"
    [[ "$staging_uid" =~ ^[0-9]+$ ]] || bad+=" STAGING_UID"
    if [[ -n "$bad" ]]; then
        warn "Group watch: bad NEUROOTDEL_GROUP_WATCH_{${bad# }} -- instance not written."
        return 1
    fi
    cat <<EOF
# ${INSTALL_TAG} v${INSTALLER_VERSION}: group watcher instance ${name}. A re-run with
# NEUROOTDEL_GROUP_WATCH_CHAT_ID rewrites this file; without it the file is kept as is.
GW_CHAT_ID=${chat}
GW_TITLE='${title}'
GW_CHIP=${chip%/}
GW_CHIP_ENV_FILE=${chip_env}
GW_AGENT=${agent}
GW_BOT_ID=${bot_id}
GW_BOT_USERNAME=${bot_user}
GW_ALL_HUMAN=${all_human}
GW_NAME_REGEX='${name_re}'
GW_PEER_BOT_IDS=${peers}
GW_IGNORE_IDS=${ignore}
GW_BOT_WAKES_PER_HOUR=${bot_cap}
GW_WHISPER_URL=${whisper}
GW_FEED=${feed}
GW_BASE=/var/lib/${AGENT_USER}-group-watch/${name}
GW_STAGING=/dev/shm/${AGENT_USER}-group-watch-${name}
GW_STAGING_UID=${staging_uid}
EOF
}

# install_group_watch -- template unit always; one instance on only with CHAT_ID + CHIP.
install_group_watch() {
    local unit_dir="${GROUP_WATCH_SYSTEMD_DIR:-/etc/systemd/system}"
    local conf_dir="${GROUP_WATCH_CONF_DIR:-/etc/${AGENT_USER}/group-watch}"
    local unit="${AGENT_USER}-group-watch@"
    local tmp
    tmp=$(mktemp); TMPFILES+=("$tmp")
    render_group_watch_unit "$conf_dir" >"$tmp"
    install -m 0644 -o root -g root "$tmp" "${unit_dir}/${unit}.service"
    install -d -m 0750 -o root -g root "$conf_dir"

    local chat chip name
    chat="$(env_value GROUP_WATCH_CHAT_ID)"
    chip="$(env_value GROUP_WATCH_CHIP)"
    name="$(env_value GROUP_WATCH_NAME)"; name="${name:-main}"
    if [[ -z "$chat" || -z "$chip" ]]; then
        GROUP_WATCH_STATUS="off"
        log "Group watch: unit ${unit}.service written, not enabled (no NEUROOTDEL_GROUP_WATCH_CHAT_ID/CHIP)."
        return 0
    fi
    local env_tmp
    env_tmp=$(mktemp); TMPFILES+=("$env_tmp")
    if ! render_group_watch_env "$name" "$chat" "$chip" >"$env_tmp"; then
        GROUP_WATCH_STATUS="error"
        return 0
    fi
    install -m 0640 -o root -g root "$env_tmp" "${conf_dir}/${name}.env"
    local agent allowed
    agent=$(sed -n 's/^GW_AGENT=//p' "${conf_dir}/${name}.env")
    allowed=$(sed -n 's/^TELEGRAM_ALLOWED_CHAT_IDS=["]\{0,1\}\([^"]*\)["]\{0,1\}$/\1/p' "${CONFIG_ROOT}/${agent}/channel.env" 2>/dev/null | tail -n 1)
    if [[ ",${allowed}," != *",${chat},"* ]]; then
        warn "Group watch: ${chat} is not in TELEGRAM_ALLOWED_CHAT_IDS of ${CONFIG_ROOT}/${agent}/channel.env -- the helper refuses to wake for it until it is added."
    fi
    systemctl daemon-reload
    # restart, not start: a re-run must pick up the rewritten env file.
    if systemctl enable "${unit}${name}.service" --quiet && systemctl restart "${unit}${name}.service"; then
        GROUP_WATCH_STATUS="on:${name}"
        ok "Group watch ${name} on for chat ${chat} (${unit}${name})."
    else
        GROUP_WATCH_STATUS="error"
        warn "Group watch ${name}: enable failed -- check 'journalctl -u ${unit}${name}'."
    fi
}

# _AGENT_FILE_PY -- runs AS THE AGENT USER (never root) on a path inside the agent's home,
# so a symlink the agent planted can only point root's work at the agent's own files.
#   write  <dst> <mode> <if_absent 0|1>   content on stdin; atomic replace; rc 4 = kept as is
#   block  <file> <tag> <name> <body>     the BEGIN/END block of <name>; bytes outside stay as
#                                         they are; rc 3 = ambiguous markers, 4 = no change
# The final path component must not be a symlink (O_NOFOLLOW); a missing file for "block" = 5.
_AGENT_FILE_PY=$(cat <<'PY'
import os, sys, tempfile

def nofollow_read(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as fh:
        return fh.read()

def atomic_write(path, data, mode):
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".inst.")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise

op = sys.argv[1]
if op == "write":
    dst, mode, if_absent = sys.argv[2], int(sys.argv[3], 8), sys.argv[4] == "1"
    if os.path.islink(dst):
        sys.exit(3)
    if if_absent and os.path.lexists(dst):
        sys.exit(4)
    atomic_write(dst, sys.stdin.buffer.read(), mode)
    sys.exit(0)

path, tag, name, body = sys.argv[2:6]
if not os.path.lexists(path):
    sys.exit(5)
try:
    text = nofollow_read(path)
except OSError:
    sys.exit(3)
begin = f"<!-- BEGIN {tag}: {name} -->".encode()
end = f"<!-- END {tag}: {name} -->".encode()
lines = text.splitlines(keepends=True)
bare = [ln.rstrip(b"\r\n") for ln in lines]
bi = [i for i, ln in enumerate(bare) if ln == begin]
ei = [i for i, ln in enumerate(bare) if ln == end]
# Any other line carrying the marker text (inline, indented) is ambiguous too.
loose = sum(1 for ln in bare if (begin in ln or end in ln) and ln not in (begin, end))
nl = b"\r\n" if b"\r\n" in text else b"\n"
block = [begin + nl] + [ln.encode() + nl for ln in body.rstrip("\n").split("\n")] + [end + nl]
if loose or len(bi) > 1 or len(ei) > 1 or len(bi) != len(ei) or (bi and ei[0] < bi[0]):
    sys.exit(3)
if bi:
    tail = lines[ei[0]]
    if not tail.endswith((b"\n", b"\r")):
        block[-1] = block[-1].rstrip(b"\r\n")
    new = b"".join(lines[: bi[0]] + block + lines[ei[0] + 1 :])
else:
    sep = b"" if not text else (nl if text.endswith((b"\n", b"\r")) else nl + nl)
    new = text + sep + b"".join(block)
if new == text:
    sys.exit(4)
atomic_write(path, new, os.stat(path, follow_symlinks=False).st_mode & 0o7777)
PY
)

# _agent_write <src> <dst> <mode> [if_absent 0|1] -- the file goes in BY the agent user.
_agent_write() {
    local src=$1 dst=$2 mode=$3 if_absent=${4:-0} rc=0
    as_agent python3 -c "$_AGENT_FILE_PY" write "$dst" "$mode" "$if_absent" <"$src" || rc=$?
    case "$rc" in
        0|4) return 0 ;;
        3) warn "${dst} is a symlink -- not written."; return 1 ;;
        *) warn "${dst} not written."; return 1 ;;
    esac
}

# _ensure_marked_block <file> <name> <body> -- the installer's own lines in a file the
# owner also edits live ONLY between "<!-- BEGIN <tag>: <name> -->" and the matching END.
# One clean pair: the body between them is replaced; no markers: the block is appended;
# anything else (two BEGINs, END first, marker inside a line): left alone, rc 1.
_ensure_marked_block() {
    local file=$1 name=$2 body=$3 rc=0
    as_agent python3 -c "$_AGENT_FILE_PY" block "$file" "$INSTALL_TAG" "$name" "$body" </dev/null || rc=$?
    case "$rc" in
        0|4) return 0 ;;
        5) warn "${file} missing -- block '${name}' not added."; return 1 ;;
        3) warn "${file}: markers of '${name}' are ambiguous or the file is a symlink -- left as it is."; return 1 ;;
        *) warn "${file}: block '${name}' not written."; return 1 ;;
    esac
}

# install_team_refs -- the shared team references, code style rules and the memory layout.
#   managed (rewritten on every run):  ~/.claude-lab/shared/team-rules.md and the @-line to it
#                                      between markers in the agent's CLAUDE.md;
#   written only when missing (owner's from then on): shared/{STAFF,AGENTS,TOOLS,
#     PARALLEL-AGENTS,LEARNINGS,LESSONS-STARTER}.md, ~/.claude/rules/*.md, auto-memory MEMORY.md + index-*.md,
#     library/INDEX.md, core/archive/.
# Every file lands through the agent user (_agent_write), never a root write into its home.
install_team_refs() {
    step 12 "Installing team rules, references, code style rules, memory layout"

    local tdir="${TEMPLATES_DIR}"
    local shared="${AGENT_HOME}/.claude-lab/shared"
    local ws="${AGENT_HOME}/.claude-lab/jarvis/.claude"
    # Auto memory sits under the git root the session runs in (the plugin clone).
    local mem_dir
    mem_dir="${AGENT_HOME}/.claude/projects/$(printf '%s' "${ws}/dashi-plugin-claude-code" | sed 's/[^A-Za-z0-9]/-/g')/memory"
    local fail=0 f tmp

    as_agent mkdir -p "$shared" "${AGENT_HOME}/.claude/rules" "$mem_dir" \
        "${ws}/core/archive" "${ws}/library" || die "Could not create reference dirs as ${AGENT_USER}."

    for f in team-rules STAFF AGENTS TOOLS PARALLEL-AGENTS LEARNINGS LESSONS-STARTER; do
        tmp=$(mktemp)
        TMPFILES+=("$tmp")
        render_template "${tdir}/shared/${f}.md" "$tmp" \
            USER_NAME "$OPERATOR_NAME" LIB "$GUARD_LIB_DIR" CONFIG_ROOT "$CONFIG_ROOT" USER "$AGENT_USER"
        if [[ "$f" == team-rules ]]; then
            _agent_write "$tmp" "${shared}/${f}.md" 0644 0 || fail=1
        else
            _agent_write "$tmp" "${shared}/${f}.md" 0644 1 || fail=1
        fi
    done

    for f in bash python typescript; do
        _agent_write "${tdir}/rules/${f}.md" "${AGENT_HOME}/.claude/rules/${f}.md" 0644 1 || fail=1
    done

    for f in MEMORY index-work index-people index-content index-infra; do
        _agent_write "${tdir}/memory/${f}.md" "${mem_dir}/${f}.md" 0644 1 || fail=1
    done
    _agent_write "${tdir}/memory/library-INDEX.md" "${ws}/library/INDEX.md" 0644 1 || fail=1

    _ensure_marked_block "${ws}/CLAUDE.md" team-rules "@~/.claude-lab/shared/team-rules.md" || fail=1

    if [[ "$fail" -ne 0 ]]; then
        err "Team references are not all in place -- see the warnings above."
        return 1
    fi
    ok "Team rules on (@ in ${ws}/CLAUDE.md); references in ${shared}; memory layout in ${mem_dir}."
}

# =============================================================================
# STEP 13: SYSTEMD ENABLE (do not start yet -- OAuth + tokens required first)
# =============================================================================

enable_services() {
    step 13 "Enabling systemd services (and starting if OAuth is already set up)"

    systemctl daemon-reload

    local oauth_ready="no"
    if [[ -f "${AGENT_HOME}/.claude/.credentials.json" ]]; then
        oauth_ready="yes"
    fi

    # Always enable (on-boot auto-start). If tokens are present we also try
    # start -- but only when OAuth credentials exist, otherwise the unit crashes.
    # Decide by the written channel.env: a token filled in by hand earlier
    # counts even when this run got no answer.
    if ! _env_has_value "${JARVIS_ENV_DIR}/channel.env" TELEGRAM_BOT_TOKEN; then
        log "${JARVIS_UNIT} NOT enabled (no token) -- fill ${JARVIS_ENV_DIR}/channel.env, see the final notes."
    elif ! _retire_legacy_gateway; then
        # Two pollers on one bot token fight (409): no start while the old one runs.
        warn "${JARVIS_UNIT} NOT started: old ${LEGACY_GATEWAY_UNIT} is still running. Stop it, then: sudo systemctl enable ${JARVIS_UNIT} && sudo systemctl restart ${JARVIS_UNIT}"
    else
        systemctl enable "${JARVIS_UNIT}.service" --quiet
        if [[ "$oauth_ready" == "yes" ]]; then
            # restart, not start: a re-run must pick up the new channel.env.
            if systemctl restart "${JARVIS_UNIT}.service" 2>/dev/null; then
                ok "${JARVIS_UNIT} enabled + started."
            else
                warn "${JARVIS_UNIT} enabled, but start failed -- check 'journalctl -u ${JARVIS_UNIT}'."
            fi
        else
            log "${JARVIS_UNIT} enabled -- will start after OAuth under ${AGENT_USER}."
        fi
    fi

    if [[ -n "$RICHARD_BOT_TOKEN" ]]; then
        systemctl enable claude-richard.service --quiet
        if [[ "$oauth_ready" == "yes" ]]; then
            if systemctl start claude-richard.service 2>/dev/null; then
                ok "claude-richard enabled + started."
            else
                warn "claude-richard enabled, but start failed -- check 'journalctl -u claude-richard'."
            fi
        else
            log "claude-richard enabled -- will start after OAuth under ${AGENT_USER}."
        fi
    else
        log "claude-richard NOT enabled (no token)."
    fi
}

# _retire_legacy_gateway -- migrated server: back up and stop claude-gateway.
# Its files stay on disk; `install.sh --rollback` turns it back on.
# Returns 1 (gateway left as it was, or still active/enabled) when the backup
# or the stop fails.
_retire_legacy_gateway() {
    local unit_file="/etc/systemd/system/${LEGACY_GATEWAY_UNIT}.service"
    local legacy_dir="${AGENT_HOME}/${LEGACY_GATEWAY_DIR_NAME}"
    if [[ ! -f "$unit_file" ]]; then
        return 0
    fi
    if ! systemctl is-enabled --quiet "$LEGACY_GATEWAY_UNIT" 2>/dev/null \
            && ! systemctl is-active --quiet "$LEGACY_GATEWAY_UNIT" 2>/dev/null; then
        return 0    # already retired by an earlier run
    fi

    # No backup, no switch: the gateway keeps running untouched.
    local backup_dir
    backup_dir="${LEGACY_BACKUP_ROOT}/claude-gateway-$(date +%Y%m%d-%H%M%S)"
    if ! install -d -m 0700 -o root -g root "$LEGACY_BACKUP_ROOT" "$backup_dir" \
            || ! cp -a "$unit_file" "${backup_dir}/"; then
        err "Backup of ${unit_file} to ${backup_dir} failed."
        return 1
    fi
    if [[ -d "$legacy_dir" ]] && ! tar -C "$AGENT_HOME" --exclude="${LEGACY_GATEWAY_DIR_NAME}/.venv" \
            -czf "${backup_dir}/claude-gateway-dir.tgz" "$LEGACY_GATEWAY_DIR_NAME"; then
        err "Backup of ${legacy_dir} to ${backup_dir} failed."
        return 1
    fi

    systemctl disable --now "${LEGACY_GATEWAY_UNIT}.service" --quiet || true
    # Still running now, or enabled to come back at boot: both mean two pollers.
    if systemctl is-active --quiet "$LEGACY_GATEWAY_UNIT" 2>/dev/null \
            || systemctl is-enabled --quiet "$LEGACY_GATEWAY_UNIT" 2>/dev/null; then
        err "Could not stop + disable ${LEGACY_GATEWAY_UNIT} (backup: ${backup_dir})."
        return 1
    fi
    ok "Old ${LEGACY_GATEWAY_UNIT} stopped + disabled (backup: ${backup_dir}). Undo: sudo bash install.sh --rollback"
}

# =============================================================================
# ROLLBACK (--rollback): Jarvis back to the old claude-gateway unit
# =============================================================================

rollback_to_gateway() {
    if [[ $EUID -ne 0 ]]; then
        die "Run as root: sudo $0 --rollback"
    fi

    if [[ ! -f "/etc/systemd/system/${LEGACY_GATEWAY_UNIT}.service" ]]; then
        # Checked first: with nothing to return to, a working Jarvis stays up.
        warn "No ${LEGACY_GATEWAY_UNIT} unit on this server (installed straight on the plugin) -- nothing to return to, ${JARVIS_UNIT} left as it is."
        return 0
    fi
    if [[ -f "/etc/systemd/system/${JARVIS_UNIT}.service" ]]; then
        systemctl disable --now "${JARVIS_UNIT}.service" --quiet || true
        if systemctl is-active --quiet "$JARVIS_UNIT" 2>/dev/null \
                || systemctl is-enabled --quiet "$JARVIS_UNIT" 2>/dev/null; then
            die "Could not stop + disable ${JARVIS_UNIT}; not starting ${LEGACY_GATEWAY_UNIT} next to it (one bot token, two pollers)."
        fi
        ok "${JARVIS_UNIT} stopped + disabled (plugin files kept)."
    fi

    systemctl daemon-reload
    systemctl enable --now "${LEGACY_GATEWAY_UNIT}.service" --quiet \
        || die "Could not start ${LEGACY_GATEWAY_UNIT} -- check 'journalctl -u ${LEGACY_GATEWAY_UNIT}'."
    ok "${LEGACY_GATEWAY_UNIT} enabled + started. Switch to the plugin again: sudo bash install.sh"
}

# =============================================================================
# FINAL BANNER
# =============================================================================

# report_claude_plan [credentials.json] -- prints the plan of the Claude account the
# agents run on (subscriptionType only; tokens are never read out). "pro" gets a
# warning: its usage limit stops a working agent for hours several times a day.
report_claude_plan() {
    local cred=${1:-"${AGENT_HOME}/.claude/.credentials.json"} plan
    if [[ ! -s "$cred" ]]; then
        warn "Claude account: not logged in yet. After 'claude auth login' check the plan:"
        warn "  sudo -u ${AGENT_USER} jq -r .claudeAiOauth.subscriptionType ${cred}"
        return 0
    fi
    plan=$(jq -r '.claudeAiOauth.subscriptionType // "unknown" | tostring | .[0:32]' "$cred" 2>/dev/null) || plan="unreadable"
    plan=${plan//[^A-Za-z0-9_.-]/}
    case "${plan,,}" in
        pro)
            warn "Claude account plan: pro -- too small for agents that work all day: the usage limit"
            warn "  stops them for hours. Use Max (max) for this server." ;;
        "")
            warn "Claude account plan: unknown" ;;
        *)
            ok "Claude account plan: ${plan}" ;;
    esac
}

final_instructions() {
    local jarvis_label="@${JARVIS_BOT_USERNAME:-<fill-in>}"
    local richard_label="@${RICHARD_BOT_USERNAME:-<fill-in>}"
    local tokens_filled
    tokens_filled="Jarvis token: $([[ -n "$JARVIS_BOT_TOKEN" ]] && echo yes || echo no), Richard token: $([[ -n "$RICHARD_BOT_TOKEN" ]] && echo yes || echo no), your user ID: $([[ -n "$TG_USER_ID" ]] && echo yes || echo no)"

    cat <<EOF

$(printf '%b' "$C_GREEN")================================================================================
  НЕЙРООТДЕЛ: neurootdel-install v${INSTALLER_VERSION} complete.  Agent-native flow: the root-Claude
  agent will configure the rest.  Do NOT run commands by hand below.
================================================================================$(printf '%b' "$C_NC")

Installed on this VPS:
  - User:      ${AGENT_USER} (${AGENT_HOME})
  - Claude:    ${AGENT_HOME}/.local/bin/claude  (per-user, on PATH)
  - Jarvis:    ${AGENT_HOME}/.claude-lab/jarvis/.claude/  (systemd: ${JARVIS_UNIT})
               env: ${JARVIS_ENV_DIR}/channel.env
  - Richard:   ${RICHARD_HOME}                       (systemd: claude-richard)
  - Skills:    ${AGENT_HOME}/.claude-lab/jarvis/.claude/skills/  (10 skills)
  - Plugin:    ${AGENT_HOME}/.claude/plugins/superpowers/
  - Sudoers:   ${SUDOERS_FILE}  (narrow, 0440)

$(printf '%b' "$C_BOLD")Tokens filled during install:$(printf '%b' "$C_NC") ${tokens_filled}

$(printf '%b' "$C_BOLD")NEXT STEPS -- these are for the root-Claude agent, not the student:$(printf '%b' "$C_NC")

  $(printf '%b' "$C_YELLOW")1.$(printf '%b' "$C_NC") One-time Anthropic OAuth under ${AGENT_USER} (interactive -- opens browser):

        sudo -u ${AGENT_USER} -i bash -lc 'claude auth login'

      Credentials land in ${AGENT_HOME}/.claude/ and are shared by both agents.
      Check the plan (must not be "pro"): sudo -u ${AGENT_USER} jq -r .claudeAiOauth.subscriptionType ${AGENT_HOME}/.claude/.credentials.json

  $(printf '%b' "$C_YELLOW")2.$(printf '%b' "$C_NC") If tokens were skipped during install, fill them now and restart:

        # Jarvis: ${JARVIS_ENV_DIR}/channel.env --
        #   TELEGRAM_BOT_TOKEN=<token>, and your id in BOTH
        #   TELEGRAM_ALLOWED_USER_IDS=<id> and TELEGRAM_ALLOWED_CHAT_IDS=<id>
        #   Permission prompts ("allow this command?") go only to TELEGRAM_ALLOWED_USER_IDS
        # Richard: ${RICHARD_HOME}/.env -- TELEGRAM_BOT_TOKEN=..., ALLOWED_USERS=<id>

        sudo systemctl enable ${JARVIS_UNIT} claude-richard
        sudo systemctl restart ${JARVIS_UNIT} claude-richard
        sudo systemctl status  ${JARVIS_UNIT} claude-richard --no-pager
        sudo journalctl -u ${JARVIS_UNIT} -f       # Jarvis logs
        sudo -u ${AGENT_USER} tmux -L ${JARVIS_UNIT} capture-pane -p -t ${JARVIS_UNIT} | tail -30   # Jarvis screen

      Undo the switch to the plugin (servers that had claude-gateway):

        sudo bash install.sh --rollback

  $(printf '%b' "$C_YELLOW")3.$(printf '%b' "$C_NC") Smoke-checks:

        id ${AGENT_USER}                                      # uid >= 1000
        node -v                                                 # v22+
        python3 --version                                       # 3.12+
        sudo -u ${AGENT_USER} bash -lc 'which claude'         # ${AGENT_HOME}/.local/bin/claude
        ls ${AGENT_HOME}/.claude-lab/jarvis/.claude/          # CLAUDE.md, core/, skills/
        systemctl is-active ${JARVIS_UNIT}                       # active (after steps 1+2)
        systemctl is-active claude-richard                      # active (after steps 1+2)
        ls -la ${SUDOERS_FILE}                    # exists, 0440
        ls ${AGENT_HOME}/.claude-lab/jarvis/.claude/skills/ | wc -l   # 10
        ls ${AGENT_HOME}/.claude/plugins/superpowers/skills/ 2>/dev/null | wc -l

  $(printf '%b' "$C_YELLOW")4.$(printf '%b' "$C_NC") Group watch (status: ${GROUP_WATCH_STATUS:-off}). Jarvis does not see group messages by itself;
      with a Telegram user-account chip on this server, turn it on for a group (its id also goes into
      TELEGRAM_ALLOWED_CHAT_IDS of ${JARVIS_ENV_DIR}/channel.env):

        sudo NEUROOTDEL_GROUP_WATCH_CHAT_ID=<-100...> NEUROOTDEL_GROUP_WATCH_CHIP=http://127.0.0.1:<port> bash install.sh
        # every human message wakes it only with NEUROOTDEL_GROUP_WATCH_ALL_HUMAN=1 (default: tag/reply/name)
        # stop: sudo touch /var/lib/${AGENT_USER}-group-watch/main/STOP && sudo systemctl disable --now ${AGENT_USER}-group-watch@main

  $(printf '%b' "$C_YELLOW")5.$(printf '%b' "$C_NC") Student talks to Jarvis in Telegram: ${jarvis_label}
      If Jarvis dies, the student messages Richard:  ${richard_label}

EOF
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    if [[ "${1:-}" == "--rollback" ]]; then
        rollback_to_gateway
        return 0
    fi
    if [[ "${1:-}" == "--solo" ]]; then
        SOLO=1
    fi

    banner
    preflight
    if [[ "$SOLO" == "1" ]]; then
        azv_activate
    fi
    install_apt_deps
    require_step_packages
    install_node
    ensure_agent_user
    check_node_for_agent
    install_claude_cli
    install_bun
    collect_inputs
    install_jarvis
    install_richard
    setup_global_claude
    install_skills
    if [[ "$SOLO" == "1" ]]; then
        azv_install_payload
    fi
    install_superpowers
    install_sudoers
    install_memory_cron
    install_guard
    install_group_watch
    setup_agent_hooks || die "Hooks are not all on; fix the warnings above and re-run the installer."
    install_team_refs || die "Team references are not all in place; fix the warnings above and re-run the installer."
    enable_services
    report_claude_plan
    final_instructions
}

# Tests source this file with INSTALL_SH_SOURCED_FOR_TESTING=1 to reach helpers.
if [[ "${INSTALL_SH_SOURCED_FOR_TESTING:-0}" != "1" ]]; then
    main "$@"
fi
