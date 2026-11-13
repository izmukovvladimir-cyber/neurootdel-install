#!/usr/bin/env bash
# text-critics.sh -- two independent Codex critics (editor + proofreader) for a text going to people.
# Installed by the installer into <lib dir>; runs as the agent user.
# Usage: text-critics.sh [--genre G] [--source src.md ...] [--expect-sha256 H] [--expect-bytes N] <draft.md> [sample.md ...]
#   samples: the owner's model texts, rejected versions; --source: first-source text (editor only);
#   options go before the draft. Completeness contract may also come from env TC_EXPECT_SHA256 /
#   TC_EXPECT_BYTES (flags win).
# Settings: $EDITORIAL_CONF (default ~/.claude-lab/shared/editorial.conf), plain KEY=value lines:
#   EDITORIAL_ENABLED=0|1   off by default, on after `codex login` under the agent user
#   TEXT_STANDARD=          the owner's text standard (default ~/.claude-lab/shared/checklists/text-standard.md)
#   CODEX_CHECK_BIN=        codex-check.sh of the codex-check skill (default: the Jarvis skill)
#   CRITICS_CONTEXT=        one line: whose text, for whom, in what voice
# Exit: 0 both critics APPROVE; 1 not approved / not verified; 2 refused before any model call;
#       3 switched off (EDITORIAL_ENABLED is not 1).
set -euo pipefail
conf="${EDITORIAL_CONF:-$HOME/.claude-lab/shared/editorial.conf}"
usage="usage: text-critics.sh [--genre G] [--source F ...] [--expect-sha256 H] [--expect-bytes N] <draft> [sample ...]"
bad_usage() { echo "$usage" >&2; exit 2; }
refuse() { echo "ОТКАЗ: $*" >&2; exit 2; }

# conf_get <key> -- value of KEY=value from the conf (no sourcing: the file is never executed).
conf_get() {
    [[ -f "$conf" ]] || return 0
    sed -n "s/^$1=[\"']\{0,1\}\([^\"']*\)[\"']\{0,1\}[[:space:]]*\$/\1/p" "$conf" | tail -n 1
}
# conf_path <key> <default> -- a path setting, leading ~/ means the agent's home.
conf_path() {
    local v
    v="$(conf_get "$1")"; v="${v:-$2}"
    [[ "$v" == "~/"* ]] && v="$HOME/${v#\~/}"
    printf '%s' "$v"
}

if [[ "$(conf_get EDITORIAL_ENABLED)" != 1 ]]; then
    echo "ВЫКЛЮЧЕНО: критики не запускались. Включить: войти в Codex (codex login) и поставить EDITORIAL_ENABLED=1 в $conf"
    exit 3
fi
codex="$(conf_path CODEX_CHECK_BIN "~/.claude-lab/jarvis/.claude/skills/codex-check/scripts/codex-check.sh")"
std="$(conf_path TEXT_STANDARD "~/.claude-lab/shared/checklists/text-standard.md")"
context="$(conf_get CRITICS_CONTEXT)"
[[ -n "$context" ]] || context="Текст для живых читателей автора; пишем голосом автора из образцов."

genre=""; exp_sha="${TC_EXPECT_SHA256:-}"; exp_bytes="${TC_EXPECT_BYTES:-}"; sources=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --genre|--source|--expect-sha256|--expect-bytes) [[ $# -ge 2 && -n "$2" ]] || bad_usage ;;&
        --genre) genre="$2"; shift 2 ;;
        --source) sources+=("$2"); shift 2 ;;
        --expect-sha256) exp_sha="$2"; shift 2 ;;
        --expect-bytes) exp_bytes="$2"; shift 2 ;;
        --) shift; break ;;
        --*) bad_usage ;;
        *) break ;;
    esac
