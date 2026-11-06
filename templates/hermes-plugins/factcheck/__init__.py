"""factcheck: facts in the auditor's outgoing text only after a source was read (installed by neurootdel-install).

A text with facts (a digit, a status word, «нельзя / не умеет», news words, «по данным / со слов», or at least
LONG_FACT_CHARS long) goes out only if the agent successfully READ a source in the same turn. The fact patterns are
vendored verbatim from lib/hooks/fact-check-gate.py, the gate of the Claude agents of the installer
(tests/test_hermes_plugins.py fails if the two copies drift).

Strict on purpose: only read_file, search_files, web_search and web_extract count, each by its own success shape.
terminal, MCP tools, delegate_task and browser do not (a source read through the shell gets the stub, the agent then
opens it with read_file). A read of an agent letter (the bridge spool) is not a source either.

Hooks:
- post_tool_call: remember successful reads per (session_id, turn_id).
- transform_llm_output: the final answer. A violating answer is replaced by STUB, the reason goes to
  ~/.hermes/logs/factcheck.log (never the text itself, only a short hash).
- pre_tool_call: sending tools (send_message, MCP notify-like calls) get a real block with the reason, so the agent
  reads the source and sends again in the same turn.
- pre_llm_call: if the previous answer of this session was replaced, the next turn is told why (one short line).
Subagent turns are not checked: their text goes to the parent, not out. A checker bug never eats an answer
(fail open on exceptions, logged by type only).

Stop: hermes plugins disable factcheck, then sudo systemctl restart hermes-auditor.
"""
from __future__ import annotations

import hashlib
import json
import logging
import re
import threading
import time
from collections import OrderedDict
from pathlib import Path
from typing import Any

log = logging.getLogger(__name__)

LOG_PATH = Path.home() / ".hermes" / "logs" / "factcheck.log"
MAX_TURNS = 500
MAX_SUBAGENTS = 20000
SKIP_PLATFORMS = {"subagent"}

# --- vendored from lib/hooks/fact-check-gate.py (keep identical) ------------------------------------------------
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
NEWS_RE = re.compile(
    r"\b(суд\w*|арест\w*|страж\w*|сизо|задерж\w*|приговор\w*|осуд\w*|штраф\w*|закон\w*|следовател\w*|"
    r"следств\w*|полиц\w*|прокур\w*|обвин\w*|уголовн\w*|статья|стать[еи]|заявил\w*|рассказал\w*|сообщил\w*|"
    r"сообщает|сообщают|объявил\w*|подписал\w*|принял\w*|запретил\w*|разрешил\w*|млн|млрд|тыс|рубл\w*|"
    r"процент\w*|по\s+данным|по\s+словам|источник\w*)\b",
    re.IGNORECASE,
)
LONG_FACT_CHARS = 280
# --- end of vendored block --------------------------------------------------------------------------------------

# Status words of a check report that the shared gate does not list.
EXTRA_STATUS_RE = re.compile(
    r"(?<![\w-])(останов\w*|заверш\w*|пада\w*|упад\w*|провал\w*|пройден\w*|успешн\w*|ошибк\w*|ошибоч\w*|"
    r"обновл[её]н\w*|деплой\w*|выкат\w*|влит\w*|принят\w*|отклон\w*|отмен[её]н\w*|перезапущ\w*|рестарт\w*|"
    r"завис\w*|висит|висят|лежит|лежат|passed|failed|merged|deployed|done|fixed|broken|running|stopped)(?![\w-])",
    re.IGNORECASE,
)
ATTRIB_RE = re.compile(r"(?<![\w-])(со\s+слов\w*|по\s+данным|по\s+словам|по\s+отч[её]т\w*|по\s+сведениям|"
                       r"как\s+(?:пишет|пишут|сообщ\w+|доложил\w*|отчитал\w*))(?![\w-])", re.IGNORECASE)
# Where agent letters live (the auditor bridge spool): a letter about the subject is not the subject.
LETTER_SRC_RE = re.compile(r"auditor-bus|auditor-bridge|swarm[-_]?(?:inbox|outbox|reply|bridge|task|spool|letter)",
                           re.IGNORECASE)

READ_TOOLS = {"read_file", "search_files", "web_search", "web_extract"}
SEND_TOOLS = {"send_message"}
SEND_MCP_RE = re.compile(r"^mcp_+.+_+(notify|send\w*|reply|post\w*)$")
LINE_NO_RE = re.compile(r"(?m)^\s*\d+\|")

