"""secretguard: the starter secrets rule on the auditor's outgoing text (installed by neurootdel-install).

The Claude agents of the installer have secret-outbound-guard.py (PreToolUse on reply). The auditor runs on Hermes,
where that hook never fires, so this plugin is the Hermes side of the same rule with the same PATTERNS (vendored
verbatim from templates/secret-outbound-guard.py; tests/test_hermes_plugins.py fails if the two copies drift).

Routes it covers:
- transform_llm_output: the final answer of every turn on every platform (Telegram, and the agent bridge through
  the local api_server). A hit replaces the whole answer with STUB; nothing of the original text goes out.
- pre_tool_call: tools that send or store text outside the turn: send_message, every MCP tool, kanban_* and
  cronjob_manage. A hit blocks the call with the reason.
- pre_llm_call: after a replaced answer the next turn is told why (one line).
Not covered here: mid-turn interim messages; the installer turns them off for Telegram in config.yaml.

Besides the PATTERNS, the real secret values of this install are matched literally: every value of
~/.hermes/.env whose name says KEY / TOKEN / SECRET / PASSWORD (the bot token, the local api_server key), so a
bare 64-hex key with no «token=» before it is caught too. The values are re-read when the file changes.

Fail closed: if the scan itself raises, the tool is blocked and the answer is replaced. The log line never carries
the matched value, only pattern names and a short hash of the text.

Stop: hermes plugins disable secretguard, then sudo systemctl restart hermes-auditor.
"""
from __future__ import annotations

import hashlib
import json
import logging
import os
import re
import threading
import time
from collections import OrderedDict
from pathlib import Path
from typing import Any

log = logging.getLogger(__name__)

LOG_PATH = Path.home() / ".hermes" / "logs" / "secretguard.log"
MAX_SESSIONS = 500
MAX_DEPTH = 20
ENV_PATH = Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes") / ".env"
SECRET_NAME_RE = re.compile(r"KEY|TOKEN|SECRET|PASSW", re.IGNORECASE)
MIN_SECRET_LEN = 12

# --- vendored from templates/secret-outbound-guard.py (keep identical) ------------------------------------------
PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    ("private key", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("ssh key", re.compile(r"\bssh-(?:ed25519|rsa|dss|ecdsa[\w-]*) AAAA[0-9A-Za-z+/=]{20,}")),
    ("telegram bot token", re.compile(r"\b\d{8,10}:[A-Za-z0-9_-]{35}(?![A-Za-z0-9_-])")),
    ("api key", re.compile(r"\b(?:sk|pk|rk)-[A-Za-z0-9_-]{20,}")),
    ("github token", re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})")),
    ("cloud key", re.compile(r"\b(?:AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|xox[abpr]-[0-9A-Za-z-]{10,})")),
    ("jwt", re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}")),
    # a value after «пароль:» / «token=»: 6+ chars with a digit, 8+ ASCII with a Latin letter and a symbol, or 6+
    # Latin letters; masks («******») and plain words / instructions («смените!»)
    # words («пароль: сменить в панели») stay allowed
    ("password value", re.compile(
        r"(?i:пароль|password|passwd|pass|токен|token|secret|секрет|api[ _-]?key|ключ)\s*(?i:root\s*)?[:=]\s*[`\"'«]?"
        r"(?:(?=\S*\d)\S{6,}|(?=\S*[A-Za-z])(?=\S*[!@#$%^&*_+=?~])[\x21-\x7e]{8,}"
        r"|[A-Za-z]{6,})")),
]
# --- end of vendored block --------------------------------------------------------------------------------------

STUB = ("Ответ остановлен проверкой секретов: в нём был пароль, ключ или токен. Такое уходит только решением "
        "владельца. Значение не повторяю; если оно нужно, спросите владельца.")
BLOCK = ("[secretguard] В исходящем {where} найдено: {names}. Пароли, ключи, токены и доступы уходят только решением "
         "владельца. Не отправляй значение: убери его (назови место, где оно лежит, без самого значения) или "
         "спроси владельца.")
REMIND = ("[secretguard] Твой прошлый ответ не ушёл: в нём был пароль, ключ или токен. Значения не повторяй, "
          "называй только место; выдача только по решению владельца.")

OUTBOUND_EXACT = {"send_message", "cronjob_manage"}
OUTBOUND_PREFIXES = ("mcp_", "kanban_")

_lock = threading.Lock()
_stubbed: "OrderedDict[str, bool]" = OrderedDict()
_local: dict[str, Any] = {"stamp": None, "values": []}


