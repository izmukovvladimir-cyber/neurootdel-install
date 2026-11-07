#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329  # globals read by sourced fns, overrides
# Starter lessons in auto memory: templates/memory/feedback-*.md (shape, index line, no private
# traces) and _install_memory_layout (notes land once, the index block in MEMORY.md is managed).
# Run: bash tests/test_memory_lessons.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TDIR="$(mktemp -d)"
trap 'rm -rf "${TDIR:?}"' EXIT
M="${REPO}/templates/memory"
IDX="${M}/lessons-index.md"
TIDX="${M}/lessons-index-tools.md"

PASS=0
FAIL=0
check() {
    local name=$1; shift
    if "$@"; then
        PASS=$((PASS + 1)); printf 'ok   %s\n' "$name"
    else
        FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$name" >&2
    fi
}

# --- the notes themselves ---------------------------------------------------------------------
shopt -s nullglob
notes=("$M"/feedback-*.md)
shopt -u nullglob
n=${#notes[@]}
check "notes: 60-150 lessons ($n)"            test "$n" -ge 60 -a "$n" -le 150
bad_shape=0 bad_index=0
for f in "${notes[@]}"; do
    b=$(basename "$f" .md)
    head -1 "$f" | grep -qx -- '---' || { echo "  no frontmatter: $b" >&2; bad_shape=1; }
    grep -qx "name: ${b}" "$f" || { echo "  name != file: $b" >&2; bad_shape=1; }
    grep -q '^description: .\+' "$f" || { echo "  no description: $b" >&2; bad_shape=1; }
    grep -qx '  type: feedback' "$f" || { echo "  no metadata.type feedback: $b" >&2; bad_shape=1; }
    grep -q '^\*\*Why:\*\* .\+' "$f" || { echo "  no Why: $b" >&2; bad_shape=1; }
    grep -q '^\*\*How to apply:\*\* .\+' "$f" || { echo "  no How to apply: $b" >&2; bad_shape=1; }
    [[ "$(cat "$IDX" "$TIDX" | grep -cF "](${b}.md)")" -eq 1 ]] || { echo "  not exactly once in index: $b" >&2; bad_index=1; }
done
check "notes: frontmatter + Why + How"        test "$bad_shape" -eq 0
check "notes: each has one index line"        test "$bad_index" -eq 0
dangling=0
while IFS= read -r link; do
    [[ -f "${M}/${link}" ]] || { echo "  dangling: $link" >&2; dangling=1; }
done < <(grep -hoE '\]\(feedback-[a-z0-9-]+\.md\)' "$IDX" "$TIDX" | sed 's/^](//; s/)$//')
check "index: no dangling links"              test "$dangling" -eq 0
check "index: no marker text inside"          bash -c '! grep -q "<!--" "$0" "$1"' "$IDX" "$TIDX"
check "index: MEMORY points to index-infra"   grep -qF 'index-infra.md' "$IDX"

# Private traces of the source team: names, handles, ids, hosts, paths, keys.
PRIV='Владимир|Даш|Маркус|Ирин|Натал|Светлан|Корягин|Лес[яиеюь]|Лёс|Александр|Евген|Татьян|Надежд|Вик[аиуо]|Виктори|Мирослав|Юл[яиеюь]|Николай|Герман|Ричард|Эдит|Лиз[аиеуы]|Артур|Алан|Марго|Карин|edgelab|vladimir|izhmukov|izmukov|reelsmentor|62\.60\.|147\.45\.|176\.124\.|159\.194\.|@|chat_id|msg |t\.me/|sk-[A-Za-z0-9]|ghp_|github_pat_|[A-Za-z0-9+/]{40,}|([0-9]{1,3}\.){3}[0-9]{1,3}|/home/|[0-9]{6,}|daria|dasha|markus|jarvis|koder|richard|hermes|neurootdel|gosteva|svetlana'
hits=$(grep -nHiE "$PRIV" "${notes[@]}" "$IDX" "$TIDX" "${M}/MEMORY.md" "${M}/index-infra.md" || true)
[[ -z "$hits" ]] || printf '%s\n' "$hits" >&2
check "privacy: 0 hits"                       test -z "$hits"

# --- install: notes land, the index block is managed ------------------------------------------
export INSTALL_SH_SOURCED_FOR_TESTING=1
export NEUROOTDEL_TEMPLATES_DIR="${REPO}/templates"
# shellcheck disable=SC1091
source "${REPO}/install.sh"
set +e
as_agent() { "$@"; }
step() { :; }
ok() { :; }
warn() { :; }
err() { :; }
AGENT_HOME="${TDIR}/home"
AGENT_USER=neurootdel
TEMPLATES_DIR="${REPO}/templates"
MEM="${TDIR}/mem"
mkdir -p "$MEM"

