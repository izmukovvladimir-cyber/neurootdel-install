#!/usr/bin/env bash
# edgelab-install v3.0.1 -- 3-Claude architecture installer
#
# Installs on a fresh Ubuntu 22.04 / 24.04 VPS:
#   - edgelab user (dedicated, non-login-privileged)
#   - Node.js 22 + Python 3.12 + Claude Code CLI
#   - Jarvis: izmukovvladimir-cyber/dashi-plugin-claude-code (main) -> systemd unit channel-jarvis
#     (a server that still runs the old claude-gateway is migrated; see --rollback)
#   - Richard: izmukovvladimir-cyber/claude-code-telegram v1.6.0 -> systemd unit claude-richard
#
# Both agents share Anthropic Max OAuth from /home/edgelab/.claude/
# Operator runs `sudo -u edgelab -i bash -lc 'claude auth login'` once after install finishes.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/izmukovvladimir-cyber/edgelab-install/main/install.sh -o install.sh && sudo bash install.sh
#   # or
#   sudo ./install.sh
#   sudo ./install.sh --rollback   # Jarvis back to the old claude-gateway unit
#   sudo ./install.sh --solo       # «Агент за вечер»: asks for the personal key first
#                                  # (or EDGELAB_AZV_KEY=...), stops without a valid one
#
# Env overrides (non-interactive):
#   EDGELAB_JARVIS_BOT_TOKEN   Jarvis Telegram bot token
#   EDGELAB_JARVIS_BOT_USER    Jarvis bot @username (no @)
#   EDGELAB_RICHARD_BOT_TOKEN  Richard Telegram bot token
#   EDGELAB_RICHARD_BOT_USER   Richard bot @username (no @)
#   EDGELAB_TG_USER_ID         Operator Telegram numeric ID
#   EDGELAB_USER_NAME          Operator display name (for Jarvis CLAUDE.md)
#   EDGELAB_LANGUAGE           Operator language (default: Russian)
#   EDGELAB_TIMEZONE           Operator timezone (default: Europe/Moscow)

set -euo pipefail

# =============================================================================
# CONSTANTS
# =============================================================================

readonly EDGELAB_VERSION="3.1.0"
readonly PLUGIN_REPO="https://github.com/izmukovvladimir-cyber/dashi-plugin-claude-code.git"
readonly PLUGIN_REF="main"
readonly JARVIS_UNIT="channel-jarvis"
readonly JARVIS_ENV_DIR="/etc/dashi-plugin/jarvis"
readonly CHANNEL_CONFIRM_BIN="/usr/local/lib/edgelab/channel-confirm.sh"
readonly CHANNEL_START_BIN="/usr/local/lib/edgelab/channel-start.sh"
# Root-owned apt wrapper: the only apt path in sudoers (plain `apt-get *` = root).
readonly APT_WRAPPER_BIN="/usr/local/sbin/edgelab-apt-install"
# Pre-plugin Jarvis (v3.0.x). Kept on disk for --rollback, never deleted.
readonly LEGACY_GATEWAY_UNIT="claude-gateway"
readonly LEGACY_GATEWAY_DIR_NAME="claude-gateway"
readonly LEGACY_BACKUP_ROOT="/var/backups/edgelab-install"
readonly RICHARD_REPO_SPEC="git+https://github.com/izmukovvladimir-cyber/claude-code-telegram@v1.6.0"
readonly RICHARD_HOME="/opt/richard"
readonly NODE_MAJOR="22"
readonly EDGELAB_USER="edgelab"
readonly EDGELAB_HOME="/home/edgelab"

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

TEMPLATES_DIR="${EDGELAB_TEMPLATES_DIR:-$TEMPLATES_DIR_DEFAULT}"
INSTALLER_ROOT="${EDGELAB_INSTALLER_ROOT:-$INSTALLER_ROOT_DEFAULT}"
TEMPLATE_CLONE_DIR=""
INSTALLER_SKILLS_DIR=""

