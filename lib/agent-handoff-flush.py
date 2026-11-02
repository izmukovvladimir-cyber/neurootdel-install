#!/usr/bin/env python3
"""agent-handoff-flush.py — генерирует handoff.md для агента из JSONL-логов.

Запускается перед daily-reset, чтобы новый сеанс агента после /clear
видел в handoff.md последние 10-15 ключевых действий и понимал контекст.

Usage:
    agent-handoff-flush.py <agent_name>

Что считается ключевым действием:
- Edit / Write — файл который агент трогал
- Bash — git / systemctl / rsync / cron / curl / python-скрипты
- MCP-вызовы create_decision_note / create_runbook_note / create_error_pattern_note
- MCP-вызовы task_done / task_review (gbrain-tasks)

Что игнорируется:
- Read / Glob / Grep (просто чтение, не изменение)
- ls / cat / wc / echo (info-команды)
- TaskCreate / TaskUpdate (если без content)

Формат handoff.md (последние 15 записей за 24h):
    {HH:MM} — {agent_action}

Пишет в:
- ~/.claude-lab/<agent>/.claude/core/hot/handoff.md
- gbrain decision_note daily_summary_<agent>_<YYYY-MM-DD> (опционально, если bearer есть)
"""
from __future__ import annotations
import fcntl
import json
import os
import re
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Iterable
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

sys.path.insert(0, str(Path(__file__).resolve().parent))
import guard_conf  # noqa: E402  (lives next to this script)

# The channel agents from guard.conf. Richard runs SDK sessions and is not reset,
# so it is not flushed either.
CONF = guard_conf.load()
AGENT_TO_JSONL_DIR = {a: CONF.project_prefix(a) for a in CONF.channel_agents}
AGENT_TO_WORKSPACE = {a: str(CONF.workspace(a)) for a in CONF.channel_agents}

CLIENT_AGENTS: tuple[str, ...] = ()

JSONL_ROOT = CONF.projects
HOME_PREFIX = str(CONF.agent_home).rstrip("/") + "/"
# Times in handoff.md are in the owner's timezone (guard.conf OWNER_TIMEZONE).
try:
    MSK = ZoneInfo(CONF.owner_timezone)
except (ZoneInfoNotFoundError, ValueError):
    MSK = timezone(timedelta(hours=3))
DRY_RUN = False
MAX_ENTRIES = 15
WINDOW_HOURS = 24
# Marker that separates the hand-written sticky part from the generated one.
# Kept as a constant so the writer and the preserving reader cannot drift apart.
AUTO_MARKER = "## Last "
# The reader matches a WHOLE heading line, not the bare prefix: a sticky sentence
# containing "## Last " mid-text would otherwise truncate everything below it.
# The heading alone is not enough: a human quoting it inside the sticky part would
# cut everything below the quote. The generated section always carries its own
# "Auto-flushed by" line right after the heading, so both are required.
AUTO_MARKER_RE = re.compile(
    r"^## Last \d+ actions \(auto-generated\)\s*\n+Auto-flushed by agent-handoff-flush\.py",
    re.M,
)

# Closing fence of the generated section, added 2026-09-12. Before it the section
# ran to the end of the file, so anything appended below it (a `cat >>` from an
# agent writing its day down) was treated as generated and dropped by the next
# tick — an agent lost eight blocks in one day that way.
AUTO_END_MARKER = "<!-- end agent-handoff-flush -->"
AUTO_END_RE = re.compile(r"^" + re.escape(AUTO_END_MARKER) + r"\s*$", re.M)

# Lines the generator itself produces. Used only while migrating a file that has
# no end marker yet: everything below the header that does NOT look like our own
# output is hand-written and must be carried over.
AUTO_ENTRY_RE = re.compile(r"^- \*\*\d{2}\.\d{2} \d{2}:\d{2}\*\* \u2014 ")
AUTO_IDLE_RE = re.compile(r"^_\(no key actions in the last \d+h")
AUTO_HEADER_RE = re.compile(r"^(## Last \d+ actions \(auto-generated\)|Auto-flushed by |Window: last )")

