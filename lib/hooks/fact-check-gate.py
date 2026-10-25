#!/usr/bin/env python3
"""PreToolUse gate (matcher mcp__dashi-channel__reply): the first status-bearing reply to the owner
or to a group is stopped once with a fact-check reminder. Main agent only.

Installed by neurootdel-install: owner chat = guard.conf OWNER_TG_ID, the deny state lives in the
directory given as argv[1].
A reply with status words or digits is denied once; any reply within GRACE_SEC after that passes.
A «can't / impossible» claim about a service counts as a fact too.
Stop: delete the PreToolUse entry with matcher mcp__dashi-channel__reply from plugin/.claude/settings.json.
"""
import json
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import guard_conf  # noqa: E402  (lives one level up, next to guard.conf)

_CONF = guard_conf.load()
OWNER_CHAT = _CONF.owner_tg_id or "-"
GRACE_SEC = 600
STATUS_RE = re.compile(
    r"\d|\b(нет|есть|стоит|стоят|работает|работают|скрыт\w*|вышл\w*|вышел|сделан\w*|готов\w*|включ\w*|выключ\w*|"
    r"запущ\w*|закрыт\w*|отправ\w*|пришл\w*|пришёл|прош[её]л\w*|прошл[аио]|упал\w*|сломан\w*|нашл\w*|исправ\w*|"
    r"проверен\w*|подключ\w*|удал[её]н\w*|оплачен\w*|выдан\w*|недоступ\w*|доступ\w*)\b",
    re.IGNORECASE,
)
CANT_RE = re.compile(
    r"(не\s+получится|нельзя|невозможно|не\s+умеет|не\s+поддержива\w*|только\s+через|не\s+да[её]т|не\s+позволя\w*)",
    re.IGNORECASE,
)
REASON = ("Каждая фактическая фраза проверена вызовом в ЭТОМ ходе? Нет: проверь или напиши «не проверено», "
          "потом отправь снова (повтор 10 мин проходит). Ответ про возможности чужого сервиса (Telegram, "
          "Instagram, сервисы оплаты...) = сначала WebSearch или документация в этом ходе; «нельзя / не "
          "получится» без такой проверки запрещено.")


def decide(payload: dict, now: float, state_dir: Path) -> str | None:
    """Return a deny reason, or None to let the call through."""
    args = payload.get("tool_input")
    if not isinstance(args, dict):
        return None
    chat = str(args.get("chat_id", ""))
    if chat != OWNER_CHAT and not chat.startswith("-"):
        return None
    if not re.fullmatch(r"-?\d+", chat):
        return None
    text = str(args.get("text", ""))
    if not (STATUS_RE.search(text) or CANT_RE.search(text)):
        return None
    state = state_dir / ("last_deny" if chat == OWNER_CHAT else f"last_deny_{chat}")
    try:
        last = float(state.read_text().strip())
    except FileNotFoundError:
        last = 0.0
    except (OSError, ValueError, UnicodeDecodeError):
        return None  # unreadable state -> never risk an endless deny loop
    if 0 <= now - last < GRACE_SEC:
        return None
    try:
        state.parent.mkdir(parents=True, exist_ok=True)
        state.write_text(repr(float(now)))
    except OSError:
        return None  # cannot remember the deny -> never risk an endless loop
    return REASON


def main() -> int:
    if len(sys.argv) < 2:
        return 0
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError, UnicodeDecodeError):
        return 0
    if not isinstance(payload, dict):
        return 0
    reason = decide(payload, time.time(), Path(sys.argv[1]))
    if reason:
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                                 "permissionDecision": "deny",
                                                 "permissionDecisionReason": reason}}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception:  # a gate bug must never wedge the reply
        sys.exit(0)
