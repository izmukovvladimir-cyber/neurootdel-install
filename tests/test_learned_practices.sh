#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals read by sourced install.sh functions
# Tests for the learned-practices pack (templates/rules/learned-practices.md +
# templates/learned-practices/learned-practices-more.md), no root needed:
#   the pack itself: main file within the always-loaded cap, its pointer names the more-file,
#   denylist (no people, servers, handles, ids, products, our infra, secrets) = 0 hits;
#   install_team_refs: both files land in the plugin project rules of Jarvis and Coder, the
#   pointer resolves from the installed main file, Coder skipped when not installed, nothing in
#   ~/.claude/rules (would load twice), owner edits survive a re-run, symlinks are not followed.
# Run: bash tests/test_learned_practices.sh
set -euo pipefail
export LC_ALL=C.UTF-8

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

MAIN_SRC="${REPO}/templates/rules/learned-practices.md"
MORE_SRC="${REPO}/templates/learned-practices/learned-practices-more.md"
POINTER="learned-practices/learned-practices-more.md"

# --- the pack itself -------------------------------------------------------------------------
check "pack: main file exists"            test -s "$MAIN_SRC"
check "pack: more file exists"            test -s "$MORE_SRC"
check "pack: main file <= 12288 bytes"    test "$(wc -c <"$MAIN_SRC")" -le 12288
check "pack: main names the more-file"    grep -qF "\`${POINTER}\`" "$MAIN_SRC"
check "pack: pointer resolves in repo"    test -s "$(dirname "$(dirname "$MAIN_SRC")")/${POINTER}"
check "pack: DROPPED.md not shipped"      bash -c '! find "$0/templates" -name DROPPED.md | grep -q .' "$REPO"

# Denylist: the same patterns as the pack's own check.sh.
names='Владимир|Ижмуков|Светлан|Николай|Николая|Юля|Юли|Юлия|Виктори|Вика|Маркус|Дарь|Даша|Даши|Edith|Ричард|Лиза|Лизы|Артур|Алан|Герман|Ирин|Александр|Натали|Лёсин|Лесин|Корягин|Татьян|Женя|Жени|Евгени|Надежд|Ларис|Мира|Миры|Саня|Сани|Анастаси|Алина|Алины|Цайслер|Катя|Кати|Тесс|Эйва|Меркулов|Гостев|Вадим|Степан|Марго|Нина|Нины|Костя|Кости|Джарвис'
names_lat='Richard|Hermes|Jarvis|jarvis|koder|Marcus|marcus|Daria|daria|Svetlana|svetlana|Nikolai|nikolai|Vladimir|vladimir|izhmukov|Tsaisler|tsaisler'
products='chatplace|salebot|getcourse|prodamus|продамус|onlypult|elevenlabs|heygen|higgsfield|adspower|openrouter|openviking|gpt-image|codex-image|nano.?banana|\bfal\b|\bomni\b|\bflow\b|threads|reels challenge|лаборатори|нейроотдел|neurootdel|\bазв\b|\bazv\b|\bvpf\b|gbrain|swarm|dashi|ai_realshift|reelsmentor|pohyi|inferio|taplink|beget|timeweb|vast\.ai|telethon|tg-sales|продажник|\bблог|\bseo\b|дубай|\bмск\b|edgelab|/home/|/root/|/tmp/|tarify'
ids='@[A-Za-z0-9_]{4,}|\b[0-9]{1,3}(\.[0-9]{1,3}){3}\b|\bmsg ?[0-9]+|(голос|voice|сообщени[ея]) ?[0-9]{3,}|chat[ _]?id|\b[0-9]{5,}\b|\([0-9]{4}\)|sk-[A-Za-z0-9]{8,}|token=|api[_-]?key'
deny_hits() {
    local flags=$1 pattern=$2
    { grep -HnE $flags -- "(^|[^[:alpha:]])(${pattern})" "$MAIN_SRC" "$MORE_SRC" || true; } | wc -l
}
hits=0
for spec in "|$names" "|$names_lat" "-i|$products" "-i|$ids"; do
    n=$(deny_hits "${spec%%|*}" "${spec#*|}")
    hits=$((hits + n))
