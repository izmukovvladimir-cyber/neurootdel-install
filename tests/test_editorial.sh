#!/usr/bin/env bash
# Tests for the editorial loop: skills/codex-check/scripts/codex-check.sh (strict verdict parsing, off by
# default, no Codex login = DISABLED), lib/text-critics.sh (paths from editorial.conf, refusals before any
# model call, both critics must APPROVE) and the installer wiring. No model, no network: a fake `codex`.
# Run: bash tests/test_editorial.sh
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CC="${REPO}/skills/codex-check/scripts/codex-check.sh"
TC="${REPO}/lib/text-critics.sh"
TDIR="$(mktemp -d)"
trap 'rm -rf "${TDIR:?}"' EXIT

PASS=0; FAIL=0
check() {
    local name=$1; shift
    if "$@"; then PASS=$((PASS + 1)); printf 'ok   %s\n' "$name"
    else FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$name" >&2; fi
}

H="${TDIR}/home"
mkdir -p "${H}/.local/bin" "${H}/.codex" "${H}/.claude-lab/shared/checklists"
CONF="${H}/.claude-lab/shared/editorial.conf"
# Fake codex: logs each call; the reply goes to the file after -o. FAKE_REPLY = fixed reply;
# otherwise an editor prompt gets FAKE_EDITOR and any other prompt FAKE_PROOF.
cat >"${H}/.local/bin/codex" <<'F'
#!/usr/bin/env bash
in="$(cat)"
echo "call $*" >>"$HOME/codex-calls"
printf '%s' "$in" >"$HOME/last-prompt-$$"
while [[ $# -gt 0 ]]; do
    if [[ "$1" == "-o" ]]; then
        if [[ -n "${FAKE_REPLY:-}" ]]; then cp "$FAKE_REPLY" "$2"
        elif grep -q 'главный редактор' <<<"$in"; then printf '%s' "$FAKE_EDITOR" >"$2"
        else printf '%s' "$FAKE_PROOF" >"$2"; fi
    fi
    shift
done
F
chmod +x "${H}/.local/bin/codex"
echo '{"tokens":"x"}' >"${H}/.codex/auth.json"
on()  { printf 'EDITORIAL_ENABLED=1\nCODEX_CHECK_MODEL=%s\nCODEX_CHECK_BIN=%s\nTEXT_STANDARD=~/.claude-lab/shared/checklists/text-standard.md\nCRITICS_CONTEXT=Канал о садоводстве для дачников\n' "${1-}" "$CC" >"$CONF"; }
calls() { [[ -f "${H}/codex-calls" ]] && wc -l <"${H}/codex-calls" || echo 0; }
export HOME="$H" EDITORIAL_CONF="$CONF"
unset CODEX_HOME CODEX_CHECK_MODEL

check "syntax: codex-check"  bash -n "$CC"
check "syntax: text-critics" bash -n "$TC"
check "codex-check executable"  test -x "$CC"
check "text-critics executable" test -x "$TC"

# --- off by default: the installer's conf -> DISABLED, no model call ----------------------------------
sed "s/{{USER}}/agent/" "${REPO}/templates/editorial.conf" >"$CONF"
OUT=$(echo 'материал' | bash "$CC" || echo "rc=$?")
check "default conf: DISABLED"            grep -q '^codex: model=default verdict=DISABLED' <<<"$OUT"
check "default conf: exit 3"              grep -qx 'rc=3' <<<"$OUT"
OUT=$(bash "$TC" "$CONF" 2>&1 || echo "rc=$?")
check "critics off: exit 3"               grep -qx 'rc=3' <<<"$OUT"
check "critics off: says how to enable"   grep -q 'EDITORIAL_ENABLED=1' <<<"$OUT"
check "off: codex never called"           test "$(calls)" -eq 0
rm -f "$CONF"
OUT=$(echo 'материал' | bash "$CC" || echo "rc=$?")
check "no conf at all: DISABLED"          grep -q 'verdict=DISABLED' <<<"$OUT"

# --- on, but no Codex login -> DISABLED, no call ------------------------------------------------------
on
mv "${H}/.codex/auth.json" "${H}/auth.off"
OUT=$(echo 'материал' | bash "$CC" || echo "rc=$?")
check "no login: DISABLED with the fix"   grep -q 'verdict=DISABLED (нет входа в Codex' <<<"$OUT"
check "no login: codex never called"      test "$(calls)" -eq 0
mv "${H}/auth.off" "${H}/.codex/auth.json"

# --- strict verdict parsing (ported, 26 cases) ---------------------------------------------------------
vcheck() {  # name expected reply-text
    local name="$1" want="$2" reply="${TDIR}/reply.txt" got
    printf '%s' "$3" >"$reply"
    got="$(echo 'материал' | FAKE_REPLY="$reply" bash "$CC" | head -1 | grep -oE 'verdict=[A-Z_]+' | cut -d= -f2 || true)"
    if [[ "$got" == "$want" ]]; then PASS=$((PASS + 1)); echo "ok   verdict: $name -> $got"
    else FAIL=$((FAIL + 1)); echo "FAIL verdict: $name: want $want got ${got:-<none>}" >&2; fi
}
vcheck "quoted APPROVE before final REQUEST_CHANGES" REQUEST_CHANGES $'Автор пишет, что ждёт APPROVE, но рано.\nVERDICT: REQUEST_CHANGES\n1. Заголовок.'
vcheck "APPROVE word in prose only" EMPTY $'Можно было бы дать APPROVE, но есть ошибки.\n1. Запятая.'
vcheck "empty reply" EMPTY ''
vcheck "conflicting verdict lines" CONFLICT $'VERDICT: APPROVE\nзамечаний нет\nVERDICT: REQUEST_CHANGES\n1. Тире.'
vcheck "clean final APPROVE" APPROVE $'VERDICT: APPROVE\nзамечаний нет'
vcheck "clean REQUEST_CHANGES" REQUEST_CHANGES $'VERDICT: REQUEST_CHANGES\n1. Тавтология.'
vcheck "markdown bold verdict" APPROVE $'**VERDICT: APPROVE**\nзамечаний нет'
vcheck "instruction echoed, no real verdict" EMPTY $'VERDICT: APPROVE или REQUEST_CHANGES\n1. ...'
vcheck "quoted verdict line in prose" EMPTY $'> VERDICT: APPROVE\nЭто цитата из прошлого ответа.'
vcheck "same verdict twice" REQUEST_CHANGES $'VERDICT: REQUEST_CHANGES\n1. A\nVERDICT: REQUEST_CHANGES'
vcheck "bold label form" APPROVE $'**VERDICT:** APPROVE\nзамечаний нет'
vcheck "no space after colon" EMPTY $'VERDICT:APPROVE'
vcheck "unbalanced bold" EMPTY $'VERDICT: APPROVE**'
vcheck "bold label then trailing bold" EMPTY $'VERDICT:** APPROVE'
vcheck "fenced example only" EMPTY $'Example, not a decision:\n```\nVERDICT: APPROVE\n```'
vcheck "tilde fenced example only" EMPTY $'Example:\n~~~\nVERDICT: APPROVE\n~~~'
vcheck "fenced APPROVE example, real REQUEST_CHANGES" REQUEST_CHANGES $'Формат:\n```text\nVERDICT: APPROVE\n```\nVERDICT: REQUEST_CHANGES\n1. Тире.'
vcheck "real APPROVE after fenced example" APPROVE $'```\nVERDICT: REQUEST_CHANGES\n```\nVERDICT: APPROVE\nзамечаний нет'
vcheck "unclosed fence hides verdict" EMPTY $'```\nVERDICT: APPROVE\nзамечаний нет'
vcheck "indented fence" EMPTY $'  ```\n  VERDICT: APPROVE\n  ```'
vcheck "other fence char inside fence" EMPTY $'~~~\n```\nVERDICT: APPROVE\n~~~'
vcheck "info string is not a closing fence" EMPTY $'```\n```text\nVERDICT: APPROVE'
vcheck "tilde info string is not a closing fence" EMPTY $'~~~\n~~~text\nVERDICT: APPROVE'
vcheck "shorter backtick fence does not close longer" EMPTY $'````\n```\nVERDICT: APPROVE'
vcheck "shorter tilde fence does not close longer" EMPTY $'~~~~\n~~~\nVERDICT: APPROVE'
vcheck "longer closing fence closes" APPROVE $'```\nVERDICT: REQUEST_CHANGES\n`````\nVERDICT: APPROVE'
vcheck "indented code block (4 spaces) is not a decision" EMPTY $'Пример формата:\n\n    VERDICT: APPROVE\n'
vcheck "tab-indented line is not a decision" EMPTY $'\tVERDICT: APPROVE'
vcheck "3 spaces still a verdict" APPROVE $'   VERDICT: APPROVE'
vcheck "4-space fence inside a fence does not close it" EMPTY $'```text\n    ```\nVERDICT: APPROVE\n```'
vcheck "4-space fence outside does not open one" REQUEST_CHANGES $'    ```\nVERDICT: REQUEST_CHANGES\n1. A.'
vcheck "3-space fence closes" APPROVE $'```\nVERDICT: REQUEST_CHANGES\n   ```\nVERDICT: APPROVE'
vcheck "inline code line is not a fence" REQUEST_CHANGES $'```VERDICT: APPROVE```\nVERDICT: REQUEST_CHANGES\nПример:\n```\nVERDICT: APPROVE\n```'
vcheck "tilde info string may hold a backtick" EMPTY $'~~~ a`b\nVERDICT: APPROVE\n~~~'

# --- model from the conf --------------------------------------------------------------------------------
rm -f "${H}/codex-calls"
printf 'VERDICT: APPROVE\n' >"${TDIR}/ok.txt"
OUT=$(echo 'x' | FAKE_REPLY="${TDIR}/ok.txt" bash "$CC")
check "empty model: no -m, shown default" bash -c 'grep -q "^codex: model=default verdict=APPROVE" <<<"$0" && ! grep -q -- " -m " "$1"' "$OUT" "${H}/codex-calls"
on gpt-test-1
OUT=$(echo 'x' | FAKE_REPLY="${TDIR}/ok.txt" bash "$CC")
check "model from conf passed with -m"   bash -c 'grep -q "^codex: model=gpt-test-1 " <<<"$0" && grep -q -- "-m gpt-test-1" "$1"' "$OUT" "${H}/codex-calls"
on 'bad model;id'
OUT=$(echo 'x' | bash "$CC" 2>&1 || echo "rc=$?")
check "bad model name refused"           grep -qx 'rc=2' <<<"$OUT"
on

# --- text-critics -----------------------------------------------------------------------------------------
cp "${REPO}/templates/checklists/text-standard.md" "${H}/.claude-lab/shared/checklists/text-standard.md"
printf 'Как поливать томаты в жару\n\nУтром, до девяти.\n' >"${TDIR}/draft.md"
printf 'Образец автора.\n' >"${TDIR}/sample.md"
export FAKE_EDITOR=$'VERDICT: APPROVE\nзамечаний нет' FAKE_PROOF=$'VERDICT: APPROVE\nзамечаний нет'
rm -f "${H}/codex-calls" "${H}"/last-prompt-*
OUT=$(bash "$TC" --genre пост "${TDIR}/draft.md" "${TDIR}/sample.md" 2>&1); RC=$?
check "both APPROVE -> exit 0"           test "$RC" -eq 0
check "two critics called"               test "$(calls)" -eq 2
check "summary line"                     grep -q '^ИТОГ: редактор=APPROVE корректор=APPROVE sha256=' <<<"$OUT"
check "standard from conf in prompts"    bash -c 'test "$(grep -l "Шаг 5. Факты" "$0"/last-prompt-* | wc -l)" -eq 2' "$H"
check "context from conf in prompts"     bash -c 'test "$(grep -l "Канал о садоводстве для дачников" "$0"/last-prompt-* | wc -l)" -eq 2' "$H"
check "genre line in prompts"            bash -c 'test "$(grep -l "Жанр (метаданные): пост" "$0"/last-prompt-* | wc -l)" -eq 2' "$H"
check "draft text in prompts"            bash -c 'test "$(grep -l "Утром, до девяти" "$0"/last-prompt-* | wc -l)" -eq 2' "$H"
check "quote-author rule reaches critics" bash -c 'grep -l "У цитаты всегда указан автор" "$0"/last-prompt-* >/dev/null' "$H"
export FAKE_PROOF=$'VERDICT: REQUEST_CHANGES\n1. Запятая.'
set +e; bash "$TC" "${TDIR}/draft.md" >/dev/null 2>&1; RC=$?; set -e
check "one REQUEST_CHANGES -> exit 1"     test "$RC" -eq 1
export FAKE_PROOF=$'VERDICT: APPROVE'
cat >"${TDIR}/liar.sh" <<'F'
#!/usr/bin/env bash
cat >/dev/null
echo "codex: model=default verdict=APPROVE"
exit 42
F
chmod +x "${TDIR}/liar.sh"
sed -i "s#^CODEX_CHECK_BIN=.*#CODEX_CHECK_BIN=${TDIR}/liar.sh#" "$CONF"
set +e; OUT=$(bash "$TC" "${TDIR}/draft.md" 2>&1); RC=$?; set -e
check "critic exiting non-zero never approves" test "$RC" -eq 1
check "failed critic shown in summary"   grep -q 'редактор=FAILED(rc=42) корректор=FAILED(rc=42)' <<<"$OUT"
on
rm -f "${H}/codex-calls"
printf '   \n\n' >"${TDIR}/blank.md"
set +e; bash "$TC" "${TDIR}/blank.md" >/dev/null 2>&1; RC=$?; set -e
check "blank draft refused (2)"           test "$RC" -eq 2
printf 'a\0b\n' >"${TDIR}/nul.md"
set +e; bash "$TC" "${TDIR}/nul.md" >/dev/null 2>&1; RC=$?; set -e
check "NUL byte refused (2)"              test "$RC" -eq 2
set +e; bash "$TC" --expect-sha256 0000 "${TDIR}/draft.md" >/dev/null 2>&1; RC=$?; set -e
check "sha256 contract mismatch refused"  test "$RC" -eq 2
set +e; bash "$TC" --expect-bytes 007 "${TDIR}/draft.md" >/dev/null 2>&1; RC=$?; set -e
check "non-decimal byte contract refused" test "$RC" -eq 2
set +e; bash "$TC" --genre $'a\nb' "${TDIR}/draft.md" >/dev/null 2>&1; RC=$?; set -e
check "multi-line genre refused"          test "$RC" -eq 2
set +e; bash "$TC" "${TDIR}/missing.md" >/dev/null 2>&1; RC=$?; set -e
check "missing draft refused"             test "$RC" -eq 2
check "refusals made no model call"       test "$(calls)" -eq 0
B=$(wc -c <"${TDIR}/draft.md"); B="${B//[[:space:]]/}"
OUT=$(bash "$TC" --expect-bytes "$B" --expect-sha256 "$(sha256sum "${TDIR}/draft.md" | cut -d' ' -f1)" "${TDIR}/draft.md" 2>&1)
check "contract met is reported"          grep -q 'полнота: контракт выполнен sha256 bytes=' <<<"$OUT"
sed -i 's#^TEXT_STANDARD=.*#TEXT_STANDARD=~/nowhere/standard.md#' "$CONF"
set +e; bash "$TC" "${TDIR}/draft.md" >/dev/null 2>&1; RC=$?; set -e
check "standard path taken from conf"     test "$RC" -eq 2
on

# --- generic: no names, hosts, users of a real install ---------------------------------------------------
GEN_RE='neurootdel|edgelab|svetlan|светлан|гостев|gostev|виктори|николай|nikolai|vladimir|владимир|/home/[a-z]'
check "codex-check: generic"   bash -c '! grep -inE "$0" "$1" "$2"' "$GEN_RE" "$CC" "${REPO}/skills/codex-check/SKILL.md"
check "text-critics: generic"  bash -c '! grep -inE "$0" "$1"' "$GEN_RE" "$TC"
check "standard: generic"      bash -c '! grep -inE "$0" "$1"' "$GEN_RE" "${REPO}/templates/checklists/text-standard.md"
check "conf template: generic" bash -c '! grep -inE "$0" "$1"' "$GEN_RE" "${REPO}/templates/editorial.conf"
check "conf template: OFF"     grep -qx 'EDITORIAL_ENABLED=0' "${REPO}/templates/editorial.conf"
check "lesson exists"          grep -q 'codex login' "${REPO}/docs/lesson-editorial.md"
check "people texts: no em dash" bash -c '! grep -n "—" "$@"' _ "${REPO}/docs/lesson-editorial.md" "${REPO}/skills/codex-check/SKILL.md" "${REPO}/templates/checklists/text-standard.md"

# --- installer wiring --------------------------------------------------------------------------------------
TD="${TDIR}/inst"
RC=$(
    export INSTALL_SH_SOURCED_FOR_TESTING=1 HOME="$TDIR"
    # shellcheck disable=SC1091
    source "${REPO}/install.sh" >/dev/null 2>&1
    set +e
    apply_install_names new
    as_agent() { "$@"; }
    step() { :; }; ok() { :; }; warn() { :; }; err() { :; }
    AGENT_HOME="$TD/home"; GUARD_LIB_DIR=/usr/local/lib/neurootdel; OPERATOR_NAME=Owner
    TEMPLATES_DIR="${REPO}/templates"; CODER_INSTALLED=0
    mkdir -p "$AGENT_HOME/.claude-lab/jarvis/.claude"; printf '# j\n' >"$AGENT_HOME/.claude-lab/jarvis/.claude/CLAUDE.md"
    install_team_refs >/dev/null 2>&1; r1=$?
    echo 'EDITORIAL_ENABLED=1' >>"$AGENT_HOME/.claude-lab/shared/editorial.conf"
    echo '21. my rule' >>"$AGENT_HOME/.claude-lab/shared/checklists/text-standard.md"
    install_team_refs >/dev/null 2>&1; r2=$?
    printf '%s\n' "$r1$r2" "${SKILLS_FROM_INSTALLER[*]}"
)
SH="$TD/home/.claude-lab/shared"
check "install: refs rc 0 twice"          test "$(head -n1 <<<"$RC")" = 00
check "install: codex-check in bundled skills" bash -c 'tail -n1 <<<"$0" | tr " " "\n" | grep -qx codex-check' "$RC"
check "install: conf written, OFF"        grep -qx 'EDITORIAL_ENABLED=0' "$SH/editorial.conf"
check "install: conf placeholders filled" bash -c '! grep -q "{{" "$0"' "$SH/editorial.conf"
check "install: standard written"         cmp -s <(head -n 30 "${REPO}/templates/checklists/text-standard.md") <(head -n 30 "$SH/checklists/text-standard.md")
check "rerun: owner's conf kept"          grep -qx 'EDITORIAL_ENABLED=1' "$SH/editorial.conf"
check "rerun: owner's standard kept"      grep -qx '21. my rule' "$SH/checklists/text-standard.md"
check "skill bundled with frontmatter"    grep -qx 'name: codex-check' "${REPO}/skills/codex-check/SKILL.md"
check "lib installed by install_guard glob" bash -c "sed -n '/^install_guard() {/,/^}/p' '${REPO}/install.sh' | grep -qF '\"\$src\"/*.sh'"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
