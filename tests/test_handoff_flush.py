#!/usr/bin/env python3
"""Tests for lib/agent-handoff-flush.py: a bare copy of our heading never doubles up.

Live case: the generated body under "## Last 15 actions (auto-generated)" was cut away by
hand, the heading stayed as the last line of the hand-written part, and every flush kept it
as sticky text and wrote a second heading below it.
Run: python3 tests/test_handoff_flush.py   (no network, no root)
"""
from __future__ import annotations

import importlib.util
import os
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SRC = REPO / "lib" / "agent-handoff-flush.py"

PASS = 0
FAIL = 0


def check(name: str, cond: bool, detail: str = "") -> None:
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"ok   {name}")
    else:
        FAIL += 1
        print(f"FAIL {name} {detail}")


_TMP = Path(tempfile.mkdtemp())
_HOME = _TMP / "home"
_WS = _HOME / ".claude-lab/jarvis/.claude"
_CONF = _TMP / "guard.conf"
_CONF.write_text(f'AGENT_HOME="{_HOME}"\nCHANNEL_AGENTS="jarvis"\nOWNER_TIMEZONE="UTC"\n', encoding="utf-8")
os.environ["NEUROOTDEL_GUARD_CONF"] = str(_CONF)
sys.path.insert(0, str(REPO / "lib"))


def load(src_text: str | None = None):
    path = SRC
    if src_text is not None:
        path = REPO / "lib" / f".mutant_flush_{os.getpid()}.py"  # next to guard_conf.py
        path.write_text(src_text, encoding="utf-8")
    try:
        spec = importlib.util.spec_from_file_location(f"flush_{id(src_text)}", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    finally:
        if src_text is not None:
            path.unlink()


STICKY = "# handoff.md\n\n## Open\n\n- an open item that must survive\n"
BARE = "## Last 15 actions (auto-generated)"
AUTO_BODY = (
    "## Last 15 actions (auto-generated)\n\n"
    "Auto-flushed by agent-handoff-flush.py at 2026-09-12 16:00 UTC.\n"
    "Window: last 24h. Source: /x/*.jsonl\n\n"
    "- **12.09 10:00** - Bash: something\n"
)


def run(mod, text: str, times: int = 2) -> str:
    """Flush the agent `times` times over a handoff.md holding `text`."""
    (_WS / "core/hot").mkdir(parents=True, exist_ok=True)
    proj = _HOME / ".claude/projects" / mod.AGENT_TO_JSONL_DIR["jarvis"]
    proj.mkdir(parents=True, exist_ok=True)
    (proj / "s.jsonl").write_text("", encoding="utf-8")
    h = _WS / "core/hot/handoff.md"
    for extra in h.parent.glob("handoff.md.*"):
        extra.unlink()
    h.write_text(text, encoding="utf-8")
    for _ in range(times):
        res = mod.flush_for_agent("jarvis")
        if not res.startswith("OK"):
            return "ERR:" + res
    return h.read_text(encoding="utf-8")


def heads(text: str) -> int:
    return sum(1 for ln in text.split("\n") if ln.startswith("## Last ") and "(auto-generated)" in ln)


def main() -> int:
    src = SRC.read_text(encoding="utf-8")
    good = load()

    live = STICKY + "\n" + BARE + "\n\n" + AUTO_BODY + good.AUTO_END_MARKER + "\n\n- diary line below\n"
    out = run(good, live)
    check("bare heading above a real section collapses into one", heads(out) == 1, repr(out[-400:]))
    check("hand-written text above and below the section is kept",
          "- an open item that must survive" in out and "- diary line below" in out, repr(out[-400:]))

    cut = STICKY + "\n" + BARE + "\n"
    out = run(good, cut)
    check("section cut away by hand gives no second heading", heads(out) == 1, repr(out[-300:]))
    check("sticky part survives the cut-section case", "- an open item that must survive" in out)

    quoted = STICKY + "\nquote: " + BARE + "\n"
    out = run(good, quoted)
    check("heading quoted inside a line is the person's text", "quote: " + BARE in out)

    followed = STICKY + "\n" + BARE + "\n- item under the heading\n"
    out = run(good, followed)
    check("heading with text under it is left alone", BARE + "\n- item under the heading" in out)

    out = run(good, STICKY)
    check("plain file still gets exactly one section", heads(out) == 1 and STICKY.strip() in out)

    check("drop_orphan_headings strips repeated trailing copies",
          good.drop_orphan_headings("x\n" + BARE + "\n" + BARE + "\n\n") == "x")
    check("drop_orphan_headings keeps text that is not a trailing heading",
          good.drop_orphan_headings("x\n" + BARE + "\ny\n") == "x\n" + BARE + "\ny\n")

    for name, a, b in (
        ("no cleanup in the branch with a section", "    head = drop_orphan_headings(existing[:bounds[0]])",
         "    head = existing[:bounds[0]]"),
        ("no cleanup in the branch without a section", "    existing = drop_orphan_headings(existing)\n", ""),
    ):
        if a not in src:
            check(f"mutant anchor present: {name}", False)
            continue
        mut = load(src.replace(a, b, 1))
        out_a = run(mut, live, 1)
        out_b = run(mut, cut, 1)
        check(f"control: mutant '{name}' is caught", heads(out_a) > 1 or heads(out_b) > 1)

    print(f"\nPASS={PASS} FAIL={FAIL}")
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
