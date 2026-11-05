#!/usr/bin/env python3
"""feedback-note.py: the one route of a correction, its fields, and the cancel rule. Synthetic data.

Run: python3 tests/test_feedback_note.py
"""
from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TOOL = REPO / "lib" / "feedback-note.py"
TEMPLATE_INDEX = REPO / "templates" / "memory" / "MEMORY.md"

FAILS: list[str] = []


def check(name: str, cond: bool, detail: object = "") -> None:
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else f"  {detail!r}"[:300]))
    if not cond:
        FAILS.append(name)


def run(mem: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run([sys.executable, "-B", str(TOOL), str(mem), "add", *args],
                          capture_output=True, text=True, timeout=30)


MEM = Path(tempfile.mkdtemp()) / "memory"
MEM.mkdir()
shutil.copy(TEMPLATE_INDEX, MEM / "MEMORY.md")
INDEX = MEM / "MEMORY.md"

# --- a correction becomes a note + one index line -------------------------------------------------
p = run(MEM, "--name", "lifehack-word", "--rule", "Слово «лайфхак» не писать, писать «приём»",
        "--area", "тексты для канала", "--source", "владелец, личка, 05.11", "--why", "звучит как реклама")
note = MEM / "feedback-lifehack-word.md"
check("add: rc 0", p.returncode == 0, p.stderr)
body = note.read_text(encoding="utf-8") if note.exists() else ""
check("note: type feedback", "type: feedback" in body, body)
check("note: field Область", "Область: тексты для канала" in body, body)
check("note: field Источник", "Источник: владелец, личка, 05.11" in body, body)
check("note: field Отмена", "Отмена: ничего не отменяет" in body, body)
check("note: reason kept", "Почему: звучит как реклама" in body, body)
idx = INDEX.read_text(encoding="utf-8")
check("index: one line for the note", idx.count("(feedback-lifehack-word.md)") == 1, idx)
rules_part = idx.split("## Working rules", 1)[1].split("\n## ", 1)[0]
check("index: the line sits under «Working rules»", "(feedback-lifehack-word.md)" in rules_part, rules_part)
check("index: other sections kept", "## Topic indexes" in idx and "index-work.md" in idx)

# --- cancel: the new rule says «отменяет», the old one is gone from its carriers -----------------------
p = run(MEM, "--name", "method-word", "--rule", "Вместо «приём» писать «способ»", "--area", "тексты для канала",
        "--source", "владелец, группа проекта, 06.11", "--cancels", "lifehack-word")
new = MEM / "feedback-method-word.md"
check("cancel: rc 0", p.returncode == 0, p.stderr)
check("cancel: old note file deleted", not note.exists())
idx = INDEX.read_text(encoding="utf-8")
check("cancel: old index line deleted", "feedback-lifehack-word.md" not in idx, idx)
check("cancel: new note says «отменяет»", "Отмена: отменяет feedback-lifehack-word" in new.read_text(encoding="utf-8"))
check("cancel: new index line says «отменяет»", "(feedback-method-word.md)" in idx and "отменяет feedback-lifehack-word" in idx, idx)
check("cancel: old rule text nowhere in memory",
      not any("лайфхак" in f.read_text(encoding="utf-8") for f in MEM.glob("*.md") if f.name != new.name))

# --- refusals write nothing ----------------------------------------------------------------------------
before = sorted((f.name, f.read_bytes()) for f in MEM.iterdir())
p = run(MEM, "--name", "x-one", "--rule", "r", "--area", "a", "--source", "s", "--cancels", "missing-note")
check("cancel of a missing note: rc 2", p.returncode == 2, p)
p = run(MEM, "--name", "method-word", "--rule", "r", "--area", "a", "--source", "s")
check("duplicate name: rc 2", p.returncode == 2, p)
p = run(MEM, "--name", "Bad Name", "--rule", "r", "--area", "a", "--source", "s")
check("bad slug: rc 2", p.returncode == 2, p)
p = run(MEM, "--name", "no-source", "--rule", "r", "--area", "a", "--source", "  ")
check("empty source: rc 2", p.returncode == 2, p)
p = run(MEM, "--name", "self", "--rule", "r", "--area", "a", "--source", "s", "--cancels", "self")
check("self-cancel: rc 2", p.returncode == 2, p)
check("refusals: memory untouched", sorted((f.name, f.read_bytes()) for f in MEM.iterdir()) == before)
p = run(Path(tempfile.mkdtemp()), "--name", "x", "--rule", "r", "--area", "a", "--source", "s")
check("dir without MEMORY.md: rc 2", p.returncode == 2, p)

# --- a text correction also goes to pravki.md, only when that file exists ------------------------------
pravki = MEM.parent / "pravki.md"
p = run(MEM, "--name", "no-pravki", "--rule", "Без восклицаний", "--area", "посты", "--source", "владелец",
        "--pravki", str(pravki))
check("pravki missing: note still written, file not created", p.returncode == 0 and not pravki.exists(), p)
pravki.write_text("# pravki\n", encoding="utf-8")
p = run(MEM, "--name", "with-pravki", "--rule", "Короче на треть", "--area", "посты", "--source", "владелец, группа",
        "--pravki", str(pravki))
check("pravki present: one line appended", p.returncode == 0 and pravki.read_text(encoding="utf-8").count("Короче на треть") == 1, p)

p = run(MEM, "--name", "cancel-pravki", "--rule", "Короче на четверть", "--area", "посты", "--source", "владелец",
        "--cancels", "with-pravki")
text = pravki.read_text(encoding="utf-8")
check("cancel: the old line leaves pravki.md too (no --pravki given)", p.returncode == 0 and "Короче на треть" not in text, text)
check("cancel: pravki.md header kept", text.startswith("# pravki\n"), text)

# --- a failed write in the middle restores everything (old rule stays whole, no half-new rule) ----------
ro = MEM.parent / "ro"
ro.mkdir()
ro_pravki = ro / "pravki.md"
ro_pravki.write_text("# pravki\n", encoding="utf-8")
p = run(MEM, "--name", "ro-old", "--rule", "Старое правило", "--area", "посты", "--source", "владелец", "--pravki", str(ro_pravki))
snap = sorted((f.name, f.read_bytes()) for f in MEM.iterdir())
ro.chmod(0o555)
try:
    p = run(MEM, "--name", "ro-new", "--rule", "Новое правило", "--area", "посты", "--source", "владелец", "--cancels", "ro-old")
finally:
    ro.chmod(0o755)
check("rollback: failing pravki write -> nonzero rc", p.returncode != 0, p)
check("rollback: memory exactly as before", sorted((f.name, f.read_bytes()) for f in MEM.iterdir()) == snap)
check("rollback: old pravki line still there", "Старое правило" in ro_pravki.read_text(encoding="utf-8"))
p = run(MEM, "--name", "ro-new", "--rule", "Новое правило", "--area", "посты", "--source", "владелец", "--cancels", "ro-old")
check("rollback: the same command succeeds on retry", p.returncode == 0 and "Старое правило" not in ro_pravki.read_text(encoding="utf-8"), p)

# --- two agents, one shared pravki.md, the same slug: a cancel removes only its own line ------------------
shared = MEM.parent / "shared-pravki.md"
shared.write_text("# pravki\n", encoding="utf-8")
MEM2 = MEM.parent / "memory2"
MEM2.mkdir()
shutil.copy(TEMPLATE_INDEX, MEM2 / "MEMORY.md")
run(MEM, "--name", "short-text", "--rule", "Правило агента один", "--area", "посты", "--source", "владелец", "--pravki", str(shared))
run(MEM2, "--name", "short-text", "--rule", "Правило агента два", "--area", "посты", "--source", "владелец", "--pravki", str(shared))
p = run(MEM, "--name", "short-text-2", "--rule", "Новое правило агента один", "--area", "посты", "--source", "владелец",
        "--cancels", "short-text")
text = shared.read_text(encoding="utf-8")
check("shared pravki: own old line removed", p.returncode == 0 and "Правило агента один" not in text, text)
check("shared pravki: the other agent's line with the same slug kept", "Правило агента два" in text, text)
check("no staging or backup files left", not [f for f in (*MEM.iterdir(), *MEM.parent.iterdir())
                                               if ".new-" in f.name or f.name.endswith("feedback-note-bak")])

# --- in-process failures: a rename fails mid-way -> renames undo it; an undo that fails is reported --------
import importlib.util
spec = importlib.util.spec_from_file_location("feedback_note", TOOL)
fn = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fn)
M3 = Path(tempfile.mkdtemp()) / "memory"
M3.mkdir()
shutil.copy(TEMPLATE_INDEX, M3 / "MEMORY.md")
fn.main([str(M3), "add", "--name", "old", "--rule", "Старое", "--area", "a", "--source", "s"])
snap3 = sorted((f.name, f.read_bytes()) for f in M3.iterdir())
real_replace = fn.os.replace