done
[[ $# -ge 1 && -n "$1" ]] || bad_usage
draft="$1"; shift
# Genre: one short printable line (no control chars, no Unicode line separators U+2028/U+2029/U+0085).
if [[ "$genre" == *[[:cntrl:]]* || "$genre" == *$'\xe2\x80\xa8'* || "$genre" == *$'\xe2\x80\xa9'* \
      || "$genre" == *$'\xc2\x85'* || ${#genre} -gt 100 ]]; then
    refuse "жанр должен быть одной короткой строкой без управляющих символов"
fi
[[ -x "$codex" ]] || { echo "missing: $codex (навык codex-check)" >&2; exit 2; }
[[ -f "$draft" ]] || { echo "missing: $draft" >&2; exit 2; }
[[ -f "$std" ]] || { echo "missing: $std" >&2; exit 2; }
for s in "$@" "${sources[@]}"; do
    [[ -f "$s" ]] || { echo "missing: $s" >&2; exit 2; }
done

# Any failure while preparing inputs is a refusal (rc=2) before any model call.
trap 'echo "ОТКАЗ: ошибка подготовки входа (строка $LINENO)" >&2; exit 2' ERR
out_editor=""; out_proof=""; snapdir=""
cleanup() {
    [[ -z "$out_editor" ]] || rm -f -- "$out_editor"
    [[ -z "$out_proof" ]] || rm -f -- "$out_proof"
    [[ -z "$snapdir" ]] || { chmod -R u+w -- "$snapdir"; rm -rf -- "${snapdir:?}"; }
    return 0
}
trap cleanup EXIT
out_editor="$(mktemp)"
out_proof="$(mktemp)"
snapdir="$(mktemp -d)"
# One frozen snapshot of every input; both critics get text captured once from it, verdict is bound to its sha256s.
sha_of() { sha256sum "$1" | cut -d' ' -f1; }
nonblank() { grep -q '[^[:space:]]' "$1"; }
no_nul() {
    local original filtered
    original="$(wc -c < "$1")" || return 1
    filtered="$(tr -d '\000' < "$1" | wc -c)" || return 1
    [[ -n "$original" && "$original" == "$filtered" ]]
}
take() { cp -- "$1" "$2" || refuse "не удалось прочитать $1"; }
snap="$snapdir/draft"; take "$draft" "$snap"
snap_std="$snapdir/standard"; take "$std" "$snap_std"
snap_files=("$snap" "$snap_std"); snap_labels=("черновик" "стандарт")
i=0
for s in "$@"; do
    i=$((i + 1)); take "$s" "$snapdir/sample.$i"
    snap_files+=("$snapdir/sample.$i"); snap_labels+=("образец $(basename "$s")")
done
i=0
for s in "${sources[@]}"; do
    i=$((i + 1)); take "$s" "$snapdir/source.$i"
    snap_files+=("$snapdir/source.$i"); snap_labels+=("первоисточник $(basename "$s")")
done
chmod a-w -- "${snap_files[@]}" "$snapdir"
snap_shas=()
for f in "${snap_files[@]}"; do snap_shas+=("$(sha_of "$f")"); done
sha="${snap_shas[0]}"

# Fail closed before any model call: nothing blank goes to the critics.
for k in "${!snap_files[@]}"; do
    nonblank "${snap_files[$k]}" || refuse "пустой ${snap_labels[$k]}"
    no_nul "${snap_files[$k]}" || refuse "нулевой байт в ${snap_labels[$k]}"
done
# Completeness contract: only an explicit expected sha256 / byte size proves the draft is whole.
complete="полнота: контракт не задан, обрезанность не проверялась"
if [[ -n "$exp_sha" || -n "$exp_bytes" ]]; then
    complete="полнота: контракт выполнен"
    if [[ -n "$exp_sha" ]]; then
        [[ "${exp_sha,,}" == "$sha" ]] || refuse "sha256 черновика $sha не совпадает с ожидаемым $exp_sha"
        complete+=" sha256"
    fi
    if [[ -n "$exp_bytes" ]]; then
        # Decimal string compare: no shell arithmetic (octal leading zeros, overflow).
        [[ "$exp_bytes" =~ ^(0|[1-9][0-9]*)$ ]] || refuse "ожидаемый размер не десятичное число: $exp_bytes"
        bytes="$(wc -c < "$snap")"; bytes="${bytes//[[:space:]]/}"
        [[ "$bytes" == "$exp_bytes" ]] || refuse "размер черновика $bytes байт, ожидалось $exp_bytes"
        complete+=" bytes=$bytes"
    fi
fi

# Capture every text once; both prompts are built from these values, never from files again.
draft_text="$(cat "$snap")"
std_text="$(cat "$snap_std")"
samples=""
i=0
for s in "$@"; do
    i=$((i + 1))
    samples+=$'\n--- ОБРАЗЕЦ / ОТВЕРГНУТАЯ ВЕРСИЯ: '"$(basename "$s")"$' ---\n'"$(cat "$snapdir/sample.$i")"
done
source_text=""
i=0
for s in "${sources[@]}"; do
    i=$((i + 1))
    source_text+=$'\n--- ПЕРВОИСТОЧНИК: '"$(basename "$s")"$' ---\n'"$(cat "$snapdir/source.$i")"
done
# The captured texts must come from the hashed snapshot.
for k in "${!snap_files[@]}"; do
    [[ "$(sha_of "${snap_files[$k]}")" == "${snap_shas[$k]}" ]] || refuse "снимок (${snap_labels[$k]}) изменился при чтении"
done
# Genre is metadata only: one line in both prompts, it switches nothing in the script.
genre_line=""
[[ -n "$genre" ]] && genre_line="Жанр (метаданные): $genre"$'\n'

editor_prompt() {
cat <<P
MAPPING: стандарт текста, образцы (если есть), первоисточник (если есть) и черновик ниже.
ЦЕЛЬ: ты строгий главный редактор. Пройди черновик по стандарту пункт за пунктом. Найди каждое нарушение: заголовок не так, как говорят люди, или не взят из образца; структура; у действия нет субъекта; факт без источника; цитата без автора; слова героя вперемешку с советами автора; оформление. Каждое замечание: номер пункта стандарта, цитата, как исправить. Одно нарушение = REQUEST_CHANGES.
КОНТЕКСТ: $context Будь строг, но не придумывай нарушений, которых нет. Черновик это простой текст: жирный шрифт и ссылки ставятся при публикации, их отсутствие не нарушение. Первоисточник передан: сверь с ним каждое утверждение. Не передан: отметь только утверждения, которые выглядят натяжкой.
${genre_line}--- СТАНДАРТ ---
$std_text
$samples$source_text
--- ЧЕРНОВИК ---
$draft_text
P
}

proof_prompt() {
cat <<P
MAPPING: стандарт текста, черновик ниже, образцы для сравнения тона (если есть).
ЦЕЛЬ: ты корректор и литературный редактор, носитель русского языка. Прочитай черновик ПОСТРОЧНО и найди: кальки с английского, фразы, которые носитель так не скажет, ошибки сочетаемости и управления, паронимы, плеоназмы, тавтологию и однокоренные рядом, канцелярит, жаргон, грамматику, пунктуацию, «е» вместо «ё», риторические вопросы. Каждое замечание: цитата, что не так, готовая замена. Одна ошибка = REQUEST_CHANGES.
КОНТЕКСТ: $context Не придумывай ошибок, которых нет. Разговорные слова, которые есть в образцах автора, допустимы. Замены предлагай короткие и живые, НИКОГДА не канцелярские: канцелярская замена хуже оригинала.
${genre_line}--- СТАНДАРТ ---
$std_text
$samples
--- ЧЕРНОВИК ---
$draft_text
P
}

trap - ERR
editor_prompt | "$codex" > "$out_editor" 2>&1 &
p1=$!
proof_prompt | "$codex" > "$out_proof" 2>&1 &
p2=$!
rc1=0; rc2=0
wait "$p1" || rc1=$?
wait "$p2" || rc2=$?

echo "===== КРИТИК 1: РЕДАКТОР ====="; cat "$out_editor"
echo; echo "===== КРИТИК 2: КОРРЕКТОР ====="; cat "$out_proof"
v1=$(grep -m1 -oE 'verdict=[A-Z_]+' "$out_editor" | cut -d= -f2 || true)
v2=$(grep -m1 -oE 'verdict=[A-Z_]+' "$out_proof" | cut -d= -f2 || true)
# A critic that exited non-zero has no verdict, whatever it printed.
(( rc1 == 0 )) || v1="FAILED(rc=$rc1)"
(( rc2 == 0 )) || v2="FAILED(rc=$rc2)"
echo; echo "ИТОГ: редактор=${v1:-EMPTY} корректор=${v2:-EMPTY} sha256=$sha"
for k in "${!snap_files[@]}"; do
    [[ $k -eq 0 ]] && continue
    echo "  снимок: ${snap_labels[$k]} sha256=${snap_shas[$k]}"
done
echo "  $complete"
echo "  жанр: ${genre:-не передан}"
# Ledger for the send gate (hooks/text-critics-gate.py): this exact text and both verdicts. A failure here never
# changes the verdict of this run.
gate="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/hooks/text-critics-gate.py"
if [[ -f "$gate" ]]; then
    python3 "$gate" record --state "${CRITICS_STATE:-$HOME/.claude-lab/shared/state/critics}" --path "$draft" \
        --file "$snap" --v1 "${v1:-EMPTY}" --v2 "${v2:-EMPTY}" >/dev/null 2>&1 \
        || echo "  журнал критиков не записан (гейт отправки этот прогон не увидит)"
fi
if [[ "$(sha256sum "$draft" | cut -d' ' -f1)" != "$sha" ]]; then
    echo "НЕ ПРОВЕРЕНО: $draft изменился во время сверки, вердикт относится к sha256=$sha"
    exit 1
fi
for k in "${!snap_files[@]}"; do
    if [[ "$(sha_of "${snap_files[$k]}")" != "${snap_shas[$k]}" ]]; then
        echo "НЕ ПРОВЕРЕНО: снимок (${snap_labels[$k]}) изменился во время сверки"
        exit 1
    fi
done
[[ "${v1:-}" == APPROVE && "${v2:-}" == APPROVE ]]