STUB = ("Ответ задержан проверкой перед отправкой: в нём есть сведения, которые в этом ходе не сверены с "
        "источником. Пришлите запрос ещё раз, сначала открою источник и проверю.")
FACT_BLOCK = ("[факт-гейт] В тексте есть факты (цифры, статусы, даты, новости, утверждения о мире), а источник в "
              "этом ходе не прочитан. Открой источник через read_file, search_files, web_search или web_extract "
              "(чтение через terminal не засчитывается), сверь каждый факт, убери то, чего в источнике нет, и "
              "отправь снова.")
REMIND = ("[factcheck] Твой прошлый ответ не ушёл: в нём были факты без источника, прочитанного в том же ходе. "
          "В этом ходе сначала открой источник через read_file, search_files, web_search или web_extract, сверь "
          "факты и только потом отвечай.")

_lock = threading.Lock()
_reads: "OrderedDict[tuple[str, str], int]" = OrderedDict()
_stubbed: "OrderedDict[str, bool]" = OrderedDict()
_subagents: "OrderedDict[str, bool]" = OrderedDict()


def _bump(od: OrderedDict, key: Any, value: Any, cap: int = MAX_TURNS) -> None:
    od[key] = value
    od.move_to_end(key)
    while len(od) > cap:
        od.popitem(last=False)


def _h(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8", "replace")).hexdigest()[:12]


def write_log(rec: dict[str, Any]) -> None:
    try:
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        with LOG_PATH.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps({"ts": ts, **rec}, ensure_ascii=False) + "\n")
    except OSError:
        log.warning("factcheck: log write failed", exc_info=True)


def _parse(result: Any) -> Any:
    if isinstance(result, (dict, list)):
        return result
    try:
        return json.loads(str(result))
    except (TypeError, ValueError):
        return None


def _words(text: Any) -> int:
    return sum(1 for ch in text if ch.isalnum()) if isinstance(text, str) else 0


def is_read_tool(name: str, args: dict) -> bool:
    if name not in READ_TOOLS:
        return False
    try:
        return not LETTER_SRC_RE.search(json.dumps(args, ensure_ascii=False, default=str))
    except (TypeError, ValueError):
        return False


def read_ok(name: str, result: Any) -> bool:
    """The tool's own success shape with real content; anything else (error, empty, non-dict) is not a read."""
    data = _parse(result)
    if not isinstance(data, dict) or data.get("error") or data.get("success") is False:
        return False
    if name == "read_file":
        content = data.get("content")
        return isinstance(content, str) and _words(LINE_NO_RE.sub(" ", content)) >= 3
    if name == "search_files":
        n = data.get("total_count")
        return isinstance(n, int) and not isinstance(n, bool) and n > 0
    if name == "web_search":
        web = (data.get("data") or {}).get("web") if isinstance(data.get("data"), dict) else None
        return data.get("success") is True and isinstance(web, list) and any(
            isinstance(r, dict) and _words(" ".join(str(r.get(k) or "") for k in ("title", "description"))) >= 3
            for r in web)
    if name == "web_extract":
        res = data.get("results")
        return isinstance(res, list) and any(
            isinstance(r, dict) and not r.get("error") and _words(r.get("content")) >= 3 for r in res)
    return False


def has_fact(text: str) -> list[str]:
    """Why the text counts as factual (empty list = no fact)."""
    why = []
    for tag, rx in (("status", STATUS_RE), ("status+", EXTRA_STATUS_RE), ("cant", CANT_RE), ("news", NEWS_RE),
                    ("attrib", ATTRIB_RE)):
        m = rx.search(text)
        if m:
            why.append(f"{tag}:{m.group(0)[:20]}")
    if len(text.strip()) >= LONG_FACT_CHARS:
        why.append("long")
    return why


def reads_in(session_id: Any, turn_id: Any) -> int:
    if not session_id or not turn_id:
        return 0
    with _lock:
        return _reads.get((str(session_id), str(turn_id)), 0)


def is_subagent(session_id: Any, platform: str = "") -> bool:
    if platform in SKIP_PLATFORMS:
        return True
    with _lock:
        return str(session_id or "") in _subagents


def outgoing_texts(tool_name: str, args: dict) -> list[str]:
    """The human-readable text a sending tool would deliver."""
    if tool_name in SEND_TOOLS:
        return [str(args[k]) for k in ("message", "text", "content") if isinstance(args.get(k), str)]
    if SEND_MCP_RE.match(tool_name):
        return ["\n".join(_strings(args))]
    return []


