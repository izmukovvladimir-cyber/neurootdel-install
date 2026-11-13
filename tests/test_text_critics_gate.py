#!/usr/bin/env python3
"""text-critics-gate.py: a text the critics rejected is stopped, an unreviewed one is journaled, approved passes.

Synthetic data. Run: python3 tests/test_text_critics_gate.py
"""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
GATE = REPO / "lib" / "hooks" / "text-critics-gate.py"
FAILS: list[str] = []


def check(name: str, cond: bool, detail: object = "") -> None:
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else f"  {detail!r}"[:300]))
    if not cond:
        FAILS.append(name)


TMP = Path(tempfile.mkdtemp())
HOME = TMP / "home"
SHARED = HOME / ".claude-lab" / "shared"
SHARED.mkdir(parents=True)
STATE = SHARED / "state" / "critics"
CONF = TMP / "guard.conf"
CONF.write_text(f'AGENT_USER="neurootdel"\nAGENT_HOME="{HOME}"\nLIB_DIR="{REPO / "lib"}"\nCHANNEL_AGENTS="jarvis"\n'
                f'OWNER_TG_ID="555"\nOWNER_TIMEZONE="Europe/Moscow"\n', encoding="utf-8")
ENV = {**os.environ, "NEUROOTDEL_GUARD_CONF": str(CONF), "PYTHONDONTWRITEBYTECODE": "1"}
EDITORIAL = SHARED / "editorial.conf"

PIECE = ("Утром в теплице плюс тридцать, и томаты сбрасывают цвет. Поливайте до девяти утра, под корень, "
         "тёплой водой из бочки. Днём откройте двери с двух сторон, чтобы шёл сквозняк. Вечером не поливайте: "
         "сырость к ночи даёт фитофтору. Через неделю такой схемы цвет держится, завязь идёт ровно.")
MSG = "Текст поста:\n\n" + PIECE
OTHER = "Текст поста:\n\n" + PIECE.replace("тёплой", "холодной")


def editorial(on: bool) -> None:
    EDITORIAL.write_text(f"EDITORIAL_ENABLED={1 if on else 0}\n", encoding="utf-8")


