#!/usr/bin/env python3
"""Вес постоянных файлов агента: что грузится КАЖДЫМ ходом и что ложится в контекст при старте.

Файлы, подключённые через `@include` в CLAUDE.md, читаются заново на каждом ходу и
оплачиваются каждым вызовом модели. Замер 06.09.2026 по парку: у части агентов это
полмегабайта на ход, при пороге 15 КБ на журнальные файлы (правило 5b глобального CLAUDE.md).

Журнал весит контекст и тогда, когда он НЕ под `@include`: агент читает его Read-ом на старте,
и прочитанное живёт до конца сессии. 18.09.2026 у одного агента handoff на 751 КБ лежал вне @include,
и сторож, смотревший только на @include, показал зелёное. Поэтому чисел два: вес ХОДА
(@include плюс сам CLAUDE.md) и вес СТАРТА (то же плюс журналы, найденные рядом).

Журналы ищутся РЕКУРСИВНО по `.claude`: раскладка у агентов разная (у одних decisions
в `core/warm`, у других в `core`, у третьих в `core/hot`), и фиксированный путь дал бы ложный ноль.
Бэкапы и архивы не в счёт: их никто не читает.

Порог относится к ЖУРНАЛЬНЫМ файлам (`decisions.md`, `handoff.md`, `recent.md`): они растут сами
и их сжатие ничего не стоит. `rules.md`, `USER.md`, `CLIENT.md`, `CLAUDE.md` это правила и профиль,
они растут медленно и режутся только осмысленно.

Известное ограничение: если два журнальных имени указывают на ОДИН файл, он считается один раз
и останется под тем именем, которое встретилось первым. Живых таких случаев в парке нет.

Сигналов два, и они про разное. ПРЕВЫШЕНИЕ это раздувшийся журнал: он читается раз за сессию,
и его сжатие ничего не стоит. ХОД ДОРОГ это вес @include-части: он платится каждым вызовом модели,
и режется только осмысленно, решением хозяина файлов.

Отношение handoff:decisions это ранний признак: закрытое копится в handoff вместо того, чтобы
уходить строкой в decisions (правило 5b). Норма около единицы, десятки означают несжатый журнал.
"""
from __future__ import annotations

import re
import stat as stat_module
import sys
from pathlib import Path
from typing import NamedTuple, Sequence

JOURNAL_LIMIT = 15 * 1024
# У recent.md свой потолок: его держит сам плагин (config.ts, max_hot_bytes=20480), и 19 КБ
# там норма, а не раздувшийся журнал. Общий порог 15 КБ кричал бы на 17 агентов из 19 впустую.
RECENT_LIMIT = 20 * 1024
JOURNAL_LIMITS = {"decisions.md": JOURNAL_LIMIT,
                  "handoff.md": JOURNAL_LIMIT,
                  "recent.md": RECENT_LIMIT}
JOURNAL_NAMES = tuple(JOURNAL_LIMITS)
# Тесты, фикстуры и шаблоны содержат файлы с теми же именами, но контекстом агента не являются:
# у одного агента фикстура скилла давала лишнюю строку recent.md.
SKIP_DIRS = {"archive", "archives", "backup", "backups", "old", ".git", "node_modules",
             "__pycache__", "tests", "test", "fixtures", "templates", "examples", ".venv", "dist"}
RATIO_WARN = 3.0
# Вес хода платится КАЖДЫМ вызовом модели, в отличие от журнала, который читается раз за сессию.
# 100 КБ это примерно 30 тыс. токенов на ход; замер 30.07.2026 у одного агента: 55 тыс. токенов на ход
# съедали четверть недельного расхода. Метка только называет цену, резать правила решает человек.
TURN_WARN = 100 * 1024
INCLUDE_RE = re.compile(r"^@(\S+)\s*$")


class Row(NamedTuple):
    """Один файл в замере. Кортеж ради совместимости: (size, name, journal, included)."""

    size: int
    name: str
    journal: bool
    included: bool


class Weight(NamedTuple):
    """Замер по агенту: вес хода, вес старта и строки."""

    turn: int
    start: int
    rows: list[Row]


def _norm(p: Path) -> Path:
    """Один и тот же файл обязан давать один и тот же ключ: иначе он посчитается дважды."""
    try:
        return p.resolve()
    except (OSError, RuntimeError):
        return p.absolute()


def _size_of(p: Path) -> int | None:
    """Размер обычного файла. None, когда файла нет или он недоступен: замер не падает из-за него."""
    try:
        st = p.stat()
    except (OSError, ValueError):
        return None
    return st.st_size if stat_module.S_ISREG(st.st_mode) else None


