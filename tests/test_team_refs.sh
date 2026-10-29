#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329  # globals read by sourced fns, overrides
# install_team_refs: team rules (managed) + the @-line between markers, references,
# code style rules, memory layout (written once, owner's afterwards). No root needed.
# Run: bash tests/test_team_refs.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TDIR="$(mktemp -d)"
trap 'rm -rf "${TDIR:?}"' EXIT

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

export INSTALL_SH_SOURCED_FOR_TESTING=1
export NEUROOTDEL_TEMPLATES_DIR="${REPO}/templates"
# shellcheck disable=SC1091
source "${REPO}/install.sh"
set +e
write_as_user() { mkdir -p "$(dirname "$2")"; install -m "${3:-0644}" "$1" "$2"; }
as_agent() { "$@"; }
step() { :; }
ok() { :; }
warn() { :; }
err() { :; }

H="${TDIR}/home"
WS="${H}/.claude-lab/jarvis/.claude"
SH="${H}/.claude-lab/shared"
AGENT_HOME="$H"
AGENT_USER=neurootdel
GUARD_LIB_DIR=/usr/local/lib/neurootdel
OPERATOR_NAME="Анна"
TEMPLATES_DIR="${REPO}/templates"
mkdir -p "$WS"
printf '# Jarvis\n\nowner text\n@core/USER.md\n' >"${WS}/CLAUDE.md"
MEM="${H}/.claude/projects/$(printf '%s' "${WS}/dashi-plugin-claude-code" | sed 's/[^A-Za-z0-9]/-/g')/memory"

install_team_refs; rc=$?
check "refs: rc 0"                            test "$rc" -eq 0
for f in team-rules STAFF AGENTS TOOLS PARALLEL-AGENTS LEARNINGS LESSONS-STARTER; do
    check "refs: shared/${f}.md"              test -s "${SH}/${f}.md"
done
check "refs: placeholders filled"             bash -c '! grep -l "{{" "$0"/*.md' "$SH"
LS="${SH}/LESSONS-STARTER.md"
nl=$(grep -cE '^## [0-9]+\. ' "$LS")
check "lessons: 12-20 lessons"               test "$nl" -ge 12 -a "$nl" -le 20
check "lessons: each has rule/why/how"       test "$(grep -c '^Правило: ' "$LS")" -eq "$nl" -a "$(grep -c '^Почему: ' "$LS")" -eq "$nl" -a "$(grep -c '^Как: ' "$LS")" -eq "$nl"
check "lessons: == template"                 cmp -s "$LS" "${REPO}/templates/shared/LESSONS-STARTER.md"
check "lessons: in team-rules references"    grep -qF 'LESSONS-STARTER.md' "${SH}/team-rules.md"
check "lessons: generic (no ids/IPs/@/\$)"   bash -c '! grep -qE "[0-9]{6,}|([0-9]{1,3}\.){3}[0-9]{1,3}|@|\\\$|/home/|t\.me/" "$0"' "${REPO}/templates/shared/LESSONS-STARTER.md"
check "refs: owner name in team rules"        grep -q 'Owner = Анна' "${SH}/team-rules.md"
check "refs: lib path in team rules"          grep -q '/usr/local/lib/neurootdel/include_weight.py' "${SH}/team-rules.md"
for f in bash python typescript; do
    check "refs: code rule ${f}.md"           test -s "${H}/.claude/rules/${f}.md"
done
for f in MEMORY index-work index-people index-content index-infra; do
    check "refs: memory ${f}.md"              test -s "${MEM}/${f}.md"
done
check "refs: library index"                   test -s "${WS}/library/INDEX.md"
check "refs: core/archive dir"                test -d "${WS}/core/archive"
check "refs: @ line between markers"          grep -qx '@~/.claude-lab/shared/team-rules.md' "${WS}/CLAUDE.md"
check "refs: BEGIN marker"                    grep -qx "<!-- BEGIN ${INSTALL_TAG}: team-rules -->" "${WS}/CLAUDE.md"
check "refs: owner text kept"                 grep -qx 'owner text' "${WS}/CLAUDE.md"
check "refs: no names of ours in templates"   bash -c '! grep -rliE "svetlan|светлан|vladimir|владимир|edgelab|nikolai|николай|gosteva" "$0"/templates/shared "$0"/templates/memory "$0"/templates/rules' "$REPO"

