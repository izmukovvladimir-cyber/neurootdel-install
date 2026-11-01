#!/usr/bin/env python3
"""Put ONE alert of a service watchdog where agents-guard.py puts its own (installed by the installer).

Same item format as agents-guard.py Guard.alert(): {"id", "at_msk", "key", "text"}, id is
"<ms>-<sha256(key)[:8]>" (the --ack regex of agents-guard.py), so `agents-guard.py --drain`
shows these items too. Route = ALERT_MODE in guard.conf, as for the guard:
  outbox   (default) item in /var/lib/<user>-guard/outbox, nothing leaves the server;
  telegram the same item plus a message through the Richard bot to ALERT_TG_CHAT_ID / owner;
  log      a line in /var/log/<user>-guard.log only.
De-duplication is the caller's job (cooldown / signature state of each watchdog).

Usage (root): outbox-put.py KEY TEXT
"""
from __future__ import annotations

import hashlib
import json
import os
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

sys.path.insert(0, str(Path(__file__).resolve().parent))
import guard_conf  # noqa: E402

CONF = guard_conf.load()
USER = CONF.agent_user
STATE_DIR = Path(os.environ.get("NEUROOTDEL_GUARD_STATE") or f"/var/lib/{USER}-guard")  # env: tests
OUTBOX = STATE_DIR / "outbox"
LOG = Path(os.environ.get("NEUROOTDEL_GUARD_LOG") or f"/var/log/{USER}-guard.log")
MSK = timezone(timedelta(hours=3))


def owner_stamp() -> str:
    """Item time on the owner's clock (field name at_msk kept for the --drain/--ack format)."""
    try:
        tz = ZoneInfo(CONF.owner_timezone)
    except (ZoneInfoNotFoundError, ValueError):
        return f"{datetime.now(MSK):%d.%m %H:%M} МСК"
    now = datetime.now(tz)
    if now.utcoffset() == timedelta(hours=3):
        return f"{now:%d.%m %H:%M} МСК"
    return f"{now:%d.%m %H:%M} {now.tzname()}"


def env_value(path: str, key: str) -> str:
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if line.startswith(key + "="):
                return line.split("=", 1)[1].strip().strip('"')
    return ""


def send_telegram(text: str) -> bool:
    chat = CONF.alert_tg_chat_id or CONF.owner_tg_id
    if not chat or not CONF.richard_env:
        return False
    try:
        token = env_value(CONF.richard_env, "TELEGRAM_BOT_TOKEN")
    except OSError:
        return False
    if not token:
        return False
    data = urllib.parse.urlencode({"chat_id": chat, "text": text[:4000]}).encode()
    try:
        with urllib.request.urlopen(f"https://api.telegram.org/bot{token}/sendMessage", data=data,
                                    timeout=20) as resp:
            return json.loads(resp.read()).get("ok") is True
    except (OSError, ValueError):
        return False


def log_line(msg: str) -> None:
    try:
        with LOG.open("a", encoding="utf-8") as fh:
            fh.write(f"{datetime.now(timezone.utc):%Y-%m-%dT%H:%M:%SZ} outbox-put {msg}\n")
    except OSError:
        pass


def publish(key: str, text: str) -> str | None:
    sha8 = hashlib.sha256(key.encode()).hexdigest()[:8]
    OUTBOX.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = OUTBOX / f".put-{os.getpid()}-{time.time_ns()}.tmp"
    ms = int(time.time() * 1000)
    try:
        for _ in range(1000):
            item = {"id": f"{ms}-{sha8}", "at_msk": owner_stamp(),
                    "key": key, "text": text}
            tmp.write_text(json.dumps(item, ensure_ascii=False), encoding="utf-8")
            try:
                os.link(tmp, OUTBOX / f"{item['id']}.json")  # publish without overwriting
            except FileExistsError:
                ms += 1  # same key in the same millisecond: next numeric prefix, ack format kept
                continue
            return item["id"]
        return None
    finally:
        tmp.unlink(missing_ok=True)


def main(argv: list[str]) -> int:
    if len(argv) != 3 or not argv[1].strip() or not argv[2].strip():
        print("usage: outbox-put.py KEY TEXT", file=sys.stderr)
        return 64
    key, text = argv[1], argv[2]
    log_line(f"ALERT {key}: {text.splitlines()[0][:200]}")
    if CONF.alert_mode == "log":
        print("logged")
        return 0
    item_id = publish(key, text)
    if item_id is None:
        print("outbox-put: no free id", file=sys.stderr)
        return 1
    if CONF.alert_mode == "telegram":
        log_line(f"telegram ok={send_telegram(f'[сторож] {text}')}")
    print(item_id)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