def failing_on_index(src, dst):
    if Path(dst).name == "MEMORY.md" and ".new-" in Path(src).name:
        raise OSError(28, "No space left on device")
    return real_replace(src, dst)


fn.os.replace = failing_on_index
rc = fn.main([str(M3), "add", "--name", "new", "--rule", "Новое", "--area", "a", "--source", "s", "--cancels", "old"])
fn.os.replace = real_replace
check("ENOSPC on the index: rc 1", rc == 1, rc)
check("ENOSPC on the index: memory byte for byte as before", sorted((f.name, f.read_bytes()) for f in M3.iterdir()) == snap3)


def failing_index_and_undo(src, dst):
    if Path(dst).name == "MEMORY.md" or "feedback-note-bak" in Path(src).name:
        raise OSError(28, "No space left on device")
    return real_replace(src, dst)


pr3 = M3.parent / "pravki.md"
pr3.write_text("# pravki\n", encoding="utf-8")
fn.os.replace = failing_index_and_undo
rc = fn.main([str(M3), "add", "--name", "new", "--rule", "Новое", "--area", "a", "--source", "s", "--pravki", str(pr3)])
fn.os.replace = real_replace
check("undo fails too: rc 3, not «put back»", rc == 3, rc)
baks = list(M3.parent.glob(".pravki.md.feedback-note-bak*"))
check("undo fails too: the backup it names is kept on disk", len(baks) == 1 and baks[0].read_text(encoding="utf-8") == "# pravki\n", baks)
rc = fn.main([str(M3), "add", "--name", "other", "--rule", "Ещё", "--area", "a", "--source", "s", "--pravki", str(pr3)])
check("after a failed undo: next change of that file refused (rc 3)", rc == 3, rc)
check("after a failed undo: the kept backup byte for byte", baks[0].read_bytes() == b"# pravki\n" and not (M3 / "feedback-other.md").exists())
baks[0].unlink()