# Re-run: owner's edits outside markers and in owner files survive, the block is not doubled.
echo '- my own staff line' >>"${SH}/STAFF.md"
echo '## 21. my own lesson' >>"${SH}/LESSONS-STARTER.md"
echo '- [my rule](feedback-x.md)' >>"${MEM}/MEMORY.md"
echo 'my rule' >>"${H}/.claude/rules/bash.md"
echo 'after the block' >>"${WS}/CLAUDE.md"
sha_before=$(sha256sum "${SH}/LESSONS-STARTER.md" "${SH}/STAFF.md" "${MEM}/MEMORY.md" "${H}/.claude/rules/bash.md" | sha256sum)
echo 'stale managed text' >>"${SH}/team-rules.md"
install_team_refs
sha_after=$(sha256sum "${SH}/LESSONS-STARTER.md" "${SH}/STAFF.md" "${MEM}/MEMORY.md" "${H}/.claude/rules/bash.md" | sha256sum)
check "rerun: owner files untouched"          test "$sha_before" = "$sha_after"
check "rerun: team rules refreshed"           bash -c '! grep -q "stale managed text" "$0"' "${SH}/team-rules.md"
check "rerun: one block only"                 test "$(grep -c "BEGIN ${INSTALL_TAG}: team-rules" "${WS}/CLAUDE.md")" -eq 1
check "rerun: text after block kept"          grep -qx 'after the block' "${WS}/CLAUDE.md"
cp "${WS}/CLAUDE.md" "${TDIR}/c1"
install_team_refs
check "rerun: CLAUDE.md unchanged 3rd run"    cmp -s "${WS}/CLAUDE.md" "${TDIR}/c1"

# Block body inside markers is replaced, text around it stays byte for byte.
python3 - "${WS}/CLAUDE.md" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
p.write_text(s.replace("@~/.claude-lab/shared/team-rules.md", "@~/old/path.md"))
PY
install_team_refs
check "block: old body replaced"              bash -c '! grep -q "old/path" "$0"' "${WS}/CLAUDE.md"
check "block: file equals the clean state"    cmp -s "${WS}/CLAUDE.md" "${TDIR}/c1"

# BEGIN without END: left alone, nonzero.
printf 'x\n<!-- BEGIN %s: team-rules -->\nowner\n' "$INSTALL_TAG" >"${TDIR}/broken.md"
cp "${TDIR}/broken.md" "${TDIR}/broken.orig"
if _ensure_marked_block "${TDIR}/broken.md" team-rules "@a"; then b_rc=0; else b_rc=$?; fi
check "block: BEGIN without END -> nonzero"   test "$b_rc" -ne 0
check "block: broken file untouched"          cmp -s "${TDIR}/broken.md" "${TDIR}/broken.orig"

# Bytes outside the block: CRLF and trailing blank lines survive an append.
printf 'a\r\nb\r\n\r\n\r\n' >"${TDIR}/crlf.md"
_ensure_marked_block "${TDIR}/crlf.md" team-rules "@x"
check "bytes: CRLF prefix kept"               test "$(head -c 10 "${TDIR}/crlf.md" | od -An -c | tr -s ' ')" = "$(printf 'a\r\nb\r\n\r\n\r\n' | od -An -c | tr -s ' ')"
check "bytes: block uses CRLF too"            grep -q $'^@x\r$' "${TDIR}/crlf.md"
printf 'no newline at end' >"${TDIR}/nonl.md"
_ensure_marked_block "${TDIR}/nonl.md" team-rules "@x"
check "bytes: text without final newline kept" test "$(head -n 1 "${TDIR}/nonl.md")" = "no newline at end"

# Ambiguous markers: two BEGINs, END before BEGIN, inline marker -> untouched, nonzero.
for body in 'B\nown\nB\nx\nE\n' 'E\nown\nB\n' 'say B inline\n'; do
    f="${TDIR}/amb.md"
    printf "$(printf '%s' "$body" | sed "s/B/<!-- BEGIN ${INSTALL_TAG}: team-rules -->/g; s/E/<!-- END ${INSTALL_TAG}: team-rules -->/g")" >"$f"
    cp "$f" "${f}.orig"
    if _ensure_marked_block "$f" team-rules "@a"; then a_rc=0; else a_rc=$?; fi
    check "ambiguous: $(printf '%s' "$body" | tr '\n' ' ') -> nonzero, untouched" bash -c '[[ "$0" -ne 0 ]] && cmp -s "$1" "$1.orig"' "$a_rc" "$f"
done

# Symlinks: CLAUDE.md -> elsewhere is not followed, a symlinked target is not written.
echo secret >"${TDIR}/outside"
ln -s "${TDIR}/outside" "${TDIR}/link.md"
if _ensure_marked_block "${TDIR}/link.md" team-rules "@a"; then l_rc=0; else l_rc=$?; fi
check "symlink: block refuses a symlink"      test "$l_rc" -ne 0
check "symlink: target untouched"             test "$(cat "${TDIR}/outside")" = secret
ln -s "${TDIR}/outside" "${SH}/team-rules.md.l"
rm -f "${SH}/team-rules.md"; mv "${SH}/team-rules.md.l" "${SH}/team-rules.md"
if install_team_refs; then s_rc=0; else s_rc=$?; fi
check "symlink: managed write refuses"        test "$s_rc" -ne 0
check "symlink: managed target untouched"     test "$(cat "${TDIR}/outside")" = secret

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
