#!/usr/bin/env python3
"""Tests for include_weight.turn_weight / turn_problems (whole turn weight). Run: python3 tests/test_include_weight_turn.py"""
from __future__ import annotations

import importlib.util
import sys
import tempfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("iw", Path(__file__).resolve().parent.parent / "lib" / "include_weight.py")
iw = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(iw)

FAILS: list[str] = []
COUNT = 0


def check(name: str, cond: bool) -> None:
    global COUNT
    COUNT += 1
    if not cond:
        FAILS.append(name)


def build(root: Path, includes: list[str], sizes: dict[str, int]) -> Path:
    agent = root / "someagent"
    (agent / ".claude" / "core" / "hot").mkdir(parents=True)
    (agent / ".claude" / "core" / "warm").mkdir(parents=True)
    body = "# CLAUDE\n\n" + "\n".join(f"@{i}" for i in includes) + "\n"
    (agent / ".claude" / "CLAUDE.md").write_text(body, encoding="utf-8")
    for rel, size in sizes.items():
        p = agent / ".claude" / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text("x" * size, encoding="utf-8")
    return agent


# Вес хода целиком, как его грузит Claude Code. Прежний замер видел только CLAUDE.md агента
# и его @include первого уровня: глобальный CLAUDE.md, rules/, CLAUDE.md предков, вложенные @ и
# индекс авто-памяти MEMORY.md в ход не попадали, и сторож жил на половине настоящего веса.
with tempfile.TemporaryDirectory() as td:
    root = Path(td)
    cfg = root / "cfg"
    (cfg / "rules").mkdir(parents=True)
    (cfg / "CLAUDE.md").write_text("g" * 3000, encoding="utf-8")
    (cfg / "rules" / "bash.md").write_text("r" * 500, encoding="utf-8")
    (root / "CLAUDE.md").write_text("a" * 700, encoding="utf-8")  # предок агента
    agent = build(root, ["core/rules.md", "core/hot/handoff.md"],
                  {"core/hot/handoff.md": 16 * 1024, "core/deep.md": 400, "core/deeper.md": 300})
    (agent / ".claude" / "core" / "rules.md").write_text("x" * 1000 + "\n@deep.md\n", encoding="utf-8")
    (agent / ".claude" / "core" / "deep.md").write_text("y" * 400 + "\n@deeper.md\n@rules.md\n", encoding="utf-8")
    work = agent / ".claude" / "plugin-repo" / "plugin"
    work.mkdir(parents=True)
    (work.parent / ".git").mkdir()
    mem = cfg / "projects" / iw.project_slug(work.parent) / "memory"
    mem.mkdir(parents=True)
    (mem / "MEMORY.md").write_text("".join(f"line {i}\n" for i in range(300)), encoding="utf-8")

    tw = iw.turn_weight(agent, workdir=work, config_dir=cfg)
    names = {r.name: r for r in tw.rows}
    def has(suffix: str):
        return [r for r in tw.rows if r.name.endswith(suffix)]
    check("полный ход: глобальный CLAUDE.md", any(r.kind == "global" and not r.own for r in has("cfg/CLAUDE.md")))
    check("полный ход: глобальные rules/*.md", any(r.kind == "global" for r in has("rules/bash.md")))
    check("полный ход: CLAUDE.md предка, не свой", any(r.kind == "project" and not r.own
                                                        for r in tw.rows if r.name == str(root / "CLAUDE.md")))
    check("полный ход: вложенный @ второго уровня", bool(has("core/deep.md")))
    check("полный ход: вложенный @ третьего уровня", bool(has("core/deeper.md")))
    check("полный ход: цикл @ не считается дважды", len(has("core/rules.md")) == 1)
    lines200 = sum(len(f"line {i}\n") for i in range(iw.MEMORY_INDEX_LINES))
    m = has("memory/MEMORY.md")
    check("полный ход: индекс MEMORY.md по git-корню, только первые строки",
          len(m) == 1 and m[0].size == lines200 and m[0].own and m[0].kind == "memory")
    check("полный ход: сумма = сумма строк", tw.total == sum(r.size for r in tw.rows))
    check("полный ход: своё = сумма своих строк", tw.own == sum(r.size for r in tw.rows if r.own))
    check("полный ход: своё меньше целого", 0 < tw.own < tw.total)
    probs = iw.turn_problems(tw)
    check("перевес: журнал под @ выше 15 КБ назван", any("handoff.md" in p for p in probs))
    check("перевес: лёгкий ход без журналов молчит",
          iw.turn_problems(iw.TurnWeight(1000, 1000, [iw.Source(1000, "core/rules.md", "include", True)])) == [])
    big = iw.TurnWeight(iw.TURN_LIMIT + 1, 10, [iw.Source(iw.TURN_LIMIT + 1, "core/rules.md", "include", True)])
    check("перевес: ход выше потолка назван", any("ход" in p for p in iw.turn_problems(big)))
    check("потолок хода выше журнального", iw.TURN_LIMIT > iw.JOURNAL_LIMIT)