BORING_BASH = re.compile(
    r"^\s*(ls|cat|head|tail|wc|echo|pwd|which|stat|file|grep|find|du|df|date|printf)\b"
)
INTERESTING_BASH = re.compile(
    r"\b(git\s+(?:commit|push|tag|merge|checkout|reset|revert|rebase)"
    r"|systemctl\s+(?:start|stop|restart|reload|enable|disable)"
    r"|rsync|scp|sftp"
    r"|cron|crontab"
    r"|curl\s+-\w*X?\s*POST"
    r"|python3?\s+\S+\.py"
    r"|npm\s+(?:run|publish|install)"
    r"|pnpm\s+(?:build|deploy)"
    r"|docker\s+(?:run|build|push|pull)"
    r"|kubectl\s+(?:apply|delete)"
    r"|psql|sqlite3"
    r"|sudo\s+(?:systemctl|tee|cp|mv|rm)"
    r")\b"
)
MCP_INTERESTING = {
    "mcp__gbrain-memory__create_decision_note",
    "mcp__gbrain-memory__create_runbook_note",
    "mcp__gbrain-memory__create_error_pattern_note",
    "mcp__gbrain-memory__supersede_decision",
    "mcp__gbrain-tasks__task_done",
    "mcp__gbrain-tasks__task_review",
    "mcp__gbrain-tasks__task_block",
    "mcp__gbrain-swarm__notify",
    "mcp__gbrain-swarm__ack",
}


def iter_tool_uses(jsonl_path: Path, since_iso: str) -> Iterable[dict]:
    """Yield {ts, type, name, summary} for each interesting tool_use since since_iso."""
    try:
        with jsonl_path.open() as fh:
            for line in fh:
                try:
                    d = json.loads(line)
                except json.JSONDecodeError:
                    continue
                # A syntactically valid line may still be a list, a number or null.
                if not isinstance(d, dict):
                    continue
                ts = d.get("timestamp")
                if not isinstance(ts, str) or not ts or ts < since_iso:
                    continue
                if d.get("type") != "assistant":
                    continue
                msg = d.get("message")
                if not isinstance(msg, dict):
                    msg = {}
                content = msg.get("content") or []
                if not isinstance(content, list):
                    continue
                for block in content:
                    if not isinstance(block, dict):
                        continue
                    if block.get("type") != "tool_use":
                        continue
                    # One malformed record must not abort the whole flush: the
                    # journal is written by many tools and its field types are
                    # not ours to guarantee.
                    try:
                        summary = summarize_tool_use(block)
                    except Exception:
                        continue
                    if summary:
                        yield {"ts": ts, "name": block.get("name", "?"), "summary": summary}
    except OSError:
        return


def summarize_tool_use(block: dict) -> str | None:
    name = block.get("name", "")
    inp = block.get("input")
    if not isinstance(inp, dict):
        inp = {}
    if name == "Edit":
        path = inp.get("file_path", "?")
        return f"Edit {short_path(path)}"
    if name == "Write":
        path = inp.get("file_path", "?")
        return f"Write {short_path(path)}"
    if name == "Bash":
        cmd = str(inp.get("command") or "").strip()
        if not cmd or BORING_BASH.match(cmd):
            return None
        if INTERESTING_BASH.search(cmd):
            return f"Bash: {short_cmd(cmd)}"
        return None
    if name == "NotebookEdit":
        return f"NotebookEdit {short_path(inp.get('notebook_path', '?'))}"
    if name in MCP_INTERESTING:
        short_name = name.split("__")[-1]
        # task_id приходит числом (доска gbrain нумерует задачи int), поэтому
        # приводим к строке до среза: иначе весь флаш падает на первой же записи.
        # Выбор по "поле присутствует", а не по truthiness: task_id=0 иначе теряется.
        title = ""
        for key in ("title", "task_id", "to_agent"):
            val = inp.get(key)
            if val is not None and str(val).strip():
                title = str(val)
                break
        title = title.replace("\n", " ").strip()
        return f"MCP {short_name}: {title[:60]}" if title else f"MCP {short_name}"
    return None