done
check "pack: denylist hits = 0 (got ${hits})" test "$hits" -eq 0
# The denylist is live: a planted name and an IP are caught.
printf 'Светлана 10.0.0.1\n' >"${TDIR}/planted.md"
planted=$(( $(grep -cE -- "(^|[^[:alpha:]])(${names})" "${TDIR}/planted.md") + $(grep -ciE -- "(^|[^[:alpha:]])(${ids})" "${TDIR}/planted.md") ))
check "pack: denylist catches a planted name and IP" test "$planted" -eq 2

# --- install_team_refs --------------------------------------------------------------------------
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

H="${TDIR}/home"
AGENT_HOME="$H"
AGENT_USER=neurootdel
GUARD_LIB_DIR=/usr/local/lib/neurootdel
OPERATOR_NAME="Анна"
TEMPLATES_DIR="${REPO}/templates"
JWS="${H}/.claude-lab/jarvis/.claude"
CWS="${H}/.claude-lab/coder/.claude"
JP="${JWS}/dashi-plugin-claude-code/plugin/.claude"
CP="${CWS}/dashi-plugin-claude-code/plugin/.claude"
mkdir -p "$JWS" "$CWS"
printf '# Jarvis\n' >"${JWS}/CLAUDE.md"
printf '# Coder\n' >"${CWS}/CLAUDE.md"

# Coder not installed: Jarvis only.
CODER_INSTALLED=0
install_team_refs; rc=$?
check "solo: rc 0"                        test "$rc" -eq 0
check "solo: jarvis main installed"       cmp -s "${JP}/rules/learned-practices.md" "$MAIN_SRC"
check "solo: no coder copy"               test ! -e "${CP}/rules/learned-practices.md"

# Coder installed.
CODER_INSTALLED=1
install_team_refs; rc=$?
check "full: rc 0"                        test "$rc" -eq 0
for agent in jarvis coder; do
    base=$JP; [[ "$agent" == coder ]] && base=$CP
    check "${agent}: main == template"    cmp -s "${base}/rules/learned-practices.md" "$MAIN_SRC"
    check "${agent}: more == template"    cmp -s "${base}/learned-practices/learned-practices-more.md" "$MORE_SRC"
    # The pointer is relative to the dir holding rules/, as the main file says.
    check "${agent}: pointer resolves"    test -s "$(dirname "${base}/rules")/${POINTER}"
    check "${agent}: mode 0644"           test "$(stat -c %a "${base}/rules/learned-practices.md")" = 644
done
check "richard: not in ~/.claude/rules"   test ! -e "${H}/.claude/rules/learned-practices.md"

# Re-run: an owner edit (and an owner-deleted line) survives, nothing is re-added.
echo '- my own lesson' >>"${JP}/rules/learned-practices.md"
sed -i '1d' "${CP}/learned-practices/learned-practices-more.md"
sha_before=$(sha256sum "${JP}/rules/learned-practices.md" "${CP}/learned-practices/learned-practices-more.md" "${CP}/rules/learned-practices.md" | sha256sum)
install_team_refs; rc=$?
sha_after=$(sha256sum "${JP}/rules/learned-practices.md" "${CP}/learned-practices/learned-practices-more.md" "${CP}/rules/learned-practices.md" | sha256sum)
check "rerun: rc 0"                       test "$rc" -eq 0
check "rerun: owner edits not clobbered"  test "$sha_before" = "$sha_after"
check "rerun: owner line kept"            grep -qxF -- '- my own lesson' "${JP}/rules/learned-practices.md"

# Owner removed the file: a re-run puts the template back (written when missing).
rm -f "${CP}/rules/learned-practices.md"
install_team_refs
check "missing: re-created"               cmp -s "${CP}/rules/learned-practices.md" "$MAIN_SRC"

# Symlink at the target: not followed, the outside file stays, the run reports failure.
echo secret >"${TDIR}/outside"
rm -f "${JP}/rules/learned-practices.md"
ln -s "${TDIR}/outside" "${JP}/rules/learned-practices.md"
if install_team_refs; then s_rc=0; else s_rc=$?; fi
check "symlink: refused (nonzero)"        test "$s_rc" -ne 0
check "symlink: target untouched"         test "$(cat "${TDIR}/outside")" = secret

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