with tempfile.TemporaryDirectory() as td:
    root = Path(td)
    cfg = root / "cfg"
    cfg.mkdir()
    (cfg / "CLAUDE.md").write_text("g" * 100, encoding="utf-8")
    agent = build(root, [], {})
    # глобальный файл виден и как .claude/CLAUDE.md предка (как ~/.claude/CLAUDE.md)
    (root / ".claude").mkdir()
    (root / ".claude" / "CLAUDE.md").symlink_to(cfg / "CLAUDE.md")
    chain = agent / ".claude"
    prev = "core/l0.md"
    (chain / "CLAUDE.md").write_text("@core/l0.md\n", encoding="utf-8")
    for i in range(8):
        (chain / "core").mkdir(exist_ok=True)
        (chain / "core" / f"l{i}.md").write_text(f"@l{i + 1}.md\n", encoding="utf-8")
    (chain / "core" / "l8.md").write_text("z", encoding="utf-8")
    tw = iw.turn_weight(agent, workdir=chain, config_dir=cfg)
    check("один файл двумя путями считается один раз", sum(1 for r in tw.rows if r.size == 100) == 1)
    depth = [r for r in tw.rows if "/core/l" in r.name]
    check("глубина @ ограничена как у Claude Code", len(depth) == iw.MAX_INCLUDE_DEPTH)
    check("рабочий каталог по умолчанию: плагин или .claude", iw.default_workdir(agent) == agent / ".claude")

with tempfile.TemporaryDirectory() as td:
    root = Path(td)
    home = root / "home"
    (home / ".claude" / "rules").mkdir(parents=True)
    (home / ".claude" / "CLAUDE.md").write_text("h" * 900, encoding="utf-8")
    (home / ".claude" / "rules" / "py.md").write_text("p" * 77, encoding="utf-8")
    cfg = home / "own-config"
    cfg.mkdir()
    agent = build(home, [], {})
    tw = iw.turn_weight(agent, workdir=agent / ".claude", config_dir=cfg, home=home)
    # живой след 07.11.2026: при своём CLAUDE_CONFIG_DIR приходят ~/.claude/rules, но не ~/.claude/CLAUDE.md
    check("свой конфиг: ~/.claude/rules приходят", any(r.name.endswith("rules/py.md") for r in tw.rows))
    check("свой конфиг: ~/.claude/CLAUDE.md предком не грузится", not any(r.size == 900 for r in tw.rows))

with tempfile.TemporaryDirectory() as td:
    # проектные .claude/rules предков, условные rules (paths:), @ в блоке кода, глубина по кратчайшему пути
    root = Path(td)
    home = root / "home"
    home.mkdir()
    cfg = root / "cfg"
    (cfg / "rules").mkdir(parents=True)
    (cfg / "rules" / "cond.md").write_text("---\npaths:\n  - \"*.py\"\n---\n" + "c" * 5000, encoding="utf-8")
    agent = build(root, ["core/a.md", "core/s.md"], {"core/fenced.md": 7777, "core/kid.md": 333})
    (agent / ".claude" / "rules").mkdir()
    (agent / ".claude" / "rules" / "proj.md").write_text("q" * 4444, encoding="utf-8")
    c = agent / ".claude" / "core"
    (c / "a.md").write_text("```\n@fenced.md\n```\n@b1.md\n", encoding="utf-8")
    for i, nxt in enumerate(["b2.md", "b3.md", "s.md"], start=1):
        (c / f"b{i}.md").write_text(f"@{nxt}\n", encoding="utf-8")
    (c / "s.md").write_text("@kid.md\n", encoding="utf-8")
    tw = iw.turn_weight(agent, workdir=agent / ".claude", config_dir=cfg, home=home)
    check("rules проекта (.claude/rules) входят в ход", any(r.size == 4444 and r.own for r in tw.rows))
    check("условные rules (paths:) в ход не входят", not any(r.name.endswith("cond.md") for r in tw.rows))
    check("@ внутри блока кода не импорт", not any(r.name.endswith("fenced.md") for r in tw.rows))
    check("глубина по кратчайшему пути: ребёнок общего файла посчитан", any(r.name.endswith("kid.md") for r in tw.rows))
    check("общий файл посчитан один раз", sum(1 for r in tw.rows if r.name.endswith("/s.md")) == 1)

with tempfile.TemporaryDirectory() as td:
    # ``` не закрывает ````, и импорт ПОСЛЕ правильно закрытого блока считается
    root = Path(td)
    agent = build(root, ["core/a.md"], {"core/in.md": 1111, "core/after.md": 2222})
    (agent / ".claude" / "core" / "a.md").write_text("````\n```\n@in.md\n````\n@after.md\n", encoding="utf-8")
    tw = iw.turn_weight(agent, workdir=agent / ".claude", config_dir=root / "nocfg", home=root / "nohome")
    check("короткая ``` внутри ```` блок не закрывает", not any(r.size == 1111 for r in tw.rows))
    check("импорт после закрытого блока считается", any(r.size == 2222 for r in tw.rows))

print(f"проверок {COUNT}, провалов {len(FAILS)}")
for f in FAILS:
    print("FAIL:", f)
sys.exit(1 if FAILS or COUNT != 26 else 0)