_install_memory_layout "$MEM"; rc=$?
check "install: rc 0"                         test "$rc" -eq 0
copied=0
for f in "${notes[@]}"; do cmp -s "$f" "${MEM}/$(basename "$f")" && copied=$((copied + 1)); done
check "install: all $n notes copied"          test "$copied" -eq "$n"
B="<!-- BEGIN ${INSTALL_TAG}: memory-lessons -->"
E="<!-- END ${INSTALL_TAG}: memory-lessons -->"
block() { sed -n "\|^${B}\$|,\|^${E}\$|p" "${MEM}/MEMORY.md" | sed '1d;$d'; }
TB="<!-- BEGIN ${INSTALL_TAG}: memory-lessons-tools -->"
TE="<!-- END ${INSTALL_TAG}: memory-lessons-tools -->"
tblock() { sed -n "\|^${TB}\$|,\|^${TE}\$|p" "${MEM}/index-infra.md" | sed '1d;$d'; }
check "install: block == lessons-index"       cmp -s <(block) "$IDX"
check "install: tools block == tools index"   cmp -s <(tblock) "$TIDX"
check "install: no {{TAG}} left"              bash -c '! grep -q "{{" "$0" "$1"' "${MEM}/MEMORY.md" "${MEM}/index-infra.md"
wr=$(grep -n '^## Working rules' "${MEM}/MEMORY.md" | cut -d: -f1)
ti=$(grep -n '^## Topic indexes' "${MEM}/MEMORY.md" | cut -d: -f1)
bl=$(grep -nxF "$B" "${MEM}/MEMORY.md" | cut -d: -f1)
check "install: block inside Working rules"   test "$wr" -lt "$bl" -a "$bl" -lt "$ti"
sz=$(wc -c <"${MEM}/MEMORY.md")
check "install: MEMORY.md <= 12 KB ($sz)"     test "$sz" -le 12288
for f in index-work index-people index-content index-infra; do
    check "install: ${f}.md"                  test -s "${MEM}/${f}.md"
done
check "install: lessons-index not deployed"   test ! -e "${MEM}/lessons-index.md" -a ! -e "${MEM}/lessons-index-tools.md"

# Re-run: owner's rule line and an edited lesson survive, the block is not doubled.
first=$(basename "${notes[0]}")
echo 'owner edit' >>"${MEM}/${first}"
sed -i "/^${B}\$/i - [my own rule](feedback-mine.md)" "${MEM}/MEMORY.md"
_install_memory_layout "$MEM"; rc=$?
check "rerun: rc 0"                           test "$rc" -eq 0
check "rerun: one block"                      test "$(grep -cxF "$B" "${MEM}/MEMORY.md")" -eq 1
check "rerun: owner rule kept"                grep -qF '(feedback-mine.md)' "${MEM}/MEMORY.md"
check "rerun: edited lesson kept"             grep -qx 'owner edit' "${MEM}/${first}"
check "rerun: block still == index"           cmp -s <(block) "$IDX"
check "rerun: one tools block"                test "$(grep -cxF "$TB" "${MEM}/index-infra.md")" -eq 1

# An older install: MEMORY.md without markers gets the block appended, its own text kept.
OLD="${TDIR}/old"
mkdir -p "$OLD"
printf '# Memory index\n\n## Working rules (always in force)\n\n- [old](feedback-old.md) - x\n' >"${OLD}/MEMORY.md"
printf '# Agents, server, infrastructure\n\n- [my server](reference-mine.md) - x\n' >"${OLD}/index-infra.md"
_install_memory_layout "$OLD"; rc=$?
_install_memory_layout "$OLD"; rc2=$?
check "old: rc 0 twice"                       test "$rc" -eq 0 -a "$rc2" -eq 0
check "old: own line kept"                    grep -qF '(feedback-old.md)' "${OLD}/MEMORY.md"
check "old: own infra line kept"              grep -qF '(reference-mine.md)' "${OLD}/index-infra.md"
check "old: block appended once"              test "$(grep -cxF "$B" "${OLD}/MEMORY.md")" -eq 1
check "old: tools block appended once"        test "$(grep -cxF "$TB" "${OLD}/index-infra.md")" -eq 1
MEM="$OLD"
check "old: block == index"                   cmp -s <(block) "$IDX"
check "old: tools block == tools index"       cmp -s <(tblock) "$TIDX"
check "old: notes copied"                     test -f "${OLD}/${first}"

# A missing lessons index: rc 1 and the managed block is NOT emptied.
FAKE="${TDIR}/tpl"
cp -r "${REPO}/templates" "$FAKE"
rm -f "${FAKE}/memory/lessons-index.md"
TEMPLATES_DIR="$FAKE"
_install_memory_layout "$OLD"; rc=$?
TEMPLATES_DIR="${REPO}/templates"
check "no index: rc 1"                        test "$rc" -eq 1
check "no index: block kept"                  cmp -s <(block) "$IDX"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
