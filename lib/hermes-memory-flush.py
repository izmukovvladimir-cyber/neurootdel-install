#!/usr/bin/env python3
"""Ask the Auditor (hermes agent) to save what matters to its long-term memory BEFORE a session reset.

Installed by neurootdel-install into <lib dir> with the Auditor (stage intensive). Called by
hermes-auditor-reset.sh before a threshold reset, and nightly from /etc/cron.d/<user>-hermes-reset.

WHY. A reset (hermes-session-reset.py) drops the live conversation. With the engine's built-in
memory the agent writes MEMORY.md itself, so whatever it did not write is lost at the reset.

HOW. The agent's local api_server (API_SERVER_* in ~/.hermes/.env, written by the installer)
continues an EXISTING session when given its id in X-Hermes-Session-Id: it loads that session's
full history from state.db. So the flush prompt runs with the whole Telegram conversation in
context, the agent writes its memory, and the answer comes back here, not to the person's chat.

Only Telegram sessions with a message in the last --active-hours are flushed: a session idle since
the previous night has nothing new to save. The key is read from the env file, never printed.
A save counts only when it is checkable: the files of <home>/memories changed during that turn, or the
agent answered «нечего записывать». Anything else is a failed save (exit 1), and the reset waits.

Usage:
    hermes-memory-flush.py --home ~/.hermes [--env-file ~/.hermes/.env] [--api http://127.0.0.1:8642]
                           [--timeout 900] [--active-hours 24] [--dry-run]
Exit codes: 0 flushed or nothing to flush, 1 at least one flush failed (or no key / no api),
2 no state.db, 3 db unreadable (raised by hermes-session-reset.live_entries).
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import re
import sqlite3
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

BIN = Path(__file__).resolve().parent
sys.path.insert(0, str(BIN))
import guard_conf  # noqa: E402

KEY_RE = re.compile(r"[A-Za-z0-9._~+/=-]{16,512}")
MAX_ANSWER = 300


def _load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, BIN / filename)
    if spec is None or spec.loader is None:
        raise ImportError(filename)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


reset = _load("hermes_session_reset", "hermes-session-reset.py")


class FlushError(Exception):
    """A flush could not be done; the text never holds the key."""


def flush_prompt(owner: str) -> str:
    who = f"с владельцем ({owner})" if owner else "с владельцем"
    return (
        "Сброс переписки через несколько минут. Сейчас запиши в свою долгую память всё, "
        f"что должно пережить сброс: договорённости {who} и командой агентов, их правки и предпочтения, "
        "незаконченные проверки с тем, на чём остановился, и новые приёмы работы, которые сегодня "
        "сработали. Не дублируй то, что уже записано. Ничего не отправляй в Telegram. "
        "В ответе одной строкой перечисли, что записал, или напиши «нечего записывать»."
    )


FLUSH_PROMPT = flush_prompt(guard_conf.load().owner_name)


def log(msg: str) -> None:
    print(f"[memory-flush] {msg}", flush=True)


def env_value(path: Path, key: str) -> str:
    """KEY=value from an env file, quotes stripped; empty when the file or the key is missing."""
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError):
        return ""
    val = ""
    for line in lines:
        m = re.match(rf"^\s*{re.escape(key)}=(.*)$", line)
        if m:
            val = m.group(1).strip().strip("'\"")
    return val


def read_key(env_file: Path) -> str:
    key = env_value(env_file, "API_SERVER_KEY")
    if not key:
        raise FlushError(f"в {env_file} нет API_SERVER_KEY: api_server Аудитора не настроен (перезапусти установщик)")
    if not KEY_RE.fullmatch(key):
        raise FlushError(f"API_SERVER_KEY в {env_file} содержит недопустимые символы")
    return key


def send(text: str, base_url: str, key: str, timeout: float, session: str) -> str:
    """One turn in an existing session through the local api_server; returns the answer text."""
    body = json.dumps({"model": "hermes-agent", "messages": [{"role": "user", "content": text}]}).encode()
    req = urllib.request.Request(f"{base_url}/v1/chat/completions", data=body, method="POST")
    req.add_header("Authorization", f"Bearer {key}")
    req.add_header("Content-Type", "application/json")
    req.add_header("X-Hermes-Session-Id", session)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        raise FlushError(f"HTTP {exc.code} от {base_url}") from exc
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise FlushError(f"нет связи с {base_url}: {exc}") from exc
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise FlushError(f"ответ {base_url} не JSON") from exc
    choices = data.get("choices") if isinstance(data, dict) else None
    content = (choices[0].get("message") or {}).get("content") if choices and isinstance(choices[0], dict) else None
    if not isinstance(content, str) or not content.strip():
        raise FlushError("ответ без текста")
    return content.strip()


NOTHING_RE = re.compile(r"[«\"']?нечего записывать[»\"']?[.!]?", re.I)


def memory_state(home: Path) -> str | None:
    """Fingerprint of the built-in memory files (<home>/memories/*): name + content hash.
    "" when there is no memory dir yet; None when anything could not be read (the save is then unprovable)."""
    h = hashlib.sha256()
    d = home / "memories"
    if not d.exists():
        return ""
    errors: list[OSError] = []
    files: list[Path] = []
    # os.walk with onerror: an unreadable sub-dir must fail the proof, never look empty (rglob hides it).
    for root, _dirs, names in os.walk(d, onerror=errors.append):
        files.extend(Path(root) / n for n in names)
    if errors:
        return None
    if not files:
        return ""   # an empty memory dir proves nothing more than a missing one
    try:
        for f in sorted(files):
            h.update(f"{f.relative_to(d)}\0".encode() + hashlib.sha256(f.read_bytes()).digest())
    except OSError:
        return None
    return h.hexdigest()


def saved(before: str | None, after: str | None, answer: str) -> bool:
    """A save counts only when it is checkable: the memory files were read both times and changed, or the
    whole answer is «нечего записывать». Any other answer (an error, a refusal, words without a write)
    and any unreadable memory file hold the reset."""
    if before is None or after is None:
        return False
    return before != after or bool(NOTHING_RE.fullmatch(" ".join(answer.split())))


def still_live(db: Path, key: str, sid: str, marked_ok: bool = False) -> bool:
    """Re-read right before sending: a reset may have marked or replaced the session meanwhile."""
    for _scope, k, entry, _upd in reset.live_entries(db):
        if k == key and isinstance(entry, dict):
            return entry.get("session_id") == sid and (marked_ok or not entry.get("suspended"))
    return False


def unreadable_routes(db: Path) -> int:
    """Routing rows that live_entries() skips (bad JSON); any sqlite error counts as one."""
    try:
        c = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=10)
        total = c.execute("select count(*) from gateway_routing").fetchone()[0]
        c.close()
    except sqlite3.Error:
        return 1
    return max(total - len(reset.live_entries(db)), 0)


def route_set(db: Path) -> set[tuple[str, str, str]]:
    """(scope, session_key, session_id) of every routed session."""
    return {(scope, key, str(entry.get("session_id") or "")) for scope, key, entry, _upd in reset.live_entries(db)
            if isinstance(entry, dict)}


def targets(db: Path, active_hours: float, every: bool = False) -> list[tuple[str, str]]:
    """(session_key, session_id) of sessions that had a message within the window.

    every=True (the save before a threshold reset): every routed session of any platform and age, marked
    ones too (a mark lives only in the database until the restart; the running engine still serves that
    session, and words said after the mark must be saved before the restart drops it).
    """
    out = []
    for _scope, key, entry, _upd in reset.live_entries(db):
        sid = entry.get("session_id") if isinstance(entry, dict) else None
        # Nightly: only the person's unmarked Telegram conversations.
        if not sid or (not every and (entry.get("suspended") or entry.get("platform") != "telegram")):
            continue
        if every:
            out.append((key, sid))
            continue
        age = reset.last_message_age(db, sid)
        if age is None or age > active_hours * 3600:
            log(f"{key}: без свежих сообщений, пропускаю")
            continue
        out.append((key, sid))
    return out


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--home", required=True, type=Path)
    p.add_argument("--env-file", type=Path, help="default: <home>/.env")
    p.add_argument("--api", help="api_server base url; default: http://127.0.0.1:<API_SERVER_PORT of the env file>")
    p.add_argument("--timeout", type=float, default=900,
                   help="TOTAL budget in seconds, shared by all sessions")
    p.add_argument("--active-hours", type=float, default=24)
    p.add_argument("--all-sessions", action="store_true",
                   help="every routed session, any platform and age, marked ones too (the save before a threshold reset)")
    p.add_argument("--dry-run", action="store_true")
    a = p.parse_args(argv)

    db = a.home / "state.db"
    if not db.is_file():
        log(f"нет базы {db}")
        return 2
    if a.all_sessions and unreadable_routes(db):
        # A skipped route would be restarted unsaved with the others: no save, no reset (Codex r6).
        log("есть записи маршрутизации, которые не разбираются: сохранение перед сбросом не доказуемо")
        return 1
    route_set_before = route_set(db)
    todo = targets(db, a.active_hours, a.all_sessions)
    if not todo:
        log("сохранять нечего")
        return 0
    if a.dry_run:
        for key, sid in todo:
            log(f"{key}: сохранил бы память сессии {sid}")
        return 0
    env_file = a.env_file or a.home / ".env"
    port = env_value(env_file, "API_SERVER_PORT") or "8642"
    api = a.api or f"http://127.0.0.1:{port}"
    try:
        key_value = read_key(env_file)
    except FlushError as e:
        log(f"ключ недоступен: {e}")
        return 1
    failed = 0
    deadline = time.monotonic() + a.timeout
    for key, sid in todo:
        left = deadline - time.monotonic()
        if left < 30:
            failed = 1
            log(f"{key}: время вышло, сохранение НЕ запускал")
            continue
        if not still_live(db, key, sid, a.all_sessions):
            if a.all_sessions:
                failed = 1   # before a reset an unsaved changed route is a failed save (Codex r8)
            log(f"{key}: сессия уже помечена к сбросу или сменилась, пропускаю")
            continue
        before = memory_state(a.home)
        try:
            answer = send(FLUSH_PROMPT, api, key_value, left, sid)
            log(f"{key}: {answer.replace(chr(10), ' ')[:MAX_ANSWER]}")
        except FlushError as e:
            failed = 1
            log(f"{key}: сохранение НЕ удалось: {e}")
            continue
        if not saved(before, memory_state(a.home), answer):
            failed = 1
            log(f"{key}: файлы памяти не изменились и агент не ответил «нечего записывать» — сохранение не подтверждено")
    if a.all_sessions and not failed and route_set(db) != route_set_before:
        log("набор сессий изменился во время сохранения: сохранение не подтверждено, сброс подождёт")
        failed = 1
    return failed


if __name__ == "__main__":
    sys.exit(main())
