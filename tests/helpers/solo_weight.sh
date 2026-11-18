#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329  # globals read by sourced install.sh functions, overrides
# Weight of what a clean install puts into EVERY turn of the main agent, measured on the real
# installer functions in a sandbox (no root, no network): the global ~/.claude/CLAUDE.md, the
# agent CLAUDE.md with every nested @include, project rules (plugin/.claude/rules) and the
# auto-memory MEMORY.md head -- the same set lib/include_weight.py turn_weight() counts.
#
# Usage: bash tests/helpers/solo_weight.sh [--full] [--payload DIR] [--keep DIR]
#   default  --solo install; the soul is a filler of SOUL_FILLER_BYTES (the real one is closed and
#            not in git), wired by the installer's own azv_wire_payload;
#   --payload DIR   the real unlocked payload (DIR/soul/*.md) instead of the filler;
#   --full   the team install (SOLO=0), for comparison;
#   --keep DIR      build the sandbox in DIR and leave it there.
# Prints one line per file (bytes, path relative to the sandbox home) and the last line
# "TOTAL <bytes>".
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Real soul on 18.11.2026: CLAUDE.md + character.md + rules.md + morning-brief.md = 7590 bytes (7947 with
# the #1920 memory/idea lines); the filler is the budget for it.
SOUL_FILLER_BYTES=8192
solo=1 payload="" keep=""
while (($#)); do
    case "$1" in
        --full) solo=0 ;;
        --payload) payload=$2; shift ;;
        --keep) keep=$2; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

if [[ -n "$keep" ]]; then
    TDIR="$keep"
    mkdir -p "$TDIR"
else
    TDIR="$(mktemp -d)"
    trap 'rm -rf "${TDIR:?}"' EXIT
fi

export INSTALL_SH_SOURCED_FOR_TESTING=1
export NEUROOTDEL_TEMPLATES_DIR="${REPO}/templates"
cp "${REPO}/install.sh" "${TDIR}/install.sh"
# shellcheck disable=SC1091
source "${TDIR}/install.sh"
set +e
H="${TDIR}/home"
WS="${H}/.claude-lab/jarvis/.claude"
AGENT_HOME="$H"
AGENT_USER="$(id -un)"
AZV_AGENT_DIR="${WS}/azv"
GUARD_LIB_DIR="${TDIR}/lib"
INSTALLER_ROOT="$REPO"
TEMPLATES_DIR="${REPO}/templates"
SOLO=$solo
OPERATOR_NAME="Анна"
TG_USER_ID="42"
OPERATOR_LANGUAGE="ru"
OPERATOR_TIMEZONE="Europe/Moscow"
MAIN_AGENT_NAME="Jarvis"
CODER_INSTALLED=0
install() {
    local a=() skip=0 x
    for x in "$@"; do
        if ((skip)); then skip=0; continue; fi
        case "$x" in -o|-g) skip=1 ;; *) a+=("$x") ;; esac
    done
    command install "${a[@]}"
}
fix_owner() { :; }
as_agent() { "$@"; }
write_as_user() { mkdir -p "$(dirname "$2")"; command install -m "${3:-0644}" "$1" "$2"; }
step() { :; }
ok() { :; }
log() { :; }
warn() { printf 'warn: %s\n' "$*" >&2; }
err() { printf 'err: %s\n' "$*" >&2; }

mkdir -p "$H" "${WS}/dashi-plugin-claude-code/.git" "${WS}/dashi-plugin-claude-code/plugin"

# The install order of main(): workspace (install_jarvis), global CLAUDE.md, payload, team refs.
_write_agent_workspace "$WS" >/dev/null || { echo "workspace failed" >&2; exit 1; }
setup_global_claude >/dev/null || { echo "global CLAUDE.md failed" >&2; exit 1; }
if [[ "$solo" == 1 ]]; then
    if [[ -n "$payload" ]]; then
        mkdir -p "$AZV_AGENT_DIR"
        cp -r "${payload}/." "$AZV_AGENT_DIR/"
    else
        mkdir -p "${AZV_AGENT_DIR}/soul"
        printf '# soul\n@rules.md\n@character.md\n' >"${AZV_AGENT_DIR}/soul/CLAUDE.md"
        for f in rules character morning-brief; do
            head -c $(( (SOUL_FILLER_BYTES - 30) / 3 )) /dev/zero | tr '\0' 'x' >"${AZV_AGENT_DIR}/soul/${f}.md"
        done
    fi
    azv_wire_payload >/dev/null || { echo "payload wiring failed" >&2; exit 1; }
fi
install_team_refs >/dev/null || { echo "team refs failed" >&2; exit 1; }

HOME="$H" PYTHONPATH="${REPO}/lib" python3 - "$H" <<'PY'
import sys
from pathlib import Path

import include_weight as iw

home = Path(sys.argv[1])
tw = iw.turn_weight(home / ".claude-lab" / "jarvis", config_dir=home / ".claude", home=home)
for r in sorted(tw.rows, key=lambda r: -r.size):
    print(f"{r.size:7d}  {Path(r.name).resolve().relative_to(home.resolve())}")
print(f"TOTAL {tw.total}")
PY
