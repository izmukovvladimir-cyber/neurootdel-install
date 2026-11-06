#!/usr/bin/env python3
"""The one route of an owner's correction: a feedback note in auto memory + one line in MEMORY.md.

Installed by neurootdel-install. The agent runs it itself after fixing what the owner corrected:

  feedback-note.py <memory dir> add --name <slug> --rule "<what to do from now on>"
                   --area "<where it applies>" --source "<who said it, where, when>"
                   [--why "<reason>"] [--cancels <old slug>] [--pravki <file>]

  <memory dir>  the session's auto memory dir (~/.claude/projects/<project>/memory) holding MEMORY.md.
  add           writes <memory dir>/feedback-<slug>.md with the fields «Область», «Источник», «Отмена»
                and puts one link line into MEMORY.md under «## Working rules».
  --cancels X   the new note replaces feedback-X: the new one carries «Отмена: отменяет feedback-X»,
                the old note file and its MEMORY.md line are deleted (nothing else keeps the old rule).
  --pravki F    a correction of the owner's TEXT also goes as one line into F (the voice corrections
                file), only when F already exists; a missing F is reported and skipped. The note keeps
                the path, so a later --cancels also deletes that line from F.

Nothing else is a carrier of a correction: not core/rules.md, not CLAUDE.md, not a lessons file.
Exit 0 = written; 2 = bad arguments or a refused change; 1 = a write failed (nothing written:
every file is put back); 3 = a write failed and the undo too (the message names the backups). Shared voice files are locked while they are changed.
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import sys
import tempfile
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

SLUG = re.compile(r"^[a-z0-9][a-z0-9-]{0,60}$")
RULES_HEADING = "## Working rules"
PRAVKI_FIELD = "Правки голоса: "
TZ = os.environ.get("FEEDBACK_NOTE_TZ") or "Europe/Moscow"


def one_line(text: str) -> str:
    return " ".join(text.split())


def note_text(slug: str, rule: str, area: str, source: str, why: str, cancels: str | None, day: str,
              pravki: Path | None = None) -> str:
    cancel = f"отменяет feedback-{cancels}" if cancels else "ничего не отменяет"
    lines = [
        "---",
        f"name: feedback-{slug}",
        f"description: {json.dumps(rule, ensure_ascii=False)}",
        "type: feedback",
        "---",
        "",
        rule,
        "",
        f"Область: {area}",
        f"Источник: {source}",
        f"Отмена: {cancel}",
        f"Записано: {day}",
    ]
    if why:
        lines.insert(8, f"Почему: {why}")
    if pravki is not None:
        lines.append(f"{PRAVKI_FIELD}{pravki}")
    return "\n".join(lines) + "\n"


def pravki_of(note: Path) -> Path | None:
    """The voice corrections file a note also wrote to, if any."""
    for line in note.read_text(encoding="utf-8").splitlines():
        if line.startswith(PRAVKI_FIELD):
            return Path(line[len(PRAVKI_FIELD):].strip())
    return None


def note_id(mem: Path, slug: str) -> str:
    """Id of a note in a shared voice file: the slug plus its memory dir (two agents may share a slug)."""
    return f"feedback-{slug}@{hashlib.sha256(str(mem.resolve()).encode()).hexdigest()[:10]}"


def without_line_of(text: str, ident: str) -> str:
    """Voice corrections text with the line of this note id removed (and only that line)."""
    return "".join(ln for ln in text.splitlines(keepends=True) if f"| {ident} |" not in ln)


def lock_file(path: Path) -> int:
    """Exclusive lock beside a shared file (.<name>.lock); released when the fd is closed."""
    fd = os.open(path.with_name(f".{path.name}.lock"), os.O_RDWR | os.O_CREAT, 0o644)
    fcntl.flock(fd, fcntl.LOCK_EX)
    return fd


class RollbackError(OSError):
    """A write failed AND putting some file back failed too; the backups named here are kept."""


def stage(path: Path, text: str) -> Path:
    """The new version, fully on disk next to path (same filesystem), not yet in place."""
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.new-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp, 0o644)
    except OSError:
        Path(tmp).unlink(missing_ok=True)
        raise
    return Path(tmp)


def commit(writes: dict[Path, str], delete: Path | None) -> None:
    """Stage every new version and hard-link a backup of every file first; then rename them in place.

    Nothing touches a target before everything is staged. A failure while renaming is undone by
    renames only (a backup goes back over its file), so the undo needs no free space. If even that
    fails, RollbackError names the backups left on disk.
    """
    staged: dict[Path, Path] = {}
    backups: dict[Path, Path | None] = {}
    targets = list(writes) + ([delete] if delete is not None else [])
    # A backup left by an earlier failed undo is the only good copy: never touch it, stop here.
    stale = [str(b) for t in targets for b in t.parent.glob(f".{t.name}.feedback-note-bak*")]
    if stale:
        raise RollbackError(f"an earlier undo left backups, restore them first: {', '.join(stale)}")

    def drop(paths: list[Path | None]) -> list[str]:
        """Remove scratch files; never raises, returns what could not be removed."""
        left = []
        for x in paths:
            if x is not None:
                try:
                    x.unlink(missing_ok=True)
                except OSError:
                    left.append(str(x))
        return left

    try:
        for path, text in writes.items():
            staged[path] = stage(path, text)
        for path in targets:
            if path.exists():
                bak = path.with_name(f".{path.name}.feedback-note-bak-{os.getpid()}-{os.urandom(4).hex()}")
                os.link(path, bak)
                backups[path] = bak
            else:
                backups[path] = None
    except OSError:
        drop(list(staged.values()) + list(backups.values()))
        raise
    applied: list[Path] = []
    try:
        for path, tmp in staged.items():
            os.replace(tmp, path)
            applied.append(path)
        if delete is not None:
            delete.unlink()
            applied.append(delete)
    except OSError as exc:
        failed: list[str] = []
        for path in reversed(applied):
            bak = backups.pop(path)
            try:
                if bak is None:
                    path.unlink(missing_ok=True)
                else:
                    os.replace(bak, path)
            except OSError:
                failed.append(f"{path} (backup {bak})")
        drop([t for path, t in staged.items() if path not in applied] + [b for b in backups.values()])
        if failed:
            raise RollbackError(f"{exc}; NOT put back: {', '.join(failed)}") from exc
        raise
    left = drop(list(backups.values()))
    if left:
        print(f"feedback-note: written; remove these leftover backups by hand: {', '.join(left)}", file=sys.stderr)


def index_with(index: str, slug: str, rule: str, area: str, cancels: str | None) -> str:
    """MEMORY.md with the old note's line dropped and the new one appended to «## Working rules»."""
    keep = [ln for ln in index.splitlines() if not (cancels and f"(feedback-{cancels}.md)" in ln)]
    tail = f" (отменяет feedback-{cancels})" if cancels else ""
    entry = f"- [{rule[:80]}](feedback-{slug}.md) - область: {area}{tail}"
    start = next((i for i, ln in enumerate(keep) if ln.startswith(RULES_HEADING)), None)
    if start is None:
        keep += ["", f"{RULES_HEADING} (always in force)", "", entry]
    else:
        end = next((i for i in range(start + 1, len(keep)) if keep[i].startswith("## ")), len(keep))
        while end > start + 1 and not keep[end - 1].strip():
            end -= 1
        keep.insert(end, entry)
    return "\n".join(keep) + "\n"