def _strings(data: Any, depth: int = 0) -> list[str]:
    if depth > 20:
        return []
    if isinstance(data, str):
        parsed = _parse(data) if data.strip().startswith("{") else None
        return _strings(parsed, depth + 1) if isinstance(parsed, dict) else [data]
    if isinstance(data, dict):
        return [s for k, v in data.items() if not str(k).startswith("_") for s in _strings(v, depth + 1)]
    if isinstance(data, list):
        return [s for v in data for s in _strings(v, depth + 1)]
    return []


# --- hooks ------------------------------------------------------------------------------------------------------

def on_post_tool_call(tool_name: str = "", args: Any = None, result: Any = None, session_id: str = "",
                      turn_id: str = "", **_: Any) -> None:
    try:
        name = str(tool_name or "")
        a = args if isinstance(args, dict) else {}
        if not session_id or not turn_id or not is_read_tool(name, a) or not read_ok(name, result):
            return
        key = (str(session_id), str(turn_id))
        with _lock:
            _bump(_reads, key, _reads.get(key, 0) + 1)
    except Exception as exc:  # noqa: BLE001 - an observer must never break a tool call
        log.debug("factcheck post_tool_call failed: %s", type(exc).__name__)


def on_transform_llm_output(response_text: str = "", session_id: str = "", platform: str = "", turn_id: str = "",
                            **_: Any) -> str | None:
    try:
        if not isinstance(response_text, str) or not response_text.strip() or is_subagent(session_id, platform):
            return None
        reads = reads_in(session_id, turn_id)
        why = has_fact(response_text)
        verdict = "fact-unread" if why and reads <= 0 else ("pass:read" if why else "pass:no-fact")
        write_log({"event": "final", "session": str(session_id)[:24], "turn": str(turn_id)[:12],
                   "platform": str(platform), "reads": reads, "verdict": verdict, "why": why[:4],
                   "hash": _h(response_text), "chars": len(response_text)})
        if verdict.startswith("pass"):
            with _lock:
                _stubbed.pop(str(session_id), None)
            return None
        with _lock:
            _bump(_stubbed, str(session_id), True)
        return STUB
    except Exception as exc:  # noqa: BLE001 - fail open: a checker bug must never eat the answer
        log.warning("factcheck transform failed: %s", type(exc).__name__)
        write_log({"event": "final", "session": str(session_id)[:24], "verdict": "error-pass",
                   "error": type(exc).__name__})
        return None


def on_pre_tool_call(tool_name: str = "", args: Any = None, session_id: str = "", turn_id: str = "",
                     platform: str = "", **_: Any) -> dict | None:
    try:
        if is_subagent(session_id, platform):
            return None
        texts = [t for t in outgoing_texts(str(tool_name), args if isinstance(args, dict) else {}) if t.strip()]
        if not texts:
            return None
        text = "\n".join(texts)
        reads = reads_in(session_id, turn_id)
        why = has_fact(text)
        if not why or reads > 0:
            return None
        write_log({"event": "tool", "tool": str(tool_name), "session": str(session_id)[:24],
                   "turn": str(turn_id)[:12], "reads": reads, "verdict": "block:fact-unread", "why": why[:4],
                   "hash": _h(text)})
        return {"action": "block", "message": FACT_BLOCK}
    except Exception as exc:  # noqa: BLE001 - fail open on a checker bug; the final-answer check still runs
        log.warning("factcheck pre_tool_call failed: %s", type(exc).__name__)
        return None


def on_pre_llm_call(session_id: str = "", **_: Any) -> dict | None:
    with _lock:
        was = _stubbed.pop(str(session_id or ""), None)
    if not was:
        return None
    write_log({"event": "pre_llm", "session": str(session_id)[:24], "verdict": "remind"})
    return {"context": REMIND}


def on_subagent_start(child_session_id: Any = None, **_: Any) -> None:
    if child_session_id:
        with _lock:
            _bump(_subagents, str(child_session_id), True, MAX_SUBAGENTS)


def register(ctx: Any) -> None:
    ctx.register_hook("subagent_start", on_subagent_start)
    ctx.register_hook("post_tool_call", on_post_tool_call)
    ctx.register_hook("transform_llm_output", on_transform_llm_output)
    ctx.register_hook("pre_tool_call", on_pre_tool_call)
    ctx.register_hook("pre_llm_call", on_pre_llm_call)
    write_log({"event": "loaded", "verdict": "registered"})
