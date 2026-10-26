#!/usr/bin/env python3
"""PreToolUse guard: block outbound messages that carry secret material (RED secrets rule).

Wired on the agent's outbound tools (channel reply/edit, swarm notify): passwords, keys, tokens
and access go out only by the owner's decision. A hit exits 2, so the agent sees the reason and
asks the owner instead of sending.
"""
from __future__ import annotations

import json
import re
import sys

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


def texts(value: object) -> list[str]:
    """Every string inside the tool input, nested dicts and lists included."""
    if isinstance(value, str):
        return [value]
    if isinstance(value, dict):
        return [t for v in value.values() for t in texts(v)]
    if isinstance(value, list):
        return [t for v in value for t in texts(v)]
    return []


def hits(tool_input: object) -> list[str]:
    blob = "\n".join(texts(tool_input))
    return [name for name, rx in PATTERNS if rx.search(blob)]


def main() -> int:
    try:
        event = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0
    if not isinstance(event, dict):
        return 0
    found = hits(event.get("tool_input") or {})
    if not found:
        return 0
    print(f"RED-SECRETS: в исходящем сообщении {', '.join(found)}. Пароли, ключи, токены и доступы "
          "уходят только решением владельца. Не отправляй, спроси его.", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