def add(args: argparse.Namespace) -> int:
    mem = Path(args.memory_dir)
    index_path = mem / "MEMORY.md"
    slug, cancels = args.name, args.cancels
    rule, area, source, why = (one_line(x or "") for x in (args.rule, args.area, args.source, args.why))
    for label, value in (("--name", slug), ("--cancels", cancels)):
        if value is not None and not SLUG.match(value):
            print(f"feedback-note: {label} must be a-z, 0-9, '-' (got {value!r})", file=sys.stderr)
            return 2
    if not (rule and area and source):
        print("feedback-note: --rule, --area and --source are all required and not empty", file=sys.stderr)
        return 2
    if not index_path.is_file():
        print(f"feedback-note: {index_path} missing -- wrong memory dir?", file=sys.stderr)
        return 2
    note = mem / f"feedback-{slug}.md"
    if note.exists():
        print(f"feedback-note: {note.name} already exists; pick another --name or cancel it with --cancels",
              file=sys.stderr)
        return 2
    old = mem / f"feedback-{cancels}.md" if cancels else None
    if cancels == slug:
        print("feedback-note: a note cannot cancel itself", file=sys.stderr)
        return 2
    if old is not None and not old.is_file():
        print(f"feedback-note: {old.name} to cancel is missing", file=sys.stderr)
        return 2
    day = datetime.now(ZoneInfo(TZ)).strftime("%Y-%m-%d")
    pravki = Path(args.pravki).resolve() if args.pravki else None
    if pravki is not None and not pravki.is_file():
        print(f"feedback-note: {pravki} missing -- voice line skipped", file=sys.stderr)
        pravki = None
    old_pravki = pravki_of(old) if old is not None else None
    # Shared voice files may be written by other agents: lock them (sorted order, no deadlock).
    locks = [lock_file(path) for path in sorted({x for x in (pravki, old_pravki) if x is not None and x.is_file()})]
    try:
        return write_all(mem, index_path, note, old, slug, rule, area, source, why, cancels, day, pravki, old_pravki)
    finally:
        for fd in locks:
            os.close(fd)


