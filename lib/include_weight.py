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

import os
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
FENCE_RE = re.compile(r"^(`{3,}|~{3,})(.*)$")


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



# Вес хода ЦЕЛИКОМ, как его собирает Claude Code. weigh() выше видит только CLAUDE.md агента
# и его @ первого уровня. В ход на деле идут ещё: глобальный CLAUDE.md и rules/ из CLAUDE_CONFIG_DIR,
# CLAUDE.md всех предков рабочего каталога, вложенные @ (до 5 уровней) и начало индекса авто-памяти
# MEMORY.md. Без них сторож видел около половины настоящего веса.
# Потолок ПОЛНОГО хода, та же граница, что TURN_WARN (~30 тыс. токенов на ход). Замер парка из 18
# агентов 07.11.2026: 23-144 КБ; 60 КБ дали бы перевес 16 из 18, 100 КБ ловят тех, у кого своих
# 80-140 КБ, которые режутся их же правкой.
TURN_LIMIT = 100 * 1024
MAX_INCLUDE_DEPTH = 5
MEMORY_INDEX_LINES = 200
PLUGIN_WORKDIR = Path(".claude") / "dashi-plugin-claude-code" / "plugin"


class Source(NamedTuple):
    """Один файл полного хода. own: файл агента (его он и режет), а не общий."""

    size: int
    name: str
    kind: str  # global | project | include | memory
    own: bool


class TurnWeight(NamedTuple):
    total: int
    own: int
    rows: list[Source]


def project_slug(p: Path) -> str:
    """Имя каталога проекта в CLAUDE_CONFIG_DIR/projects: путь, где всё кроме букв и цифр стало '-'."""
    return re.sub(r"[^A-Za-z0-9]", "-", str(p))


def default_workdir(agent_dir: Path) -> Path:
    plugin = agent_dir / PLUGIN_WORKDIR
    return plugin if plugin.is_dir() else agent_dir / ".claude"


def _git_root(p: Path) -> Path | None:
    for d in (p, *p.parents):
        if (d / ".git").exists():
            return d
    return None


def _inside(p: Path, root: Path) -> bool:
    try:
        p.relative_to(root)
    except ValueError:
        return False
    return True


def turn_weight(agent_dir: Path, workdir: Path | None = None,
                config_dir: Path | None = None, home: Path | None = None) -> TurnWeight:
    """Всё, что Claude Code кладёт в контекст каждого хода агента. Один файл считается один раз.

    Сверено с живыми ходами 07.11.2026 (11 и 9 файлов у двух агентов). Правила из ~/.claude/rules
    приходят и при чужом CLAUDE_CONFIG_DIR, а ~/.claude/CLAUDE.md как файл предка не приходит.
    """
    home = Path(home) if home else Path.home()
    workdir = Path(workdir) if workdir else default_workdir(agent_dir)
    if config_dir is None:
        config_dir = Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude")
    agent_key = _norm(agent_dir)
    seen: set[Path] = set()
    rows: list[Source] = []

    expanded: dict[Path, int] = {}

    def add(p: Path, kind: str, depth: int) -> None:
        key = _norm(p)
        if key not in seen:
            size = _size_of(key)
            if size is None:
                return
            seen.add(key)
            rows.append(Source(size, str(p), kind, _inside(key, agent_key)))
        # A file met again on a SHORTER path may now open children the deeper path could not.
        if depth >= MAX_INCLUDE_DEPTH or expanded.get(key, MAX_INCLUDE_DEPTH + 1) <= depth:
            return
        expanded[key] = depth
        try:
            text = key.read_text(encoding="utf-8", errors="replace")
        except OSError:
            return
        fence = ""
        for line in text.split("\n"):
            st = line.strip()
            fm = FENCE_RE.match(st)
            if fm:
                run = fm.group(1)
                if not fence:
                    fence = run
                    continue
                # CommonMark: closed only by the same char, at least as long, nothing after it
                if run[0] == fence[0] and len(run) >= len(fence) and not fm.group(2).strip():
                    fence = ""
                continue
            if fence:
                continue  # Claude Code does not import @paths inside code blocks
            m = INCLUDE_RE.match(st)
            if m:
                add(p.parent / Path(m.group(1)).expanduser(), "include", depth + 1)

    def add_rules(rules: Path) -> None:
        if not rules.is_dir():
            return
        for r in sorted(rules.rglob("*.md")):
            try:
                head = r.read_text(encoding="utf-8", errors="replace")[:2000]
            except OSError:
                continue
            # rules with `paths:` frontmatter load only when a matching file is touched, not every turn
            if head.startswith("---") and re.search(r"^paths\s*:", head.split("\n---", 1)[0], re.M):
                continue
            add(r, "global" if not _inside(_norm(r), agent_key) else "project", 0)

    add(config_dir / "CLAUDE.md", "global", 0)
    for rules in (config_dir / "rules", home / ".claude" / "rules"):
        add_rules(rules)
    for d in reversed((workdir, *workdir.parents)):
        files = [d / "CLAUDE.md", d / "CLAUDE.local.md"]
        if d != home:
            files.insert(1, d / ".claude" / "CLAUDE.md")
        for f in files:
            add(f, "project", 0)
        if d != home:
            add_rules(d / ".claude" / "rules")
    mem = config_dir / "projects" / project_slug(_git_root(workdir) or workdir) / "memory" / "MEMORY.md"
    try:
        with mem.open("rb") as fh:
            head = b"".join(line for _, line in zip(range(MEMORY_INDEX_LINES), fh))
    except OSError:
        head = None
    if head is not None:
        rows.append(Source(len(head), str(mem), "memory", True))
    return TurnWeight(sum(r.size for r in rows), sum(r.size for r in rows if r.own), rows)


def turn_problems(tw: TurnWeight) -> list[str]:
    """Перевес хода словами: журнал над своим потолком и ход над общим. Пусто = всё в норме."""
    out = []
    for r in tw.rows:
        base = r.name.split("/")[-1]
        if base in JOURNAL_LIMITS and r.size > JOURNAL_LIMITS[base]:
            out.append(f"{base} {r.size // 1024} КБ (потолок {JOURNAL_LIMITS[base] // 1024} КБ)")
    if tw.total > TURN_LIMIT:
        out.append(f"ход {tw.total // 1024} КБ (потолок {TURN_LIMIT // 1024} КБ, своё {tw.own // 1024} КБ)")
    return out


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