def write_log(rec: dict[str, Any]) -> None:
    """One JSON line, never the matched value. A failed write never changes a decision."""
    try:
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        with LOG_PATH.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps({"ts": ts, **rec}, ensure_ascii=False) + "\n")
    except OSError:
        log.warning("secretguard: log write failed", exc_info=True)


def texts(value: Any, depth: int = 0) -> list[str]:
    """Every string inside a tool argument, nested dicts and lists included; dict KEYS count too.
    Deeper than MAX_DEPTH raises: the caller blocks (an unscanned remainder is not sent)."""
    if depth > MAX_DEPTH:
        raise ValueError("argument nesting too deep to scan")
    if isinstance(value, str):
        return [value]
    if isinstance(value, dict):
        return [t for k, v in value.items() for t in [*texts(k, depth + 1), *texts(v, depth + 1)]]
    if isinstance(value, (list, tuple)):
        return [t for v in value for t in texts(v, depth + 1)]
    return []


def local_secrets() -> list[str]:
    """Secret values of this install's .env (cached until the file changes); [] when it can not be read."""
    try:
        st = ENV_PATH.stat()
        stamp = (st.st_mtime_ns, st.st_size, st.st_ino)
    except OSError:
        return []
    with _lock:
        if _local["stamp"] == stamp:
            return list(_local["values"])
    values = []
    try:
        for line in ENV_PATH.read_text(encoding="utf-8").splitlines():
            if "=" not in line or line.lstrip().startswith("#"):
                continue
            name, val = line.split("=", 1)
            val = val.strip().strip("'\"")
            if SECRET_NAME_RE.search(name) and len(val) >= MIN_SECRET_LEN:
                values.append(val)
    except (OSError, UnicodeDecodeError):
        return []
    with _lock:
        _local.update(stamp=stamp, values=values)
    return values


def hits(value: Any) -> list[str]:
    blob = "\n".join(texts(value))
    found = [name for name, rx in PATTERNS if rx.search(blob)]
    if any(v in blob for v in local_secrets()):
        found.append("secret of this install")
    return found


def is_outbound(tool_name: str) -> bool:
    return tool_name in OUTBOUND_EXACT or tool_name.startswith(OUTBOUND_PREFIXES)


def _h(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8", "replace")).hexdigest()[:12]


def _bump(session_id: str) -> None:
    with _lock:
        _stubbed[session_id] = True
        _stubbed.move_to_end(session_id)
        while len(_stubbed) > MAX_SESSIONS:
            _stubbed.popitem(last=False)


# --- hooks ------------------------------------------------------------------------------------------------------

def on_pre_tool_call(tool_name: str = "", args: Any = None, session_id: str = "", turn_id: str = "",
                     **_: Any) -> dict | None:
    name = str(tool_name or "")
    if not is_outbound(name):
        return None
    try:
        found = hits(args if isinstance(args, (dict, list, str)) else {})
    except Exception:  # noqa: BLE001 - fail closed: an outbound call is not sent unchecked
        log.warning("secretguard pre_tool_call scan failed", exc_info=True)
        write_log({"event": "tool", "tool": name, "verdict": "block:error", "session": str(session_id)[:24]})
        return {"action": "block", "message": BLOCK.format(where="вызове " + name, names="ошибка проверки")}
    if not found:
        return None
    write_log({"event": "tool", "tool": name, "verdict": "block", "found": found,
               "session": str(session_id)[:24], "turn": str(turn_id)[:12]})
    return {"action": "block", "message": BLOCK.format(where="вызове " + name, names=", ".join(found))}


def on_transform_llm_output(response_text: str = "", session_id: str = "", platform: str = "", turn_id: str = "",
                            **_: Any) -> str | None:
    if not isinstance(response_text, str) or not response_text:
        return None
    try:
        found = hits(response_text)
    except Exception:  # noqa: BLE001 - fail closed: an unchecked answer does not go out
        log.warning("secretguard transform scan failed", exc_info=True)
        found = ["ошибка проверки"]
    if not found:
        return None
    _bump(str(session_id or ""))
    write_log({"event": "final", "verdict": "replaced", "found": found, "platform": str(platform),
               "session": str(session_id)[:24], "turn": str(turn_id)[:12], "hash": _h(response_text),
               "chars": len(response_text)})
    return STUB


def on_pre_llm_call(session_id: str = "", **_: Any) -> dict | None:
    with _lock:
        was = _stubbed.pop(str(session_id or ""), None)
    return {"context": REMIND} if was else None


def register(ctx: Any) -> None:
    ctx.register_hook("pre_tool_call", on_pre_tool_call)
    ctx.register_hook("transform_llm_output", on_transform_llm_output)
    ctx.register_hook("pre_llm_call", on_pre_llm_call)
    write_log({"event": "loaded", "verdict": "registered"})
