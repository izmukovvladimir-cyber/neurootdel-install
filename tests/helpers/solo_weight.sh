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
# As a live install sees it (#1920): the activation server watermarks every .md of the payload
# (bin/agent-activate.py watermark(): two lines with the buyer's name and key, ~214 B per file on the stand),
# and the plugin's own CLAUDE.md (channel rule, 1541 B at PLUGIN_COMMIT_DEFAULT d846493) loads from the
# agent's working dir. The name is a long-ish buyer name, the key has the real AZV-XXXX-XXXX-XXXX-XXXX shape.
WM_NAME="Мария Константинова"
WM_KEY="AZV-ABCD-EFGH-JKLM-NPQR"
PLUGIN_CLAUDE_BYTES=1541
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
    python3 - "${AZV_AGENT_DIR}" "$WM_NAME" "$WM_KEY" <<'WM'
import sys
from pathlib import Path

root, name, key = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
head = (f"<!-- Личная копия: {name}. Ключ {key}. -->\n"
        f"> Личная копия для {name}, ключ {key}. Передавать другим нельзя.\n\n")
for p in root.rglob("*.md"):
    t = p.read_text(encoding="utf-8")
    end = t.find("\n---\n", 4) if t.startswith("---\n") else -1
    if end != -1:
        cut = end + len("\n---\n")
        t = t[:cut] + "\n" + head + t[cut:]
    else:
        t = head + t
    p.write_text(t, encoding="utf-8")
WM
    azv_wire_payload >/dev/null || { echo "payload wiring failed" >&2; exit 1; }
fi
install_team_refs >/dev/null || { echo "team refs failed" >&2; exit 1; }
head -c "$PLUGIN_CLAUDE_BYTES" /dev/zero | tr '\0' 'p' >"${WS}/dashi-plugin-claude-code/plugin/CLAUDE.md"

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