def short_path(p: str) -> str:
    p = str(p)
    if p.startswith(HOME_PREFIX):
        return p[len(HOME_PREFIX):]
    return p


def short_cmd(cmd: str, limit: int = 80) -> str:
    cmd = cmd.replace("\n", " ").strip()
    if len(cmd) > limit:
        return cmd[:limit].rstrip() + "…"
    return cmd


def dedup_keep_last(entries: list[dict]) -> list[dict]:
    """Keep last occurrence of each (name, summary) pair, preserve order."""
    seen: dict[tuple, int] = {}
    result: list[dict] = []
    for e in entries:
        key = (e["name"], e["summary"])
        if key in seen:
            result[seen[key]] = e
        else:
            seen[key] = len(result)
            result.append(e)
    return result


def jsonl_root(agent: str) -> Path:
    """Where this agent's session files live.

    Internal agents share ~/.claude/projects. Client agents run with their own
    CLAUDE_CONFIG_DIR, so their sessions are inside their workspace and are
    invisible under the shared root.
    """
    if agent in CLIENT_AGENTS:
        return Path(AGENT_TO_WORKSPACE[agent]) / ".claude-config" / "projects"
    return JSONL_ROOT


def resolve_jsonl_dirs(agent: str) -> list[Path]:
    """All project dirs holding this agent's sessions, newest-relevant first.

    The base name was the only dir until the dashi-plugin migration; live sessions
    now land in "<base>-dashi-plugin-claude-code-plugin". Reading the base alone
    made every flush report "no key actions". Any dir whose name starts with the
    base belongs to the same agent (the agent name is part of the base), so the
    prefix cannot pull in a neighbour's sessions.

    The one pair worth naming is agent-a / agent-a-extra, where the
    second name extends the first. They stay apart because the separator after the
    base is "--claude": "…agent-a-extra--claude" does not start with
    "…agent-a--claude-". Their roots differ as well (each client agent reads
    only its own workspace), so this is belt and braces.
    """
    base = AGENT_TO_JSONL_DIR[agent]
    root = jsonl_root(agent)
    try:
        if not root.is_dir():
            return []
        candidates = sorted(root.iterdir())
    except OSError:
        return []
    # Exactly the base, or the base followed by a path separator ("-" in the
    # flattened project-dir naming). "<base>x-anything" is a different workspace
    # and must not be read, even though it starts with the same characters.
    # is_symlink first: is_dir() follows links, so a link named like this agent's
    # dir would pull another workspace's journal into this agent's handoff.
    return [p for p in candidates
            if not p.is_symlink() and p.is_dir()
            and (p.name == base or p.name.startswith(base + "-"))]


# Our own heading left alone at the very end of the hand-written part: the generated
# body under it was cut away by hand. AUTO_MARKER_RE no longer sees it, so every flush
# kept it as sticky text and wrote a second heading below. Nothing can follow it, so
# dropping it loses no hand-written text.
ORPHAN_HEADING_RE = re.compile(r"(?:\A|\n)## Last \d+ actions \(auto-generated\)[ \t]*\s*\Z")


def drop_orphan_headings(text: str) -> str:
    """Strip trailing bare copies of our heading; text before them is returned unchanged."""
    while True:
        m = ORPHAN_HEADING_RE.search(text)
        if m is None:
            return text
        text = text[:m.start()]


