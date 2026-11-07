#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329  # globals read by sourced fns, overrides
# Tests for the onboarding interview, no root needed:
#   skills/onboarding/SKILL.md is a working skill (no stub), names the triggers, blocks, state file
#   and the safe secrets route; the agent templates carry the trigger and include TONE_OF_VOICE.md;
#   install.sh marks a fresh USER.md as the installer default (and never touches a filled one);
#   install_skills lays the skill into Jarvis and Coder.
# Run: bash tests/test_onboarding.sh
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
has()   { grep -qF -- "$2" "$1"; }
hasnt() { ! grep -qiE -- "$2" "$1"; }

SK="${REPO}/skills/onboarding/SKILL.md"
MARK='<!-- onboarding:installer-default -->'
OLD_LINE='- Edit this file freely -- the agent reads it on every start.'

# --- the skill itself -------------------------------------------------------------------
check "skill: exists"                    test -s "$SK"
check "skill: frontmatter name"          grep -qx 'name: onboarding' "$SK"
check "skill: no stub / Firebase / Day-N" hasnt "$SK" 'stub|firebase|day-n'
check "skill: installer marker trigger"  has "$SK" "$MARK"
check "skill: old-install trigger line"  has "$SK" "$OLD_LINE"
check "skill: TONE_OF_VOICE trigger"     has "$SK" "Нет \`core/TONE_OF_VOICE.md\`"
check "skill: owner request trigger"     has "$SK" "настрой меня"
check "skill: state file"                has "$SK" "core/onboarding-state.md"
check "skill: in-progress checked first" has "$SK" "Проверяется ПЕРВЫМ и независимо от признаков ниже"
check "skill: backups never overwritten" has "$SK" ".bak-<ГГГГММДД-ЧЧММСС>-onboarding"
check "skill: no tone-stub trigger"      bash -c "! grep -n 'TONE_OF_VOICE' '$SK' | grep -qF 'onboarding:installer-default'"
check "skill: existing tone kept"        has "$SK" "Если файл уже есть (в любом режиме"
check "skill: resumable statuses"        bash -c "grep -qF 'in-progress | paused | declined | done' '$SK'"
check "skill: one question at a time"    has "$SK" "Один вопрос за сообщение"
for b in "### (а) Кто владелец" "### (б) Моя роль" "### (в) Тон голоса" "### (г) Сервисы и ключи" "### (д) Отчёты"; do
    check "skill: block ${b}"            has "$SK" "$b"
done
check "skill: doctor/auditor а,б,д only" has "$SK" "| Доктор сервера, Аудитор | домашний каталог, \`~/.hermes\` | а, б, д |"
check "skill: no secrets in chat"        has "$SK" "Пароли, токены и ключи в чат НЕ просить и НЕ принимать"
check "skill: secrets file route"        has "$SK" "~/.claude-lab/shared/secrets/<сервис>-api-key"
check "skill: secret check w/o printing" has "$SK" "stat -c '%a'"
CHMOD_AT=$(grep -n '^chmod 600 ~/.claude-lab/shared/secrets/' "$SK" | head -n 1 | cut -d: -f1)
NANO_AT=$(grep -n '^nano ~/.claude-lab/shared/secrets/' "$SK" | head -n 1 | cut -d: -f1)
check "skill: 600 before the key is typed" test "${CHMOD_AT:-0}" -gt 0 -a "${NANO_AT:-0}" -gt "${CHMOD_AT:-0}"
check "skill: marker is no licence to overwrite" has "$SK" "метка разрешает интервью, но НЕ слепую перезапись"
check "skill: summary before write"      has "$SK" "Только после его «да»"
check "skill: re-run does not overwrite" has "$SK" "Повторный запуск (файл уже заполнен): ничего не затирать"
check "skill: keeps installer fields"    has "$SK" "**Preferred language:**"
check "skill: feedback-note route"       has "$SK" "feedback-note.py <memory dir> add"
check "skill: writes TONE_OF_VOICE.md"   has "$SK" "**\`core/TONE_OF_VOICE.md\`**"
check "skill: no private names/ids/IPs"  hasnt "$SK" 'edgelab|Владимир|Vladimir|Светлан|Гостев|1815303740|izmuk|([0-9]{1,3}\.){3}[0-9]{1,3}'
check "skill: listed in installer"       grep -qE '^readonly SKILLS_FROM_INSTALLER=\(.*\bonboarding\b' "${REPO}/install.sh"

# --- templates: trigger + tone include ---------------------------------------------------
for t in CLAUDE.md coder-CLAUDE.md; do
    f="${REPO}/templates/${t}"
    check "tpl ${t}: installer marker"   has "$f" "$MARK"
    check "tpl ${t}: names the skill"    has "$f" "skills/onboarding/SKILL.md"
    check "tpl ${t}: resume on in-progress" has "$f" "status: in-progress"
    check "tpl ${t}: TONE_OF_VOICE missing" has "$f" "core/TONE_OF_VOICE.md"
    check "tpl ${t}: tone included after USER" \
        bash -c "grep -A1 -x '@core/USER.md' '$f' | grep -qx '@core/TONE_OF_VOICE.md'"