# the undo fails AND scratch cleanup fails: still rc 3 (never «put back»)
M4 = Path(tempfile.mkdtemp()) / "memory"
M4.mkdir()
shutil.copy(TEMPLATE_INDEX, M4 / "MEMORY.md")
pr4 = M4.parent / "pravki.md"
pr4.write_text("# pravki\n", encoding="utf-8")
real_unlink = fn.Path.unlink


def failing_unlink(self, missing_ok=False):
    if ".new-" in self.name or "feedback-note-bak" in self.name:
        raise OSError(30, "Read-only file system")
    return real_unlink(self, missing_ok=missing_ok)


fn.os.replace, fn.Path.unlink = failing_index_and_undo, failing_unlink
try:
    rc = fn.main([str(M4), "add", "--name", "x", "--rule", "X", "--area", "a", "--source", "s", "--pravki", str(pr4)])
finally:
    fn.os.replace, fn.Path.unlink = real_replace, real_unlink
check("undo and cleanup fail: rc 3", rc == 3, rc)

# --- YAML front matter stays valid with colons, quotes, a leading # ------------------------------------
p = run(MEM, "--name", "yaml-safe", "--rule", '# В ответах: сначала вывод, "цитаты" в кавычках', "--area", "ответы",
        "--source", "владелец")
head = (MEM / "feedback-yaml-safe.md").read_text(encoding="utf-8").split("---")[1]
desc = next(ln for ln in head.splitlines() if ln.startswith("description: "))
import json as _json
check("yaml: description is a quoted string", _json.loads(desc[len("description: "):]) == '# В ответах: сначала вывод, "цитаты" в кавычках', desc)

print(f"FAILS: {len(FAILS)}")
sys.exit(1 if FAILS else 0)