def split_sticky(existing: str) -> str:
    """Return the hand-written part of handoff.md that must survive the flush.

    Fail-CLOSED on purpose: when the auto marker is absent (a human rewrote the
    file without it), the whole file is sticky. The old code treated a missing
    marker as "nothing to keep" and silently destroyed the header — that is how
    an open-items block was lost on 2026-07-28.
    """
    existing = drop_orphan_headings(existing)
    bounds = auto_bounds(existing)
    if bounds is None:
        return existing.rstrip() + "\n\n" if existing.strip() else ""

    # Everything above the section is kept as-is. Cutting out an "extra" section
    # found higher up looked tempting, but a hand-written quote of the whole block
    # (heading + Auto-flushed line + the end marker on its own line) is byte-for-byte
    # indistinguishable from a real one, and the text a person wrote between those
    # lines would go with it (Codex, round 2, 2026-09-12). More than one closed
    # section is treated as a file we do not understand — see _flush_locked.
    head = drop_orphan_headings(existing[:bounds[0]])
    return head.rstrip() + "\n\n" if head.strip() else ""


def auto_spans(existing: str) -> list[tuple[int, int]]:
    """Every CLOSED generated section, in order: heading .. its FIRST end marker.

    First end marker after each heading, not the last one in the file: an agent
    quoting the end marker on its own line below the section would otherwise
    stretch the span down to that quote and delete everything in between
    (Codex, 2026-09-12; this exact shape was asked about beforehand).
    """
    spans: list[tuple[int, int]] = []
    pos = 0
    for begin in AUTO_MARKER_RE.finditer(existing):
        if begin.start() < pos:
            continue  # heading swallowed by the section already taken
        end = AUTO_END_RE.search(existing, begin.end())
        if end is None:
            break
        spans.append((begin.start(), end.end()))
        pos = end.end()
    return spans


def auto_bounds(existing: str) -> tuple[int, int] | None:
    """Character span of the generated section we are going to replace.

    Without an end marker (a file written before 2026-09-12) the section still
    runs to EOF, exactly as it used to — split_tail rescues the hand-written
    lines in that case.
    """
    spans = auto_spans(existing)
    if spans:
        return spans[-1]

    # Last match, not first: the generated section is always the tail of the file,
    # so anything that looks like it earlier belongs to the hand-written part.
    begins = list(AUTO_MARKER_RE.finditer(existing))
    if not begins:
        return None
    return begins[-1].start(), len(existing)


def split_tail(existing: str) -> str:
    """Return the hand-written text that sits BELOW the generated section.

    Added 2026-09-12. An agent appending its day with `cat >>` always lands at
    the end of the file, i.e. below the section, and every tick dropped it.
    """
    bounds = auto_bounds(existing)
    if bounds is None:
        return ""
    start, end = bounds

    if AUTO_END_RE.search(existing[start:end]):
        return existing[end:].strip("\n")

    # Migration path, for a file that has no end marker yet. Everything from the
    # FIRST line we could not have written ourselves is hand-written, including
    # lines below it that merely LOOK like our output: an agent writing its day
    # down uses our own bullet shape often enough (Codex, 2026-09-12).
    lines = existing[start:end].split("\n")
    for i, line in enumerate(lines):
        if not line.strip():
            continue
        if AUTO_HEADER_RE.match(line) or AUTO_ENTRY_RE.match(line) or AUTO_IDLE_RE.match(line):
            continue
        return "\n".join(lines[i:]).strip("\n")
    return ""


def handwritten_changed(existing: str, backup_path: Path) -> bool:
    """True when the hand-written part differs from what the backup already holds.

    Compares sticky+tail, not the whole file: the generated section changes on
    every tick, so comparing bytes would back up every 10 minutes and the single
    previous copy would be gone before anyone noticed a loss. A missing or
    unreadable backup counts as changed — better a redundant copy than none.
    """
    try:
        previous = backup_path.read_text(encoding="utf-8")
    except (FileNotFoundError, OSError, UnicodeDecodeError):
        return True
    return (split_sticky(existing), split_tail(existing)) != (
        split_sticky(previous), split_tail(previous))


