#!/usr/bin/env python3
"""Give the Auditor (Hermes) a task from another agent, or look at a task already given.

Installed by neurootdel-install next to the guard scripts. The bus is a folder in the agent user's home
(<home>/var/lib/auditor-bus): this script puts a letter into inbox/, the bridge (auditor-bridge.py, unit
hermes-auditor-bridge) hands it to the Auditor and brings the answer back into the sender's own chat session
through its local webhook. No secrets here and none needed.

    auditor-ask.py --from jarvis "Проверь отчёт: <путь к файлу>. Что с цифрами?"
    auditor-ask.py --from coder <<'EOF'
    длинная задача
    EOF
    auditor-ask.py --status <id>     # new / asked / done / failed, and the answer when there is one

Exit codes: 0 ok, 2 bad input, 3 the bus folder is missing (Auditor not installed).
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import sys
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import guard_conf  # noqa: E402

CONF = guard_conf.load()
BUS = Path(os.environ.get("AUDITOR_BUS_DIR") or CONF.agent_home / "var/lib/auditor-bus")
MAX_BODY = 64 * 1024
ID_RE = re.compile(r"^[0-9a-f]{32}$")
STATES = ("inbox", "work", "done", "failed")


def senders() -> list[str]:
    """Agents with a chat session the answer can come back to (CHANNEL_AGENTS of guard.conf)."""
    return list(CONF.channel_agents)


def put(sender: str, text: str) -> str:
    inbox = BUS / "inbox"
    if not inbox.is_dir():
        raise FileNotFoundError(str(inbox))
    task_id = uuid.uuid4().hex
    data = {"id": task_id, "from": sender, "text": text,
            "created_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")}
    tmp = inbox / f".{task_id}.tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, ensure_ascii=False)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, inbox / f"{task_id}.json")
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise
    return task_id


def status(task_id: str) -> tuple[str, dict]:
    for state in STATES:
        path = BUS / state / f"{task_id}.json"
        if path.is_file():
            try:
                return state, json.loads(path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                return state, {}
    return "unknown", {}


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Задача Аудитору через мост")
    ap.add_argument("--from", dest="sender", help="кто спрашивает: " + ", ".join(senders()))
    ap.add_argument("--status", metavar="ID", help="состояние задачи и ответ, если он уже есть")
    ap.add_argument("text", nargs="*", help="текст задачи; без него читается stdin")
    a = ap.parse_args(argv)

    if a.status:
        if not ID_RE.match(a.status):
            print("ОШИБКА: id задачи это 32 знака 0-9a-f", file=sys.stderr)
            return 2
        state, data = status(a.status)
        print(f"состояние: {state}")
        if data.get("answer"):
            print(data["answer"])
        elif data.get("error"):
            print(f"ошибка: {data['error']}")
        return 0

    if a.sender not in senders():
        print(f"ОШИБКА: --from {a.sender!r} не агент этого сервера, можно: {', '.join(senders())}", file=sys.stderr)
        return 2
    body = (" ".join(a.text) if a.text else sys.stdin.read()).strip()
    if not body:
        print("ОШИБКА: пустая задача", file=sys.stderr)
        return 2
    if len(body.encode("utf-8")) > MAX_BODY:
        print(f"ОШИБКА: задача больше {MAX_BODY // 1024} КБ, дай путь к файлу вместо текста", file=sys.stderr)
        return 2
    try:
        task_id = put(a.sender, body)
    except FileNotFoundError:
        print(f"ОШИБКА: нет папки {BUS / 'inbox'}: Аудитор на этом сервере не установлен", file=sys.stderr)
        return 3
    print(f"задача {task_id} у Аудитора в очереди; ответ придёт в этот чат сообщением «Ответ Аудитора»")
    return 0


if __name__ == "__main__":
    sys.exit(main())
