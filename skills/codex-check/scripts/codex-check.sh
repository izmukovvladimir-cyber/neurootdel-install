#!/usr/bin/env bash
# codex-check.sh -- second opinion from Codex (the owner's ChatGPT subscription login, no API key).
# Prompt on stdin (MAPPING / ЦЕЛЬ / КОНТЕКСТ blocks, then the material).
# Settings: $EDITORIAL_CONF (default ~/.claude-lab/shared/editorial.conf), plain KEY=value lines:
#   EDITORIAL_ENABLED=0|1   off by default: on only after `codex login` under the agent user
#   CODEX_CHECK_MODEL=      model for `codex exec -m` (empty = Codex's own default)
# Prints first line "codex: model=<X> verdict=<APPROVE|REQUEST_CHANGES|EMPTY|CONFLICT|DISABLED>", then the reply.
# Exit: 0 a verdict was read, 1 Codex failed, 2 usage, 3 switched off / no Codex login.
set -euo pipefail
conf="${EDITORIAL_CONF:-$HOME/.claude-lab/shared/editorial.conf}"

# conf_get <key> -- value of KEY=value from the conf (no sourcing: the file is never executed).
conf_get() {
    [[ -f "$conf" ]] || return 0
    sed -n "s/^$1=[\"']\{0,1\}\([^\"']*\)[\"']\{0,1\}[[:space:]]*\$/\1/p" "$conf" | tail -n 1
}

model="${CODEX_CHECK_MODEL:-$(conf_get CODEX_CHECK_MODEL)}"
shown="${model:-default}"
export PATH="$HOME/.local/bin:$PATH"
prompt="$(cat)"
[[ -n "$prompt" ]] || { echo "usage: codex-check.sh <<'P' ... P" >&2; exit 2; }
[[ -z "$model" || "$model" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || { echo "bad CODEX_CHECK_MODEL in $conf" >&2; exit 2; }

if [[ "$(conf_get EDITORIAL_ENABLED)" != 1 ]]; then
    echo "codex: model=$shown verdict=DISABLED (сверка выключена: EDITORIAL_ENABLED=1 в $conf после входа в Codex)"
    exit 3
fi
if ! command -v codex >/dev/null 2>&1; then
    echo "codex: model=$shown verdict=DISABLED (нет программы codex: поставь Codex CLI и выполни codex login)"
    exit 3
fi
if [[ ! -s "${CODEX_HOME:-$HOME/.codex}/auth.json" ]]; then
    echo "codex: model=$shown verdict=DISABLED (нет входа в Codex: выполни codex login под этим пользователем)"
    exit 3
fi

out="$(mktemp)"
trap 'rm -f "${out:?}" "${out:?}.err"' EXIT
instr='Ты независимый ревьюер. Проверь материал ниже. Ответ строго в формате:
VERDICT: APPROVE или REQUEST_CHANGES
Затем пронумерованный список замечаний (что не так, где, как исправить), самые важные первыми. Нет замечаний: напиши «замечаний нет». Ничего не меняй в файлах.'
margs=()
[[ -n "$model" ]] && margs=(-m "$model")
if ! printf '%s\n\n%s\n' "$instr" "$prompt" | timeout 600 codex exec --skip-git-repo-check -s read-only \
        "${margs[@]}" -o "$out" - >/dev/null 2>"$out.err"; then
    echo "codex: model=$shown verdict=EMPTY (ошибка: $(tail -3 "$out.err" | tr '\n' ' '))"
    exit 1
fi
# Strict, fail-closed: only whole lines "VERDICT: APPROVE|REQUEST_CHANGES" count (or **VERDICT: X** / **VERDICT:** X);
# a word quoted in prose never counts; none -> EMPTY, more than one distinct value -> CONFLICT.
# Lines inside fenced code blocks (``` or ~~~) never count: an example of the format is not a decision.
# A fence (indent 0-3 spaces) closes only with the same char, at least as long, nothing after it; an unclosed fence
# hides everything after it (fail-closed). A verdict line indented by 4+ spaces or a tab is an
# indented code block in Markdown: it never counts either.
verdict=$(awk '
    { match($0, /^ */); ind = RLENGTH; rest = substr($0, ind + 1) }   # fences: 0-3 spaces of indent only
    f == "" && ind <= 3 && match(rest, /^(```+|~~~+)/) {              # opening fence: remember char and length;
        o = substr(rest, 1, RLENGTH)                                  # a backtick in the info string of a
        if (!(substr(o, 1, 1) == "`" && index(substr(rest, RLENGTH + 1), "`") > 0)) {   # ``` fence = inline code
            f = substr(o, 1, 1); n = length(o); next } }
    f != "" { if (ind <= 3) { c = rest; sub(/[[:space:]]*$/, "", c)   # closing fence: same char,
        if (length(c) >= n && c ~ ("^" f "+$")) f = "" }; next }      # >= length, nothing after
    { print }' "$out" | grep -E '^ {0,3}(VERDICT:[[:space:]]+(APPROVE|REQUEST_CHANGES)|\*\*VERDICT:[[:space:]]+(APPROVE|REQUEST_CHANGES)\*\*|\*\*VERDICT:\*\*[[:space:]]+(APPROVE|REQUEST_CHANGES))[[:space:]]*$' \
    | grep -oE 'APPROVE|REQUEST_CHANGES' | sort -u || true)
[[ "$verdict" == *$'\n'* ]] && verdict=CONFLICT
echo "codex: model=$shown verdict=${verdict:-EMPTY}"
cat "$out"