def include_targets(claude_md: Path) -> list[Path]:
    """Пути, которые CLAUDE.md подключает через @include, плюс он сам.

    Пути отдаются КАК НАПИСАНЫ, не разрешёнными: имя журнала живёт в имени ссылки, а не
    в имени её цели. Дедуп идёт по _norm, чтобы один файл не посчитался дважды.
    """
    out = [claude_md]
    keys = {_norm(claude_md)}
    try:
        text = claude_md.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return out
    for line in text.split("\n"):
        m = INCLUDE_RE.match(line.strip())
        if not m:
            continue
        p = claude_md.parent / m.group(1)
        key = _norm(p)
        if key not in keys:
            keys.add(key)
            out.append(p)
    return out


def journal_files(claude_dir: Path) -> list[Path]:
    """Журнальные файлы агента, найденные рекурсивно по .claude. Архивы и бэкапы пропускаются."""
    out: list[Path] = []
    stack = [claude_dir]
    seen_dirs: set[Path] = set()
    while stack:
        d = stack.pop()
        key = _norm(d)
        if key in seen_dirs:
            continue
        seen_dirs.add(key)
        try:
            entries = list(d.iterdir())
        except OSError:
            continue
        for p in entries:
            try:
                is_dir = p.is_dir()
            except OSError:
                continue
            if is_dir:
                if p.name not in SKIP_DIRS:
                    stack.append(p)
            elif p.name in JOURNAL_NAMES:
                out.append(p)
    return out


def over_limit(row: Row) -> bool:
    """Журнал вырос выше СВОЕГО потолка. На нежурнальный файл порог не распространяется."""
    if not row.journal:
        return False
    return row.size > JOURNAL_LIMITS.get(row.name.split("/")[-1], JOURNAL_LIMIT)


def journal_ratio(rows: Sequence[Row]) -> float | None:
    """handoff:decisions. None, когда decisions нет: отношение не выдумывается."""
    handoff = sum(r.size for r in rows if r.journal and r.name.split("/")[-1] == "handoff.md")
    decisions = sum(r.size for r in rows if r.journal and r.name.split("/")[-1] == "decisions.md")
    if not decisions:
        return None
    return handoff / decisions


def _short(p: Path) -> str:
    return str(p).split("/.claude/", 1)[-1]


def weigh(agent_dir: Path) -> Weight:
    """Замер по одному агенту: вес хода, вес старта, строки по убыванию."""
    claude_dir = agent_dir / ".claude"
    rows: list[Row] = []
    seen: set[Path] = set()
    turn = 0
    for p in include_targets(claude_dir / "CLAUDE.md"):
        key = _norm(p)
        if key in seen:
            continue
        size = _size_of(key)
        if size is None:
            continue
        seen.add(key)
        turn += size
        rows.append(Row(size, _short(p), p.name in JOURNAL_NAMES, True))
    loose = 0
    for raw in journal_files(claude_dir):
        key = _norm(raw)
        if key in seen:
            continue
        size = _size_of(key)
        if size is None:
            continue
        seen.add(key)
        loose += size
        # Имя берётся по пути агента, а не по цели симлинка: иначе в строке встанет чужое имя.
        rows.append(Row(size, _short(raw), True, False))
    rows.sort(reverse=True)
    return Weight(turn, turn + loose, rows)


def main(argv: list[str]) -> int:
    root = Path(argv[1]) if len(argv) > 1 else Path.home() / ".claude-lab"
    agents = sorted(d for d in root.iterdir()
                    if d.is_dir() and (d / ".claude" / "CLAUDE.md").is_file())
    if not agents:
        print(f"агентов с CLAUDE.md в {root} не найдено", file=sys.stderr)
        return 2
    over = 0
    pricey = 0
    lines = []
    for d in agents:
        turn, start, rows = weigh(d)
        bad = [r for r in rows if over_limit(r)]
        over += bool(bad)
        pricey += turn > TURN_WARN
        det = " ".join(f"{r.name.split('/')[-1]}{'' if r.included else '*'}:{r.size // 1024}K"
                       for r in rows if r.size)
        ratio = journal_ratio(rows)
        rmark = f" h/d={ratio:.0f}x" if ratio is not None and ratio >= RATIO_WARN else ""
        mark = " ПРЕВЫШЕНИЕ" if bad else ""
        tmark = " ХОД ДОРОГ" if turn > TURN_WARN else ""
        lines.append((start, f"{turn // 1024:5d}K ход {start // 1024:6d}K старт  "
                             f"{d.name:<22} {det}{rmark}{tmark}{mark}"))
    for _, line in sorted(lines, reverse=True):
        print(line)
    print(f"\nагентов {len(agents)}, с превышением журнального порога "
          f"({JOURNAL_LIMIT // 1024} КБ, recent.md {RECENT_LIMIT // 1024} КБ): {over}")
    print(f"вес хода выше {TURN_WARN // 1024} КБ (платится каждым вызовом модели): {pricey}")
    print("* это журнал вне @include: в ход не идёт, но ложится в контекст при чтении")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