def cli(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run([sys.executable, str(GATE), *args], capture_output=True, text=True, env=ENV, timeout=30)


def hook(text: str, files: list[str] | None = None, tool: str = "mcp__dashi-channel__reply") -> str:
    payload = {"tool_name": tool, "tool_input": {"chat_id": "555", "text": text, "files": files or []}}
    return subprocess.run([sys.executable, str(GATE), str(STATE)], input=json.dumps(payload, ensure_ascii=False),
                          capture_output=True, text=True, env=ENV, timeout=30).stdout


def record(text: str, v1: str, v2: str, name: str = "draft.md") -> Path:
    draft = TMP / name
    draft.write_text(text, encoding="utf-8")
    r = cli("record", "--state", str(STATE), "--path", str(draft), "--file", str(draft), "--v1", v1, "--v2", v2)
    assert r.returncode == 0, r.stderr
    return draft


def journal() -> list[dict]:
    path = STATE / "gate.jsonl"
    return [json.loads(x) for x in path.read_text(encoding="utf-8").splitlines()] if path.exists() else []


denied = lambda out: '"permissionDecision": "deny"' in out  # noqa: E731

# --- editorial loop off: nothing happens ----------------------------------------------------------------
editorial(False)
record(PIECE, "REQUEST_CHANGES", "APPROVE")
check("off: a rejected text passes", hook(MSG) == "")
check("off: nothing journaled", journal() == [])

# --- on -------------------------------------------------------------------------------------------------
editorial(True)
check("on: the rejected piece is denied", denied(hook(MSG)))
check("on: the deny names text-critics.sh and override", "text-critics.sh" in hook(MSG) and "override" in hook(MSG))
check("on: same piece with bold intro and markup still denied", denied(hook("**Текст поста:**\n\n" + PIECE)))
check("on: edit_message checked too", denied(hook(MSG, tool="mcp__dashi-channel__edit_message")))
n0 = len(journal())
check("on: unreviewed piece passes", hook(OTHER) == "")
rows = journal()
check("on: unreviewed piece journaled", len(rows) == n0 + 1 and rows[-1]["event"] == "unreviewed", rows[-1:])
check("on: journal holds no text", "томаты" not in (STATE / "gate.jsonl").read_text(encoding="utf-8"))
check("on: a service reply is not a text for people", hook("Принял, делаю. Отпишусь через час.") == "")
check("on: other tools ignored", hook(MSG, tool="Bash") == "")
record(PIECE, "APPROVE", "APPROVE")
check("on: approved later -> passes", hook(MSG) == "")
record(PIECE, "APPROVE", "REQUEST_CHANGES")
check("on: approved, then rejected on a re-run -> denied", denied(hook(MSG)))
record(PIECE, "APPROVE", "APPROVE")
check("on: approved again -> passes", hook(MSG) == "")

# --- attachments -----------------------------------------------------------------------------------------------
bad = PIECE.replace("тёплой", "колодезной")
record(bad, "APPROVE", "REQUEST_CHANGES", "bad.md")
att = TMP / "post.md"
att.write_text("Текст поста:\n\n" + bad, encoding="utf-8")
check("file: a rejected .md attachment denied", denied(hook("Файл во вложении.", files=[str(att)])))
plain = TMP / "notes.txt"
plain.write_text("заметки без вводной строки " * 30, encoding="utf-8")
check("file: an attachment without the mark ignored", hook("Файл.", files=[str(plain)]) == "")

# --- override -----------------------------------------------------------------------------------------------
draft = TMP / "od.md"
draft.write_text(PIECE + " Версия три.", encoding="utf-8")
r = cli("override", "--state", str(STATE), "--file", str(draft), "--reason", "критики спорят о запятой уже давно")
check("override: refused before 4 rounds", r.returncode == 2, r)
for _ in range(4):
    cli("record", "--state", str(STATE), "--path", str(draft), "--file", str(draft), "--v1", "REQUEST_CHANGES",
        "--v2", "APPROVE")
r = cli("override", "--state", str(STATE), "--file", str(draft), "--reason", "коротко")
check("override: short reason refused", r.returncode == 2, r)
r = cli("override", "--state", str(STATE), "--file", str(draft), "--reason", "критики спорят о запятой уже давно")
check("override: after 4 rounds journaled", r.returncode == 0 and journal()[-1]["event"] == "override", r)
check("override: the text passes then", hook("Текст поста:\n\n" + PIECE + " Версия три.") == "")
d2 = TMP / "fail.md"
d2.write_text(PIECE + " Сбой.", encoding="utf-8")
cli("record", "--state", str(STATE), "--path", str(d2), "--file", str(d2), "--v1", "FAILED(rc=42)", "--v2", "APPROVE")
r = cli("override", "--state", str(STATE), "--file", str(d2), "--reason", "Codex упал, текст срочный к эфиру")
check("override: a critic failure allows it at once", r.returncode == 0, r)

# --- report, STOP, broken input --------------------------------------------------------------------------------
r = cli("report", "--state", str(STATE), "--hours", "1")
check("report: counts events", r.returncode == 0 and "unreviewed=" in r.stdout and "deny-text=" in r.stdout, r.stdout)
(STATE / "STOP").touch()
check("STOP: a rejected text passes", hook("Текст поста:\n\n" + bad) == "")
(STATE / "STOP").unlink()
r = subprocess.run([sys.executable, str(GATE), str(STATE)], input="not json", capture_output=True, text=True, env=ENV,
                   timeout=30)
check("bad input: exit 0, silent", r.returncode == 0 and r.stdout == "", r)
(STATE / "ledger.jsonl").write_text("garbage\n" + (STATE / "ledger.jsonl").read_text(encoding="utf-8"), encoding="utf-8")
check("a broken ledger line is skipped", denied(hook("Текст поста:\n\n" + bad)))

print(f"FAILS: {len(FAILS)}")
sys.exit(1 if FAILS else 0)
