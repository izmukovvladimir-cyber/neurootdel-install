#!/usr/bin/env python3
"""Bridge between the agents of this server and the Auditor (Hermes): a task in, the answer back.

Installed by neurootdel-install, runs as the agent user under the unit hermes-auditor-bridge.

    agent  --auditor-ask.py-->  <home>/var/lib/auditor-bus/inbox/<id>.json
    bridge --POST /v1/chat/completions (Hermes api_server on 127.0.0.1, key API_SERVER_KEY from ~/.hermes/.env)
    bridge --POST /hooks/agent (the sender's own channel webhook, token from its channel.env)--> sender's session

Why a folder and a webhook: the installer has no shared bus of its own, and every channel agent already listens on a
local webhook (the guard nudges through it). The answer arrives in the sender's session as a normal message, so the
sender does not poll.

State lives on disk, one file per task, moved between folders:
  inbox/   new, nobody asked the Auditor yet
  work/    asked; a bridge that died mid-turn asks again at start (attempts counted, ATTEMPTS_MAX)
  done/    answered; "delivered" says whether the sender's webhook took it (retried each loop until it does
           or DELIVERY_MAX tries, DELIVERY_GAP_SEC apart, are spent: about ten minutes for a restarting agent)
  failed/  the Auditor could not answer ATTEMPTS_MAX times; the sender is told once
One task at a time: a Hermes turn takes minutes and two parallel turns would share one ChatGPT limit.

Stop: touch <home>/var/lib/auditor-bus/STOP (the bridge idles until the file is gone), or
      sudo systemctl disable --now hermes-auditor-bridge.
"""
from __future__ import annotations

import json
import logging
import math
import os
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
import guard_conf  # noqa: E402

log = logging.getLogger("auditor-bridge")

CONF = guard_conf.load()
BUS = Path(os.environ.get("AUDITOR_BUS_DIR") or CONF.agent_home / "var/lib/auditor-bus")
HERMES_ENV = Path(os.environ.get("AUDITOR_HERMES_ENV") or CONF.agent_home / ".hermes/.env")
HERMES_TIMEOUT = int(os.environ.get("AUDITOR_HERMES_TIMEOUT", "1800"))
POLL_SEC = float(os.environ.get("AUDITOR_POLL_SEC", "3"))
ATTEMPTS_MAX = 3
RETRY_GAP_SEC = 60   # a failed ask waits attempts * RETRY_GAP_SEC before the next one
DELIVERY_MAX = 20
DELIVERY_GAP_SEC = 30
MAX_ANSWER = 60 * 1024
ID_RE = re.compile(r"^[0-9a-f]{32}$")
REPLY_TITLE = "Ответ Аудитора"
ENGINE_ERROR_MARK = "⚠️"
PROMPT_NOTE = ("[Мост аудитора: эта задача пришла от агента «{sender}», id {id}. Отвечай обычным текстом, мост сам "
               "доставит ответ отправителю.]")