MISSING = object()   # "the target did not exist when we read it"


class StaleTarget(Exception):
    """The target changed between reading it and replacing it."""


def atomic_write(path: Path, text: str, expect: object | None = None) -> None:
    """Write via a UNIQUE temp file in the same dir, then rename over the target.

    Plain write_text() truncates first, so a crash or a full disk mid-write would
    leave handoff.md empty — the very loss this script already caused once.
    The temp name is unique (mkstemp) so two concurrent runs cannot scribble over
    each other's half-written buffer, and it is removed on any failure.

    Threat model note: paths are refused if the leaf is a symlink, but symlinked
    parent dirs are NOT defended against. Every service here runs as the single
    agent uid, so there is no privilege boundary to cross; the check exists
    to catch an accidental link, not an attacker who already has this account.
    """
    mode: int | None = None
    try:
        mode = os.stat(path, follow_symlinks=False).st_mode & 0o777
    except FileNotFoundError:
        mode = None

    fd, tmp_name = tempfile.mkstemp(dir=str(path.parent), prefix=path.name + ".tmp-")
    tmp = Path(tmp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        # Keep the previous permissions; a fresh mkstemp file is 0600 and would
        # silently tighten a file other tooling reads.
        os.chmod(tmp, mode if mode is not None else 0o644)
        # Last look at the target immediately before swapping it in. This does not
        # make the check-and-replace atomic — POSIX offers no such primitive for a
        # plain file — but it shrinks the race from "the whole journal scan" to a
        # couple of syscalls. A hand edit that lands inside that window is still
        # usually recoverable from <handoff>.bak-autoflush — though not when the
        # hand edit lands INSIDE that window: the backup was taken before it, so
        # that particular edit is in neither file (Codex, round 2, 2026-09-12).
        if expect is MISSING:
            # There was no file when we read; if one appeared meanwhile it is
            # somebody's work, not ours to overwrite (Codex, 2026-09-12).
            if os.path.lexists(path):
                raise StaleTarget(f"{path} appeared while flushing")
        elif expect is not None:
            st_now = os.stat(path, follow_symlinks=False)
            if (st_now.st_mtime_ns, st_now.st_size) != expect:
                raise StaleTarget(f"{path} changed under us")
        os.replace(tmp, path)
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise
    # The rename already succeeded, so a failure to fsync the directory only means
    # the rename may not survive a power cut. Raising here would report ERR for a
    # file that IS updated, which reads as a worse state than it is.
    try:
        dir_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    except OSError:
        pass


def flush_for_agent(agent: str) -> str:
    """Rewrite the agent's handoff.md. Never raises: cron reads the returned line."""
    if agent not in AGENT_TO_JSONL_DIR:
        return f"ERR: unknown agent {agent}"
    try:
        return _flush_locked(agent)
    except Exception as exc:  # noqa: BLE001 — cron reads the line, not a traceback
        # An unreadable projects dir or an unwritable core/hot must not take down
        # the flush of the other agents, and must not print a bare traceback into a
        # 04:00 cron log nobody reads. Catching only OSError left ValueError and
        # friends free to abort the whole --all run (Codex, 2026-07-29).
        return f"ERR {agent}: {exc.__class__.__name__} {exc}"


def _flush_locked(agent: str) -> str:
    jsonl_dirs = resolve_jsonl_dirs(agent)
    if not jsonl_dirs:
        return f"ERR: jsonl dir missing {jsonl_root(agent) / AGENT_TO_JSONL_DIR[agent]}*"

    workspace = Path(AGENT_TO_WORKSPACE[agent])
    handoff_path = workspace / "core" / "hot" / "handoff.md"
    if not DRY_RUN and not handoff_path.parent.is_dir():
        handoff_path.parent.mkdir(parents=True, exist_ok=True)

    since_dt = datetime.now(timezone.utc) - timedelta(hours=WINDOW_HOURS)
    since_iso = since_dt.isoformat().replace("+00:00", "Z")

    entries: list[dict] = []
    for jsonl_dir in jsonl_dirs:
        for jsonl in sorted(jsonl_dir.glob("*.jsonl")):
            entries.extend(iter_tool_uses(jsonl, since_iso))

    entries.sort(key=lambda e: e["ts"])
    entries = dedup_keep_last(entries)
    # dedup keeps the slot of the first occurrence; re-sort so the slice keeps the newest.
    entries.sort(key=lambda e: e["ts"])
    entries = entries[-MAX_ENTRIES:]

    now_msk = datetime.now(MSK).strftime("%Y-%m-%d %H:%M %Z")

    # Sticky-header preservation: всё что выше "## Last 15 actions" — сохраняем.
    # Это позволяет вручную добавить sticky-уведомление (post-optimization notice,
    # известные блокеры и т.п.) которое переживёт auto-flush.
    # Symlinks are refused outright on every path we write. This script runs as
    # the only writer of handoff.md; following a link would rewrite someone else's
    # file by accident.
    backup_path = handoff_path.with_name(handoff_path.name + ".bak-autoflush")
    lock_path = handoff_path.with_name(handoff_path.name + ".lock")
    blocked_path = handoff_path.with_name(handoff_path.name + ".flush-blocked")
    # The lock file is opened for writing before anything else, so it has to be
    # checked here too: opening a symlinked lock with "w" truncates its target
    # (Codex, 2026-09-12). Same for the second backup generation.
    for p in (handoff_path, backup_path,
              backup_path.with_name(backup_path.name + ".1"), lock_path, blocked_path):
        if p.is_symlink():
            return f"ERR: {p} is a symlink, refusing to write"

    if DRY_RUN:
        return f"DRY {agent}: would write {len(entries)} entries to {handoff_path} (nothing written)"

    # One lock over read → backup → write. Cron runs this per agent and a human
    # may run it by hand at the same moment; without the lock the two runs can
    # interleave and the later one writes a sticky it never read.
    with lock_path.open("w") as lock_fh:
        fcntl.flock(lock_fh.fileno(), fcntl.LOCK_EX)

        sticky_header = ""
        tail = ""
        seen_stamp: object | None = MISSING
        if handoff_path.exists():
            # stat, read, stat again: a change landing between them is never taken
            # for the version we read (the swap below compares against this stamp).
            st = handoff_path.stat()
            existing = handoff_path.read_text(encoding="utf-8")
            st2 = handoff_path.stat()
            seen_stamp = (st.st_mtime_ns, st.st_size)
            if (st2.st_mtime_ns, st2.st_size) != seen_stamp:
                return (f"ERR {agent}: handoff.md changed while reading, "
                        f"not overwriting {handoff_path}")
            spans = auto_spans(existing)
            if len(spans) > 1:
                # We write exactly one section. Two means either a hand edit gone
                # wrong or somebody quoting the block verbatim in their notes, and
                # the two cannot be told apart from the text. Touching the file
                # would delete whatever a person wrote between those lines, so we
                # refuse. The refusal repeats every tick and only the log would
                # know, so a marker file is dropped NEXT to handoff.md: the agent
                # sees it in its own hot/ directory (Codex, round 3).
                note = (f"Флаш остановлен {now_msk}: в handoff.md {len(spans)} "
                        f"генерируемых секций вместо одной.\n"
                        f"Скорее всего маркер процитирован дословно в записи. "
                        f"Убери лишнюю пару строк, и флаш пойдёт сам.\n"
                        f"Пока этот файл лежит здесь, авто-секция НЕ обновляется.\n")
                try:
                    atomic_write(blocked_path, note)
                except OSError:
                    pass
                return (f"ERR {agent}: {len(spans)} generated sections in "
                        f"{handoff_path}, refusing to rewrite (quoted marker?)")
            sticky_header = split_sticky(existing)
            tail = split_tail(existing)
            # Backup before overwrite: handoff carries hand-written open items and
            # this script is the only thing that ever rewrites it unattended.
            # Only when the hand-written part actually changed: the flush ticks
            # every 10 minutes, and an unconditional copy meant the one backup was
            # overwritten with already-damaged content long before anyone looked
            # at it (2026-09-12). Two generations for the same reason.
            if existing.strip() and handwritten_changed(existing, backup_path):
                if backup_path.exists():
                    # Rename, not copy: a copy plus a failure before the new backup
                    # is written leaves two identical generations and drops the older
                    # one for nothing (Codex, round 2). os.replace is atomic, so the
                    # worst case here is "the previous backup now sits in .1".
                    os.replace(backup_path, backup_path.with_name(backup_path.name + ".1"))
                atomic_write(backup_path, existing)

        # Print the real root: a client agent's sessions are NOT under ~/.claude,
        # and a source line that claims they are sends the next reader to an
        # empty directory.
        sources = ", ".join(f"{d}/*.jsonl" for d in jsonl_dirs)
        auto_lines = [
            f"{AUTO_MARKER}{MAX_ENTRIES} actions (auto-generated)",
            "",
            f"Auto-flushed by agent-handoff-flush.py at {now_msk}.",
            f"Window: last {WINDOW_HOURS}h. Source: {sources}",
            "",
        ]
        if not entries:
            auto_lines.append("_(no key actions in the last 24h — agent was idle or only doing reads)_")
        else:
            for e in entries:
                try:
                    ts = datetime.fromisoformat(e["ts"].replace("Z", "+00:00")).astimezone(MSK)
                    hhmm = ts.strftime("%d.%m %H:%M")
                except ValueError:
                    hhmm = e["ts"][:16]
                auto_lines.append(f"- **{hhmm}** — {e['summary']}")

        if not sticky_header:
            # No previous sticky → write default minimal header
            sticky_header = f"# handoff.md — last actions (@include)\n\nAuto-generated by agent-handoff-flush.py + manual sticky-header preserved across flushes.\n\n"

        # Compare-and-swap: a human (or an agent) may have edited handoff.md while
        # this run was reading journals. flock only holds off other flush runs, so
        # without this check their edit would be silently overwritten by the sticky
        # we read minutes earlier.
        body = sticky_header + "\n".join(auto_lines) + "\n" + AUTO_END_MARKER + "\n"
        if tail:
            body += "\n" + tail + "\n"
        try:
            atomic_write(handoff_path, body, expect=seen_stamp)
        except StaleTarget:
            return (f"ERR {agent}: handoff.md changed while flushing, "
                    f"not overwriting {handoff_path}")
        # Still under the lock: a marker left by an earlier refusal is stale now, and
        # dropping it outside the lock could delete a marker another run has just
        # written for a real problem (Codex, round 4).
        blocked_path.unlink(missing_ok=True)
    return f"OK {agent}: wrote {len(entries)} entries (sticky-header preserved) to {handoff_path}"


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: agent-handoff-flush.py [--dry-run] <agent> [<agent> ...]", file=sys.stderr)
        print(f"known agents: {', '.join(AGENT_TO_JSONL_DIR.keys())}", file=sys.stderr)
        return 2
    global DRY_RUN
    agents = sys.argv[1:]
    if agents[:1] == ["--dry-run"]:
        DRY_RUN, agents = True, agents[1:]
    if agents == ["--all"]:
        agents = list(AGENT_TO_JSONL_DIR.keys())
    rc = 0
    for a in agents:
        result = flush_for_agent(a)
        print(result)
        # Every failure path starts with "ERR"; matching the narrower "ERR:" once
        # made an OSError exit 0 and a cron failure looked like a success.
        if result.startswith("ERR"):
            rc = 1
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