done
check "install.sh: marker in USER.md heredoc" \
    bash -c "grep -A1 -x '# USER.md -- Operator profile' '${REPO}/install.sh' | grep -qxF '$MARK'"
check "install.sh: old line still the same" has "${REPO}/install.sh" "$OLD_LINE"

# --- install.sh in a sandbox -------------------------------------------------------------
FAKE_HOME="${TDIR}/home"
mkdir -p "$FAKE_HOME" "${TDIR}/etc" "${TDIR}/libexec"
sed -e "s#^readonly RICHARD_HOME=.*#readonly RICHARD_HOME=\"${TDIR}/richard\"#" \
    -e "s#/etc/systemd/system/#${TDIR}/systemd/#g" \
    "${REPO}/install.sh" >"${TDIR}/install.sh"

export INSTALL_SH_SOURCED_FOR_TESTING=1
export NEUROOTDEL_TEMPLATES_DIR="${REPO}/templates"
export NEUROOTDEL_INSTALLER_ROOT="$REPO"
# shellcheck disable=SC1091
source "${TDIR}/install.sh"
set +e
apply_install_names new
AGENT_HOME="$FAKE_HOME"
CONFIG_ROOT="${TDIR}/etc"
GUARD_LIB_DIR="${TDIR}/lib"
AGENT_USER="$(id -un)"
as_agent() { "$@"; }
fix_owner() { :; }
install() {    # drop -o/-g/-m: the sandbox user cannot chown to root
    local args=()
    while (($#)); do case $1 in -o|-g|-m) shift 2 ;; *) args+=("$1"); shift ;; esac; done
    command install "${args[@]}"
}
step() { :; }
OPERATOR_NAME="Анна"; OPERATOR_LANGUAGE="Russian"; OPERATOR_TIMEZONE="Asia/Bangkok"; TG_USER_ID="555"

for kind in jarvis coder; do
    WS="${TDIR}/ws-${kind}"
    _write_agent_workspace "$WS" "$kind" >/dev/null 2>&1
    check "ws ${kind}: USER.md marked default" has "${WS}/core/USER.md" "$MARK"
    check "ws ${kind}: USER.md keeps old line" has "${WS}/core/USER.md" "$OLD_LINE"
    check "ws ${kind}: no TONE_OF_VOICE yet"  test ! -e "${WS}/core/TONE_OF_VOICE.md"
    check "ws ${kind}: CLAUDE.md trigger"     has "${WS}/CLAUDE.md" "skills/onboarding/SKILL.md"
    check "ws ${kind}: CLAUDE.md tone include" grep -qx '@core/TONE_OF_VOICE.md' "${WS}/CLAUDE.md"
    check "ws ${kind}: no placeholder left"   bash -c "! grep -q '{{' '${WS}/CLAUDE.md'"
    # A filled profile (what the interview writes) survives a re-run untouched.
    printf '# USER.md -- Operator profile\n\n**Name:** Анна\n**Timezone:** Asia/Bangkok\n**Preferred language:** русский\n\n## Роль агента\n- тексты\n' >"${WS}/core/USER.md"
    cp "${WS}/core/USER.md" "${TDIR}/user-${kind}.expected"
    _write_agent_workspace "$WS" "$kind" >/dev/null 2>&1
    check "ws ${kind}: re-run keeps filled USER.md" cmp -s "${WS}/core/USER.md" "${TDIR}/user-${kind}.expected"
done

# The interview keeps **Preferred language:**; a re-run of install.sh reads it back with its own sed.
LANG_SED=$(grep -o "sed -n 's/^\\\\\*\\\\\*Preferred language:[^']*'" "${REPO}/install.sh" | head -n 1 | sed "s/^sed -n '//; s/'\$//")
check "install.sh: language sed found"  test -n "$LANG_SED"
check "re-run reads language from a filled profile" \
    test "$(sed -n "$LANG_SED" "${TDIR}/ws-jarvis/core/USER.md" | head -n 1)" = "русский"

# install_skills: the new skill reaches Jarvis and Coder.
TPL="${TDIR}/tpl"; mkdir -p "${TPL}/skills"
for s in "${SKILLS_FROM_TEMPLATE[@]}"; do mkdir -p "${TPL}/skills/${s}"; printf -- '---\nname: %s\n---\n' "$s" >"${TPL}/skills/${s}/SKILL.md"; done
TEMPLATE_CLONE_DIR="$TPL"  # fetch_template() reuses a ready clone dir (no network)
CODER_INSTALLED=1
install_skills >/dev/null 2>&1
for a in jarvis coder; do
    check "skills ${a}: onboarding installed" cmp -s "${FAKE_HOME}/.claude-lab/${a}/.claude/skills/onboarding/SKILL.md" "$SK"
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