def write_all(mem: Path, index_path: Path, note: Path, old: Path | None, slug: str, rule: str, area: str,
              source: str, why: str, cancels: str | None, day: str, pravki: Path | None,
              old_pravki: Path | None) -> int:
    """Prepare every carrier's new text and commit them together (voice files already locked)."""
    # Everything is prepared first and written as one step; any failure restores every file.
    writes: dict[Path, str] = {note: note_text(slug, rule, area, source, why, cancels, day, pravki)}
    if old_pravki is not None and old_pravki.is_file():
        writes[old_pravki] = without_line_of(old_pravki.read_text(encoding="utf-8"), note_id(mem, cancels or ""))
    if pravki is not None:
        base = writes.get(pravki, pravki.read_text(encoding="utf-8"))
        if base and not base.endswith("\n"):
            base += "\n"
        writes[pravki] = base + f"- {day} | {note_id(mem, slug)} | {rule} | {source}\n"
    writes[index_path] = index_with(index_path.read_text(encoding="utf-8"), slug, rule, area, cancels)
    commit(writes, old)
    print(f"feedback-note: wrote {note}" + (f", removed {old.name}" if old is not None else ""))
    if old_pravki is not None and old_pravki in writes:
        print(f"feedback-note: line of feedback-{cancels} removed from {old_pravki}")
    if pravki is not None:
        print(f"feedback-note: line added to {pravki}")
    return 0


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(prog="feedback-note.py")
    p.add_argument("memory_dir")
    sub = p.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("add")
    a.add_argument("--name", required=True)
    a.add_argument("--rule", required=True)
    a.add_argument("--area", required=True)
    a.add_argument("--source", required=True)
    a.add_argument("--why", default="")
    a.add_argument("--cancels")
    a.add_argument("--pravki")
    try:
        args = p.parse_args(argv)
    except SystemExit as exc:
        return 2 if exc.code else 0
    mem = Path(args.memory_dir)
    if not mem.is_dir():
        print(f"feedback-note: {mem} is not a directory", file=sys.stderr)
        return 2
    # One writer at a time: the index is read, changed and replaced as one step.
    with (mem / ".feedback-note.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            return add(args)
        except RollbackError as exc:
            print(f"feedback-note: stopped, fix by hand (nothing more was changed): {exc}", file=sys.stderr)
            return 3
        except OSError as exc:
            print(f"feedback-note: not written, every file put back ({exc})", file=sys.stderr)
            return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