def env_value(path: Path, key: str) -> str:
    """KEY=value from an env file (last one wins, quotes stripped); "" when missing or unreadable. Never logged."""
    val = ""
    try:
        with path.open(encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line.startswith(f"{key}="):
                    val = line.split("=", 1)[1].strip().strip("'\"")
    except (OSError, UnicodeDecodeError):
        return ""
    return val


def hermes_url() -> str:
    port = env_value(HERMES_ENV, "API_SERVER_PORT") or "8642"
    return f"http://127.0.0.1:{port}/v1/chat/completions"


def _write(path: Path, data: dict[str, Any]) -> None:
    tmp = path.with_name(f".{path.name}.tmp")
    with tmp.open("w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False)
        fh.flush()
        os.fsync(fh.fileno())
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def _move(data: dict[str, Any], src: Path, state: str) -> Path:
    """Update the record where it is, then ONE atomic rename into the new state: a task is never in two folders."""
    dst = BUS / state / src.name
    _write(src, data)
    if src != dst:
        os.replace(src, dst)
    return dst


def _num(value: Any) -> float:
    """A bookkeeping number from a letter; anything odd counts as 0 (a broken field never stops the queue)."""
    try:
        num = float(value)
    except (TypeError, ValueError, OverflowError):
        return 0.0
    return num if math.isfinite(num) else 0.0


def load_task(path: Path) -> dict[str, Any] | None:
    """A letter we can work with, or None (it then goes to failed/ with the reason)."""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or not ID_RE.match(str(data.get("id", ""))) or path.stem != data["id"]:
        return None
    if data.get("from") not in CONF.channel_agents or not str(data.get("text", "")).strip():
        return None
    return data


def ask_hermes(data: dict[str, Any]) -> str:
    """The Auditor's answer text; raises RuntimeError with a short reason (never the key, never the answer)."""
    key = env_value(HERMES_ENV, "API_SERVER_KEY")
    if not key:
        raise RuntimeError("в ~/.hermes/.env нет API_SERVER_KEY")
    prompt = PROMPT_NOTE.format(sender=data["from"], id=data["id"]) + "\n\n" + str(data["text"])
    body = json.dumps({"model": "hermes-agent", "messages": [{"role": "user", "content": prompt}]}).encode()
    req = urllib.request.Request(hermes_url(), data=body, method="POST",
                                 headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=HERMES_TIMEOUT) as resp:
            reply = json.loads(resp.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"Hermes ответил HTTP {exc.code}") from None
    except (OSError, ValueError) as exc:
        raise RuntimeError(f"Hermes недоступен ({type(exc).__name__})") from None
    try:
        text = reply["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError):
        raise RuntimeError("в ответе Hermes нет текста") from None
    if not isinstance(text, str) or not text.strip():
        raise RuntimeError("Hermes вернул пустой ответ")
    text = text.strip()
    # The engine reports its own failures (no ChatGPT login, provider down) as a 200 answer starting with ⚠️.
    if text.startswith(ENGINE_ERROR_MARK):
        raise RuntimeError("Hermes: " + text.lstrip(ENGINE_ERROR_MARK).strip().splitlines()[0][:200])
    return text[:MAX_ANSWER]


def deliver(sender: str, text: str) -> bool:
    """Into the sender's chat session through its own local webhook (same call the guard nudges with)."""
    env = CONF.channel_env(sender)
    token, port = env_value(env, "TELEGRAM_WEBHOOK_TOKEN"), env_value(env, "TELEGRAM_WEBHOOK_PORT")
    if not token or not port.isdigit():
        return False
    req = urllib.request.Request(f"http://127.0.0.1:{port}/hooks/agent", method="POST",
                                 data=json.dumps({"message": text, "chatId": CONF.owner_tg_id}).encode(),
                                 headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status == 200
    except OSError:
        return False


def letter(data: dict[str, Any]) -> str:
    tid = str(data.get("id", "?"))[:40]
    if data.get("answer"):
        return f"[{REPLY_TITLE} на задачу {tid}]\n\n{data['answer']}"
    return (f"[{REPLY_TITLE} на задачу {tid}] Аудитор не ответил: {data.get('error', 'причина неизвестна')}. "
            "Задача не выполнена; повтори позже или скажи владельцу.")


def handle(path: Path) -> None:
    data = load_task(path)
    if data is None:
        bad = {"id": path.stem, "error": "письмо негодно (не JSON, чужой отправитель или пустой текст)"}
        _move(bad, path, "failed")
        log.warning("task %s rejected", path.stem[:40])
        return
    if _num(data.get("attempts")) >= ATTEMPTS_MAX:   # a task that already used its tries (recovered after a crash)
        data["error"] = data.get("error") or "мост падал во время каждой попытки"
        data["delivered"] = deliver(data["from"], letter(data))
        _move(data, path, "failed")
        log.warning("task %s failed: attempts used up", data["id"])
        return
    data["attempts"] = int(_num(data.get("attempts"))) + 1
    work = _move(data, path, "work")
    try:
        data["answer"] = ask_hermes(data)
    except RuntimeError as exc:
        data["error"] = str(exc)
        if data["attempts"] < ATTEMPTS_MAX:
            data["retry_at"] = time.time() + RETRY_GAP_SEC * data["attempts"]
            _move(data, work, "inbox")
            log.warning("task %s: %s, will retry", data["id"], exc)
            return
        data["delivered"] = deliver(data["from"], letter(data))
        _move(data, work, "failed")
        log.warning("task %s failed: %s", data["id"], exc)
        return
    data.pop("error", None)
    data["answered_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    # The answer is saved in done/ BEFORE the webhook call: a bridge stopped during delivery never asks again,
    # redeliver() finishes the delivery from the saved record.
    data.update(delivered=False, deliveries=1, delivery_at=time.time())
    done = _move(data, work, "done")
    data["delivered"] = deliver(data["from"], letter(data))
    _write(done, data)
    log.info("task %s answered, delivered=%s", data["id"], data["delivered"])


def redeliver() -> None:
    for path in sorted((BUS / "done").glob("*.json")):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            if not isinstance(data, dict) or data.get("delivered") or _num(data.get("deliveries")) >= DELIVERY_MAX:
                continue
            if time.time() - _num(data.get("delivery_at")) < DELIVERY_GAP_SEC:
                continue
            data["deliveries"] = int(_num(data.get("deliveries"))) + 1
            data["delivery_at"] = time.time()
            data["delivered"] = deliver(str(data.get("from", "")), letter(data))
            _write(path, data)
        except Exception:  # noqa: BLE001 - one broken record must not stop the queue
            log.exception("redelivery of %s failed, record left as it is", path.stem[:40])
            continue


def recover() -> None:
    """Start: a task asked by a bridge that died is asked again (counted as an attempt). A copy that already
    reached done/ or failed/ (a crash of an older bridge between write and delete) is dropped, never re-asked.
    A record that already holds the answer (the bridge died between saving it and the move) goes to done/:
    redeliver() finishes the delivery if it did not happen, the Auditor is not asked again."""
    for path in sorted((BUS / "work").glob("*.json")):
        if (BUS / "done" / path.name).exists() or (BUS / "failed" / path.name).exists():
            path.unlink(missing_ok=True)
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            data = None
        if isinstance(data, dict) and data.get("answer"):
            data.setdefault("delivered", False)
            _move(data, path, "done")
        else:
            os.replace(path, BUS / "inbox" / path.name)


def tick() -> bool:
    """One pass; True when a task was handled."""
    if (BUS / "STOP").exists():
        return False
    redeliver()
    for path in sorted((BUS / "inbox").glob("*.json"), key=lambda p: p.stat().st_mtime):
        if _waiting(path):
            continue
        try:
            handle(path)
        except Exception as exc:  # noqa: BLE001 - one broken letter must not stop the queue (systemd loop)
            log.exception("task %s crashed the handler", path.stem[:40])
            for state in ("work", "inbox"):
                stuck = BUS / state / path.name
                if stuck.exists():
                    os.replace(stuck, BUS / "failed" / path.name)
            _note_failed(path.name, f"мост не смог обработать письмо ({type(exc).__name__})")
        return True
    return False


def _note_failed(name: str, reason: str) -> None:
    path = BUS / "failed" / name
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        data = data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        data = {}
    data["error"] = reason
    try:
        _write(path, data)
    except OSError:
        log.warning("could not note the failure of %s", name[:40])


def _waiting(path: Path) -> bool:
    """True while a task that failed before waits for its retry time."""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return isinstance(data, dict) and time.time() < _num(data.get("retry_at"))
    except (OSError, ValueError):
        return False


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    for state in ("inbox", "work", "done", "failed"):
        (BUS / state).mkdir(parents=True, exist_ok=True)
    recover()
    once = "--once" in sys.argv[1:]
    while True:
        busy = tick()
        if once:
            return 0
        if not busy:
            time.sleep(POLL_SEC)


if __name__ == "__main__":
    sys.exit(main())