# «Агент за вечер» (--solo): the closed part of the agent is unlocked by a personal key
# bound to this server. Without --solo none of this runs.
readonly AZV_SALT="agent-za-vecher-v1"
AZV_ACTIVATE_URL="${EDGELAB_AZV_URL:-https://hooks.vladimir-izhmukov.ru/agent/activate}"
AZV_MACHINE_ID_FILE="${EDGELAB_AZV_MACHINE_ID_FILE:-/etc/machine-id}"
AZV_STAGE_DIR="${EDGELAB_AZV_STAGE_DIR:-/var/lib/edgelab-install/azv}"
AZV_AGENT_DIR="${EDGELAB_AZV_AGENT_DIR:-${EDGELAB_HOME}/.claude-lab/jarvis/.claude/azv}"
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
    printf '\n%b' "$C_YELLOW"
    cat <<'EOF'
   ____    _           _          _                        _       _ _
  | ___|__| | __ _  __| |   __ _ | |      _ __   ___  _   _| |_    | | |
  |___ \ / _` |/ _` |/ _` |  / _` || |_    | '_ \ / _ \| | | | __|___| | |
   ___) | (_| | (_| | (_| | | (_| ||  _|   | | | |  __/| |_| | |_|___|_|_|
  |____/ \__,_|\__,_|\__,_|  \__,_| |_|    |_| |_|\___| \__,_|\__|   (_|_)

                   edgelab-install v3.0.1 -- 3-Claude edition
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
    [[ "${EDGELAB_NONINTERACTIVE:-0}" == "1" ]] || [[ ! -t 0 ]]
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

as_edgelab() {
    sudo -u "$EDGELAB_USER" -H -- env -C "$EDGELAB_HOME" "$@"
}

# Install a file at dst owned by a specific user, 0600 by default.
install_as_user() {
    local src=$1 dst=$2 owner=$3 mode=${4:-0600}
    install -m "$mode" -o "$owner" -g "$owner" "$src" "$dst"
}

# write_as_user: copy SRC to DST owned by EDGELAB_USER. Works even when SRC is
# a root-owned 0600 mktemp file that edgelab cannot read.
write_as_user() {
    local src="$1" dst="$2" mode="${3:-0644}"
    local dst_dir
    dst_dir=$(dirname "$dst")
    if [[ ! -d "$dst_dir" ]]; then
        install -d -m 0755 -o "$EDGELAB_USER" -g "$EDGELAB_USER" "$dst_dir"
    fi
    install -o "$EDGELAB_USER" -g "$EDGELAB_USER" -m "$mode" "$src" "$dst"
}

# fix_owner: recursively chown to edgelab (-h affects symlinks).
fix_owner() {
    local path="$1"
    [[ -e "$path" ]] || return 0
    chown -RhP "${EDGELAB_USER}:${EDGELAB_USER}" "$path"
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
    prompt_or_env key EDGELAB_AZV_KEY "Личный ключ (AZV-XXXX-XXXX-XXXX-XXXX)" "" --secret
    key="${key//[[:space:]]/}"
    if [[ -z "$key" ]]; then
        die "Без личного ключа установка не продолжается. Ключ пришёл в чат после оплаты. Запусти так: EDGELAB_AZV_KEY=<ключ> sudo bash install.sh --solo"
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
    install -d -m 0755 "$AZV_AGENT_DIR"
    cp -a "${AZV_STAGE_DIR}/." "${AZV_AGENT_DIR}/"
    fix_owner "$AZV_AGENT_DIR"
    ok "Материалы лежат в ${AZV_AGENT_DIR}"
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
    if ! git clone --quiet --depth 1 "https://github.com/izmukovvladimir-cyber/edgelab-install.git" "$dir" >&2; then
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
            if [[ "${EDGELAB_ALLOW_UNTESTED_UBUNTU:-0}" == "1" ]]; then
                warn "Ubuntu ${VERSION_ID:-?} is untested. Continuing (EDGELAB_ALLOW_UNTESTED_UBUNTU=1)."
            else
                die "Ubuntu ${VERSION_ID:-?} is untested. Require 22.04 or 24.04, or set EDGELAB_ALLOW_UNTESTED_UBUNTU=1."
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
        if ! git clone --quiet --depth 1 --branch "${EDGELAB_INSTALL_REF:-main}" \
                https://github.com/izmukovvladimir-cyber/edgelab-install.git "$clone_dir"; then
            warn "Clone of branch ${EDGELAB_INSTALL_REF:-main} failed; falling back to default branch."
            rm -rf "$clone_dir"
            clone_dir=$(mktemp -d)
            TMPDIRS+=("$clone_dir")
            git clone --quiet --depth 1 \
                https://github.com/izmukovvladimir-cyber/edgelab-install.git "$clone_dir" \
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
# installed them): downloads, clones, JSON, skills rsync, as_edgelab, the
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

# check_node_for_edgelab -- warn only. No installer step needs node (Claude
# CLI is a native binary, the plugin runs on Bun); a node the agent cannot run
# (symlink into a 0700 /root) is reported, never replaced.
check_node_for_edgelab() {
    if as_edgelab node -v >/dev/null 2>&1; then
        return 0
    fi
    local where
    where=$(command -v node 2>/dev/null || echo "not on PATH")
    warn "node does not run as ${EDGELAB_USER} (${where} -> $(readlink -f "$where" 2>/dev/null || echo '?')). Left as is: the install does not need it; agents that call node will fail until it is fixed."
}

# =============================================================================
# STEP 3: CLAUDE CODE CLI
# =============================================================================

install_claude_cli() {
    step 3 "Installing Claude Code CLI (per-user for ${EDGELAB_USER})"

    local claude_bin="${EDGELAB_HOME}/.local/bin/claude"

    if [[ -x "$claude_bin" ]]; then
        ok "Claude CLI already installed at ${claude_bin}."
        # Best-effort update; never block install on update failure.
        as_edgelab "$claude_bin" update >/dev/null 2>&1 || warn "claude update non-zero; continuing."
        _ensure_path_export
        return 0
    fi

    local installer_tmp
    installer_tmp=$(mktemp)
    TMPFILES+=("$installer_tmp")

    curl "${CURL_OPTS[@]}" https://claude.ai/install.sh -o "$installer_tmp" \
        || die "Failed to download Claude Code installer."
    chmod 644 "$installer_tmp"

    # Run Anthropic's installer as edgelab so binary lands at ~/.local/bin/claude.
    as_edgelab bash "$installer_tmp"

    if [[ ! -x "$claude_bin" ]]; then
        die "Claude CLI install failed -- ${claude_bin} not found."
    fi

    local ver
    ver=$(as_edgelab "$claude_bin" --version 2>/dev/null || echo "unknown")
    ok "Claude CLI v${ver} installed at ${claude_bin}."

    _ensure_path_export
}

# Expose ~/.local/bin on edgelab's PATH for non-interactive SSH + systemd.
# .bashrc aborts on non-interactive shells, so prepend before the PS1 guard.
# .profile runs in full for login shells -- append is fine.
_ensure_path_export() {
    local marker='# Added by edgelab-install: expose ~/.local/bin'
    local export_line='export PATH="$HOME/.local/bin:$PATH"'

    local rc_entry rc placement
    for rc_entry in "${EDGELAB_HOME}/.bashrc:prepend" "${EDGELAB_HOME}/.profile:append"; do
        rc="${rc_entry%:*}"
        placement="${rc_entry##*:}"

        if [[ ! -f "$rc" ]]; then
            as_edgelab touch "$rc"
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
        install -o "$EDGELAB_USER" -g "$EDGELAB_USER" -m 0644 "$tmp" "$rc"
    done
}

# =============================================================================
# STEP 3b: BUN (runtime of the dashi-plugin channel)
# =============================================================================

install_bun() {
    step 3b "Installing Bun (per-user for ${EDGELAB_USER})"

    local bun_bin="${EDGELAB_HOME}/.bun/bin/bun"
    if [[ -x "$bun_bin" ]]; then
        ok "Bun $(as_edgelab "$bun_bin" --version 2>/dev/null || echo '?') already installed."
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

    # As edgelab, so the binary lands at ~/.bun/bin/bun (the unit PATH has it).
    as_edgelab bash "$installer_tmp" >/dev/null

    if [[ ! -x "$bun_bin" ]]; then
        die "Bun install failed -- ${bun_bin} not found."
    fi
    ok "Bun $(as_edgelab "$bun_bin" --version 2>/dev/null || echo '?') installed at ${bun_bin}."
}

# =============================================================================
# STEP 4: EDGELAB USER
# =============================================================================

ensure_edgelab_user() {
    step 4 "Ensuring '${EDGELAB_USER}' system user"

    if id -u "$EDGELAB_USER" &>/dev/null; then
        ok "User '${EDGELAB_USER}' already exists."
    else
        useradd --create-home --shell /bin/bash "$EDGELAB_USER"
        ok "User '${EDGELAB_USER}' created."
    fi

    # Make sure home is usable.
    if [[ ! -d "$EDGELAB_HOME" ]]; then
        die "Home dir ${EDGELAB_HOME} missing after useradd."
    fi
    chown "${EDGELAB_USER}:${EDGELAB_USER}" "$EDGELAB_HOME"
    chmod 0755 "$EDGELAB_HOME"
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
OPERATOR_NAME=""
OPERATOR_LANGUAGE=""
OPERATOR_TIMEZONE=""

collect_inputs() {
    step 5 "Collecting operator inputs"

    # Interactive flow (TTY present): installer asks the student for all values.
    # Non-interactive flow (EDGELAB_NONINTERACTIVE=1 or no TTY): env overrides
    # required for tokens; operator profile falls back to safe defaults.
    if ! is_noninteractive; then
        cat <<'BRIEF'

The installer will now ask a few questions. You need TWO Telegram bots ready
(create them in @BotFather beforehand) and your numeric Telegram user ID
(get it from @userinfobot). Tokens are hidden while typing.

BRIEF
    fi

    prompt_or_env OPERATOR_NAME     EDGELAB_USER_NAME  "Как к вам обращаться?"                "friend"
    prompt_or_env OPERATOR_LANGUAGE EDGELAB_LANGUAGE   "Язык общения (English / Russian / ...)" "Russian"
    prompt_or_env OPERATOR_TIMEZONE EDGELAB_TIMEZONE   "Таймзона (IANA: Europe/Moscow, Asia/Bangkok, ...)" "Europe/Moscow"

    prompt_or_env JARVIS_BOT_TOKEN  EDGELAB_JARVIS_BOT_TOKEN \
        "Jarvis bot token (from @BotFather, формат 1234567890:ABC...)" \
        "" --secret
    prompt_or_env RICHARD_BOT_TOKEN EDGELAB_RICHARD_BOT_TOKEN \
        "Richard bot token (ДРУГОЙ бот, не совпадает с Jarvis)" \
        "" --secret
    prompt_or_env TG_USER_ID        EDGELAB_TG_USER_ID \
        "Ваш Telegram numeric user ID (from @userinfobot)" \
        ""

    JARVIS_BOT_USERNAME="${EDGELAB_JARVIS_BOT_USER:-}"
    RICHARD_BOT_USERNAME="${EDGELAB_RICHARD_BOT_USER:-}"

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

    ok "Inputs collected: name=${OPERATOR_NAME}, tz=${OPERATOR_TIMEZONE}, lang=${OPERATOR_LANGUAGE}"
}

# =============================================================================
# STEP 6: INSTALL JARVIS
# =============================================================================

install_jarvis() {
    step 6 "Installing Jarvis (dashi-plugin, systemd: ${JARVIS_UNIT})"

    local wsroot="${EDGELAB_HOME}/.claude-lab/jarvis/.claude"
    local plugin_root="${wsroot}/dashi-plugin-claude-code"
    local plugin_dir="${plugin_root}/plugin"
    local state_dir="${EDGELAB_HOME}/.claude-lab/shared/state/jarvis/telegram"
    local env_file="${JARVIS_ENV_DIR}/channel.env"

    install -d -m 0755 -o "$EDGELAB_USER" -g "$EDGELAB_USER" \
        "${EDGELAB_HOME}/.claude-lab" \
        "${EDGELAB_HOME}/.claude-lab/jarvis" \
        "$wsroot" \
        "${EDGELAB_HOME}/.claude-lab/shared" \
        "${EDGELAB_HOME}/.claude-lab/shared/state"
    install -d -m 0700 -o "$EDGELAB_USER" -g "$EDGELAB_USER" \
        "${EDGELAB_HOME}/.claude-lab/shared/state/jarvis" \
        "$state_dir"

    # Full agent workspace (CLAUDE.md + core/USER.md + stub cold memory).
    # Existing files are kept, so a re-run never wipes the agent's memory.
    _write_agent_workspace "$wsroot"

    # The plugin lives inside the workspace: claude runs in plugin/ and picks
    # up the agent CLAUDE.md from the parent dirs.
    if [[ -d "${plugin_root}/.git" ]]; then
        log "Plugin repo exists -- pulling latest ${PLUGIN_REF}."
        as_edgelab git -C "$plugin_root" pull --ff-only || warn "git pull failed; continuing with existing checkout."
    else
        as_edgelab git clone --depth 1 --branch "$PLUGIN_REF" "$PLUGIN_REPO" "$plugin_root"
    fi
    [[ -f "${plugin_dir}/.mcp.json" ]] || die "Plugin checkout has no plugin/.mcp.json (${plugin_root})."
    as_edgelab env -C "$plugin_dir" "${EDGELAB_HOME}/.bun/bin/bun" install \
        || die "bun install failed in ${plugin_dir}."

    # Server that still runs the old gateway: reuse its token / allowlist.
    _collect_jarvis_channel_inputs "$env_file"

    _write_channel_env "$env_file" "$state_dir" "$wsroot"

    # Without it the folder-trust prompt sits on "No, exit", the Enter from
    # channel-confirm closes claude and the unit restarts in a loop. Both the
    # repo root (claude 2.1.x takes the git root as the project) and plugin/.
    if ! _accept_trust_dialog "${EDGELAB_HOME}/.claude.json" "$plugin_root" "$plugin_dir"; then
        warn "Could not mark ${plugin_root} as trusted in ${EDGELAB_HOME}/.claude.json -- Jarvis may stop on the trust prompt."
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
        USER           "$EDGELAB_USER" \
        HOME           "$EDGELAB_HOME" \
        PLUGIN_DIR     "$plugin_dir" \
        ENV_FILE       "$env_file" \
        CONFIRM_SCRIPT "$CHANNEL_CONFIRM_BIN" \
        START_SCRIPT   "$CHANNEL_START_BIN"
    install -m 0644 -o root -g root "$unit_tmp" "/etc/systemd/system/${JARVIS_UNIT}.service"

    fix_owner "${EDGELAB_HOME}/.claude-lab"
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
    local legacy_dir="${EDGELAB_HOME}/${LEGACY_GATEWAY_DIR_NAME}"
    local legacy_cfg="${legacy_dir}/config.json"
    local shared_groq="${EDGELAB_HOME}/.claude-lab/shared/secrets/groq-api-key"
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
# root:edgelab 0640 -- systemd reads it for the unit, the agent may read it.
_write_channel_env() {
    local env_file=$1 state_dir=$2 ws_root=$3
    local tmp
    tmp=$(mktemp)
    TMPFILES+=("$tmp")

    CHANNEL_ENV_TOKEN="$JARVIS_BOT_TOKEN" render_channel_env \
        "$env_file" "$JARVIS_ALLOWED_IDS" "$JARVIS_GROQ_KEY_FILE" "$state_dir" "$ws_root" >"$tmp" \
        || die "Could not build ${env_file}."

    install -d -m 0755 -o root -g root "$(dirname "$JARVIS_ENV_DIR")"
    install -d -m 0750 -o root -g "$EDGELAB_USER" "$JARVIS_ENV_DIR"
    install -m 0640 -o root -g "$EDGELAB_USER" "$tmp" "$env_file"
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
}
# "Allow this command?" prompts: pinned to the owner (the first id), so team
# members added to TELEGRAM_ALLOWED_USER_IDS later by hand never get them.
# A new owner answer re-pins; otherwise the pinned value is kept.
new_ids = csv(user_ids_new)
perm_ids = new_ids[0] if new_ids else (
    existing.get("TELEGRAM_PERMISSION_ALLOWED_USER_IDS", "") or (user_ids[0] if user_ids else ""))
if perm_ids:
    managed["TELEGRAM_PERMISSION_ALLOWED_USER_IDS"] = perm_ids
if groq:
    managed["GROQ_API_KEY"] = groq

for key, value in managed.items():
    if re.search(r"[\s\"'\\]", value):
        sys.exit(f"channel.env: {key} contains whitespace or quotes")

out = [
    "# Jarvis channel (dashi-plugin). Written by edgelab-install; a re-run keeps your values.",
    "# Fill the three TELEGRAM_* lines (bot token from @BotFather, your numeric id",
    "# from @userinfobot in BOTH id lines), then restart:",
    "#   sudo systemctl enable channel-jarvis && sudo systemctl restart channel-jarvis",
    "# TELEGRAM_ALLOWED_CHAT_IDS must contain your id too: without it every private",
    "# message is dropped silently. Voice needs GROQ_API_KEY=<key> (optional).",
    "# TELEGRAM_EXPECTED_BOT_ID is set at every start from the token (channel-start.sh).",
    "# Permission prompts (\"allow this command?\") go ONLY to the owner:",
    "# TELEGRAM_PERMISSION_ALLOWED_USER_IDS is set once to the first id and kept, so",
    "# team members you add to TELEGRAM_ALLOWED_USER_IDS later never get them.",
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
    as_edgelab python3 - "$@" <<'PY'
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
    backup = path.with_name(path.name + ".bak-edgelab-install")
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
    as_edgelab python3 - "$@" <<'PY'
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

    install -d -m 0755 -o "$EDGELAB_USER" -g "$EDGELAB_USER" \
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

    install -d -m 0755 -o "$EDGELAB_USER" -g "$EDGELAB_USER" "$RICHARD_HOME"

    local venv="${RICHARD_HOME}/venv"
    if [[ ! -x "${venv}/bin/python" ]]; then
        sudo -u "$EDGELAB_USER" -H -- env -C "$RICHARD_HOME" python3 -m venv "$venv"
    fi

    sudo -u "$EDGELAB_USER" -H -- env -C "$RICHARD_HOME" "${venv}/bin/pip" install --upgrade pip --quiet
    sudo -u "$EDGELAB_USER" -H -- env -C "$RICHARD_HOME" "${venv}/bin/pip" install "$RICHARD_REPO_SPEC" --quiet

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
        USER                 "$EDGELAB_USER"
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
            install -m 0600 -o "$EDGELAB_USER" -g "$EDGELAB_USER" \
                "$richard_env" "${richard_env}.bak-$(date +%Y%m%d-%H%M%S)"
        fi
        mv "$merged_tmp" "$env_tmp"
    fi
    install_as_user "$env_tmp" "$richard_env" "$EDGELAB_USER" 0600
    rm -f "$env_tmp"

    # systemd unit
    local unit_tmp
    unit_tmp=$(mktemp)
    render_template "${TEMPLATES_DIR}/claude-richard.service" "$unit_tmp" \
        USER "$EDGELAB_USER"
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

# _starter_rules_block -- prints the starter rules wrapped in the markers.
_starter_rules_block() {
    local src="${TEMPLATES_DIR}/AGENT-RULES-STARTER.md"
    [[ -f "$src" ]] || die "Template not found: $src"
    printf '\n%s\n' "$STARTER_RULES_BEGIN"
    cat "$src"
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

setup_global_claude() {
    step 8 "Setting up ${EDGELAB_HOME}/.claude/ (shared OAuth dir)"

    local claude_dir="${EDGELAB_HOME}/.claude"
    install -d -m 0700 -o "$EDGELAB_USER" -g "$EDGELAB_USER" "$claude_dir"
    install -d -m 0755 -o "$EDGELAB_USER" -g "$EDGELAB_USER" "${claude_dir}/plugins"

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

    local mcp_json="${claude_dir}/mcp.json"
    if [[ ! -f "$mcp_json" ]]; then
        local tmp
        tmp=$(mktemp)
        TMPFILES+=("$tmp")
        echo '{"mcpServers": {}}' > "$tmp"
        write_as_user "$tmp" "$mcp_json" 0644
    fi

    # Global CLAUDE.md -- loaded by every Claude Code session under edgelab user.
    # Shared by Jarvis (chat agent) and Richard (server-doctor) so Richard is
    # not blind about the owner, language, and safety rules.
    local global_claude_md="${claude_dir}/CLAUDE.md"
    if [[ ! -f "$global_claude_md" ]]; then
        local tmp
        tmp=$(mktemp)
        TMPFILES+=("$tmp")
        render_template "${TEMPLATES_DIR}/global-CLAUDE.md" "$tmp" \
            USER       "$EDGELAB_USER" \
            USER_NAME  "$OPERATOR_NAME" \
            TG_ID      "$TG_USER_ID" \
            LANGUAGE   "$OPERATOR_LANGUAGE" \
            TIMEZONE   "$OPERATOR_TIMEZONE"
        _starter_rules_block >> "$tmp"
        write_as_user "$tmp" "$global_claude_md" 0644
    else
        ensure_starter_rules "$global_claude_md"
    fi

    fix_owner "$claude_dir"
    ok "${claude_dir} ready."
}

# =============================================================================
# STEP 9: SKILLS (6 from template + 4 bundled = 10)
# =============================================================================

install_skills() {
    step 9 "Installing ${#SKILLS_FROM_TEMPLATE[@]} template + ${#SKILLS_FROM_INSTALLER[@]} bundled skills"

    local dst_parent="${EDGELAB_HOME}/.claude-lab/jarvis/.claude/skills"
    install -d -m 0755 -o "$EDGELAB_USER" -g "$EDGELAB_USER" "$dst_parent"

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
    link_skills_into_plugin "$dst_parent" "${EDGELAB_HOME}/.claude-lab/jarvis/.claude/dashi-plugin-claude-code"
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
    install -d -m 0755 -o "$EDGELAB_USER" -g "$EDGELAB_USER" "${plugin_root}/.claude"
    ln -sfnT "$skills_dir" "$link"
    chown -h "${EDGELAB_USER}:${EDGELAB_USER}" "$link" 2>/dev/null || true
    log "Skills linked into the session: ${link} -> ${skills_dir}"
}

# =============================================================================
# STEP 10: SUPERPOWERS PLUGIN
# =============================================================================

install_superpowers() {
    step 10 "Installing Superpowers plugin @ ${SUPERPOWERS_SHA:0:8}"

    local plugins_dir="${EDGELAB_HOME}/.claude/plugins"
    local sp_dir="${plugins_dir}/superpowers"
    local cfg="${plugins_dir}/config.json"

    install -d -m 0755 -o "$EDGELAB_USER" -g "$EDGELAB_USER" "$plugins_dir"

    if [[ -d "$sp_dir" ]]; then
        log "Superpowers already present -- pinning SHA."
        as_edgelab git -C "$sp_dir" fetch --depth=1 origin "$SUPERPOWERS_SHA" 2>/dev/null \
            || warn "Superpowers fetch failed -- keeping existing checkout."
        as_edgelab git -C "$sp_dir" checkout --quiet "$SUPERPOWERS_SHA" 2>/dev/null \
            || warn "Superpowers checkout of pinned SHA failed."
    else
        as_edgelab git clone --quiet --depth 1 "$SUPERPOWERS_REPO" "$sp_dir" \
            || { warn "Failed to clone Superpowers -- skipping."; return 0; }
        as_edgelab git -C "$sp_dir" fetch --depth=1 origin "$SUPERPOWERS_SHA" 2>/dev/null \
            || warn "Superpowers fetch of pinned SHA failed -- using HEAD."
        as_edgelab git -C "$sp_dir" checkout --quiet "$SUPERPOWERS_SHA" 2>/dev/null \
            || warn "Superpowers checkout of pinned SHA failed -- using HEAD."
    fi

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

# render_sudoers -- prints the sudoers file for 'edgelab' to stdout.
# apt is NOT listed: `sudo apt-get *` takes -o APT::Update::Pre-Invoke::=<cmd>
# and is full root. Package installs go through ${APT_WRAPPER_BIN} only.
render_sudoers() {
    cat <<SUDOERS
# edgelab-install v${EDGELAB_VERSION} -- passwordless sudo for 'edgelab'.
# Scope: systemctl + journalctl for the agent units, plus package installs
# through ${APT_WRAPPER_BIN} (plain package names only, no apt options).
# claude-gateway stays listed: it is the --rollback target on migrated servers.

Cmnd_Alias EDGELAB_SYSTEMCTL = \\
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

Cmnd_Alias EDGELAB_JOURNAL = \\
    /usr/bin/journalctl -u claude-gateway, \\
    /usr/bin/journalctl -u claude-gateway *, \\
    /usr/bin/journalctl -u ${JARVIS_UNIT}, \\
    /usr/bin/journalctl -u ${JARVIS_UNIT} *, \\
    /usr/bin/journalctl -u claude-richard, \\
    /usr/bin/journalctl -u claude-richard *

Cmnd_Alias EDGELAB_APT = ${APT_WRAPPER_BIN}

${EDGELAB_USER} ALL=(root) NOPASSWD: EDGELAB_SYSTEMCTL, EDGELAB_JOURNAL, EDGELAB_APT
SUDOERS
}

install_sudoers() {
    step 11 "Granting edgelab narrow passwordless sudo"

    local sudoers_file="/etc/sudoers.d/edgelab-agents"
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
    install -m 0755 -o root -g root "${TEMPLATES_DIR}/edgelab-apt-install.sh" "$APT_WRAPPER_BIN"

    install -m 0440 -o root -g root "$tmp" "$sudoers_file"
    ok "Sudoers installed at ${sudoers_file} (0440), apt only via ${APT_WRAPPER_BIN}."
}

# =============================================================================
# STEP 12: MEMORY ROTATION SCRIPTS + CRON
# =============================================================================

# Install the 5 memory-rotation scripts into the jarvis workspace and register
# them with edgelab's crontab. Matches the Day 2 self-diagnostic contract: a
# healthy agent has rotate-warm / trim-hot / compress-warm / ov-session-sync /
# memory-rotate on cron.
install_memory_cron() {
    step 12 "Installing memory-rotation scripts + cron"

    local scripts_src
    if [[ -d "${INSTALLER_ROOT}/scripts" ]]; then
        scripts_src="${INSTALLER_ROOT}/scripts"
    else
        warn "scripts/ directory missing at ${INSTALLER_ROOT} -- memory cron skipped."
        return 0
    fi

    local scripts_dst="${EDGELAB_HOME}/.claude-lab/jarvis/scripts"
    install -d -m 0755 -o "$EDGELAB_USER" -g "$EDGELAB_USER" "$scripts_dst"

    local logs_dst="${EDGELAB_HOME}/.claude-lab/jarvis/logs"
    install -d -m 0755 -o "$EDGELAB_USER" -g "$EDGELAB_USER" "$logs_dst"

    local name
    local installed=()
    local required=(trim-hot rotate-warm compress-warm ov-session-sync memory-rotate)
    for name in "${required[@]}"; do
        local src="${scripts_src}/${name}.sh"
        if [[ ! -f "$src" ]]; then
            # Day-2 self-diagnostic requires all 5 jobs on cron. A partial
            # install would leave dead cron entries pointing at missing files
            # -- fail loud so the student doesn't ship a half-wired workspace.
            err "Memory script '${name}.sh' missing at ${src} -- refusing partial install."
            return 1
        fi
        install -m 0755 -o "$EDGELAB_USER" -g "$EDGELAB_USER" "$src" "${scripts_dst}/${name}.sh"
        installed+=("$name")
    done

    # Ensure cron service is enabled + running. On minimal Ubuntu images
    # (LXC, cloud) the cron package is installed but not auto-started.
    systemctl enable --now cron 2>/dev/null \
        || warn "cron service not started -- memory rotation will run after next reboot."

    # Merge cron lines with edgelab's existing crontab without clobbering it.
    # Marker lets us update on reinstall instead of duplicating entries.
    local marker="# edgelab-install v${EDGELAB_VERSION}: memory rotation"
    local cron_block
    # CRON_TZ pins the schedule to UTC so the Day-2 diagnostic contract
    # (04:30/05:00/06:00/06:30/21:00 UTC) fires at the same wall-clock moment
    # regardless of the host's system timezone. HOME= is set because scripts
    # rely on $HOME under `set -u`; on some minimal images cron does not
    # always export HOME to the user's actual home directory.
    cron_block=$(cat <<CRON
${marker}
CRON_TZ=UTC
HOME=${EDGELAB_HOME}
30 4 * * * ${scripts_dst}/rotate-warm.sh >> ${logs_dst}/memory-cron.log 2>&1
0 5 * * *  ${scripts_dst}/trim-hot.sh >> ${logs_dst}/memory-cron.log 2>&1
0 6 * * *  ${scripts_dst}/compress-warm.sh >> ${logs_dst}/memory-cron.log 2>&1
30 6 * * * ${scripts_dst}/ov-session-sync.sh >> ${logs_dst}/memory-cron.log 2>&1
0 21 * * * ${scripts_dst}/memory-rotate.sh >> ${logs_dst}/memory-cron.log 2>&1
# edgelab-install memory rotation end
CRON
)

    local current_tmp new_tmp
    current_tmp=$(mktemp)
    new_tmp=$(mktemp)
    TMPFILES+=("$current_tmp" "$new_tmp")

    # Fetch current crontab (empty is fine on first run).
    crontab -u "$EDGELAB_USER" -l 2>/dev/null > "$current_tmp" || true

    # Strip any previous managed block so we can re-insert the current one.
    python3 - "$current_tmp" "$new_tmp" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src, encoding='utf-8') as f:
    text = f.read()
cleaned = re.sub(
    r'# edgelab-install v[0-9.]+: memory rotation.*?# edgelab-install memory rotation end\n?',
    '',
    text,
    flags=re.DOTALL,
)
open(dst, 'w', encoding='utf-8').write(cleaned.rstrip() + ('\n' if cleaned.strip() else ''))
PY

    # Append new block.
    printf '%s\n' "$cron_block" >> "$new_tmp"

    if ! crontab -u "$EDGELAB_USER" "$new_tmp" 2>/dev/null; then
        err "Failed to install crontab for ${EDGELAB_USER} -- memory rotation will not run. Day-2 self-diagnostic will flag this as a failure."
        return 1
    fi

    # Verify the block actually landed so a silent crontab discard doesn't slip through.
    if ! crontab -u "$EDGELAB_USER" -l 2>/dev/null | grep -q "edgelab-install memory rotation end"; then
        err "crontab accepted the file but memory-rotation block is not visible on read-back."
        return 1
    fi

    ok "Memory cron installed: ${installed[*]}"
}

# =============================================================================
# STEP 13: SYSTEMD ENABLE (do not start yet -- OAuth + tokens required first)
# =============================================================================

enable_services() {
    step 13 "Enabling systemd services (and starting if OAuth is already set up)"

    systemctl daemon-reload

    local oauth_ready="no"
    if [[ -f "${EDGELAB_HOME}/.claude/.credentials.json" ]]; then
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
            log "${JARVIS_UNIT} enabled -- will start after OAuth under edgelab."
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
            log "claude-richard enabled -- will start after OAuth under edgelab."
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
    local legacy_dir="${EDGELAB_HOME}/${LEGACY_GATEWAY_DIR_NAME}"
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
    if [[ -d "$legacy_dir" ]] && ! tar -C "$EDGELAB_HOME" --exclude="${LEGACY_GATEWAY_DIR_NAME}/.venv" \
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

final_instructions() {
    local jarvis_label="@${JARVIS_BOT_USERNAME:-<fill-in>}"
    local richard_label="@${RICHARD_BOT_USERNAME:-<fill-in>}"
    local tokens_filled="no"
    if [[ -n "$JARVIS_BOT_TOKEN" && -n "$RICHARD_BOT_TOKEN" && -n "$TG_USER_ID" ]]; then
        tokens_filled="yes"
    fi

    cat <<EOF

$(printf '%b' "$C_GREEN")================================================================================
  edgelab-install v${EDGELAB_VERSION} complete.  Agent-native flow: the root-Claude
  agent will configure the rest.  Do NOT run commands by hand below.
================================================================================$(printf '%b' "$C_NC")

Installed on this VPS:
  - User:      ${EDGELAB_USER} (${EDGELAB_HOME})
  - Claude:    ${EDGELAB_HOME}/.local/bin/claude  (per-user, on PATH)
  - Jarvis:    ${EDGELAB_HOME}/.claude-lab/jarvis/.claude/dashi-plugin-claude-code  (systemd: ${JARVIS_UNIT})
               env: ${JARVIS_ENV_DIR}/channel.env
  - Richard:   ${RICHARD_HOME}                       (systemd: claude-richard)
  - Skills:    ${EDGELAB_HOME}/.claude-lab/jarvis/.claude/skills/  (10 skills)
  - Plugin:    ${EDGELAB_HOME}/.claude/plugins/superpowers/
  - Sudoers:   /etc/sudoers.d/edgelab-agents  (narrow, 0440)

$(printf '%b' "$C_BOLD")Tokens filled during install:$(printf '%b' "$C_NC") ${tokens_filled}

$(printf '%b' "$C_BOLD")NEXT STEPS -- these are for the root-Claude agent, not the student:$(printf '%b' "$C_NC")

  $(printf '%b' "$C_YELLOW")1.$(printf '%b' "$C_NC") One-time Anthropic OAuth under edgelab (interactive -- opens browser):

        sudo -u ${EDGELAB_USER} -i bash -lc 'claude auth login'

      Credentials land in ${EDGELAB_HOME}/.claude/ and are shared by both agents.

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
        sudo -u ${EDGELAB_USER} tmux -L ${JARVIS_UNIT} capture-pane -p -t ${JARVIS_UNIT} | tail -30   # Jarvis screen

      Undo the switch to the plugin (servers that had claude-gateway):

        sudo bash install.sh --rollback

  $(printf '%b' "$C_YELLOW")3.$(printf '%b' "$C_NC") Smoke-checks:

        id ${EDGELAB_USER}                                      # uid >= 1000
        node -v                                                 # v22+
        python3 --version                                       # 3.12+
        sudo -u ${EDGELAB_USER} bash -lc 'which claude'         # ${EDGELAB_HOME}/.local/bin/claude
        ls ${EDGELAB_HOME}/.claude-lab/jarvis/.claude/          # CLAUDE.md, core/, skills/
        systemctl is-active ${JARVIS_UNIT}                       # active (after steps 1+2)
        systemctl is-active claude-richard                      # active (after steps 1+2)
        ls -la /etc/sudoers.d/edgelab-agents                    # exists, 0440
        ls ${EDGELAB_HOME}/.claude-lab/jarvis/.claude/skills/ | wc -l   # 10
        ls ${EDGELAB_HOME}/.claude/plugins/superpowers/skills/ 2>/dev/null | wc -l

  $(printf '%b' "$C_YELLOW")4.$(printf '%b' "$C_NC") Student talks to Jarvis in Telegram: ${jarvis_label}
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
    ensure_edgelab_user
    check_node_for_edgelab
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
    enable_services
    final_instructions
}

# Tests source this file with INSTALL_SH_SOURCED_FOR_TESTING=1 to reach helpers.
if [[ "${INSTALL_SH_SOURCED_FOR_TESTING:-0}" != "1" ]]; then
    main "$@"
fi
