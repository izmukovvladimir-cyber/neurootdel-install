"""factcheck: facts in the auditor's outgoing text only after a source was read (installed by neurootdel-install).

A text with facts (a digit, a status word, «нельзя / не умеет», news words, «по данным / со слов», or at least
LONG_FACT_CHARS long) goes out only if the agent successfully READ a source in the same turn. The fact patterns are
vendored verbatim from lib/hooks/fact-check-gate.py, the gate of the Claude agents of the installer
(tests/test_hermes_plugins.py fails if the two copies drift).

Strict on purpose: only read_file, search_files, web_search, web_extract and the two content tools of the shared
memory (gbrain recall server: recall, get) count, each by its own success shape. terminal, every other MCP tool,
delegate_task and browser do not (a source read through the shell gets the stub, the agent then opens it with
read_file). A read of an agent letter (the bridge spool, the swarm) is not a source either.

Template answers (empty recall, null get, failed call, refusal): four exact phrases, the same as in the auditor's
SOUL. One passes only as the whole answer and only when its event happened in this turn (post_tool_call of the two
recall tools, keyed by (session_id, turn_id); the turn record is born in pre_llm_call and closed by the final
answer). A template sentence inside a longer answer, or the empty-search / refusal lexicon, is stubbed; everything
else goes to the unchanged fact check. Without the shared memory no event ever happens, so only the refusal passes.

Hooks:
- post_tool_call: remember successful reads per (session_id, turn_id).
- transform_llm_output: the final answer. A violating answer is replaced by STUB, the reason goes to
  ~/.hermes/logs/factcheck.log (never the text itself, only a short hash).
- pre_tool_call: sending tools (send_message, MCP notify-like calls) get a real block with the reason, so the agent
  reads the source and sends again in the same turn.
- pre_llm_call: opens the turn record; if the previous answer of this session was replaced, the next turn is told
  why (one short line).
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
import unicodedata
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
LETTER_SRC_RE = re.compile(r"auditor-bus|auditor-bridge|swarm[-_]?(?:inbox|outbox|reply|bridge|task|spool|letter)|"
                           r"gbrain[-_]swarm|list_my_pending", re.IGNORECASE)

READ_TOOLS = {"read_file", "search_files", "web_search", "web_extract"}
# The shared memory is a source, exactly two tools of it. The name is the one the hook receives: Hermes registers MCP
# tools as mcp__<server>__<tool> with the server's «-» turned into «_» (config «gbrain-recall»). The «tool_call» search
# bridge is peeled by the engine before any hook; should a wrapper still reach the hook, only a wrapper of exactly ONE
# call whose inner name is one of these two is read as that call. «tool_call» itself, a batch, the other recall tools
# (stats, recent, related, reindex_check), other gbrain servers and any other MCP stay not-a-read.
RECALL_READ_TOOLS = {"mcp__gbrain_recall__recall": "recall", "mcp__gbrain_recall__get": "get"}
BRIDGE_CALL = "tool_call"
SEND_TOOLS = {"send_message"}
SEND_MCP_RE = re.compile(r"^mcp_+.+_+(notify|send\w*|reply|post\w*)$")
LINE_NO_RE = re.compile(r"(?m)^\s*\d+\|")

STUB = ("Ответ задержан проверкой перед отправкой: в нём есть сведения, которые в этом ходе не сверены с "
        "источником. Пришлите запрос ещё раз, сначала открою источник и проверю.")
FACT_BLOCK = ("[факт-гейт] В тексте есть факты (цифры, статусы, даты, новости, утверждения о мире), а источник в "
              "этом ходе не прочитан. Открой источник через read_file, search_files, web_search, web_extract или "
              "общую память (mcp__gbrain_recall__recall, mcp__gbrain_recall__get) "
              "(чтение через terminal не засчитывается), сверь каждый факт, убери то, чего в источнике нет, и "
              "отправь снова.")
REMIND = ("[factcheck] Твой прошлый ответ не ушёл: в нём были факты без источника, прочитанного в том же ходе. "
          "В этом ходе сначала открой источник через read_file, search_files, web_search, web_extract или общую "
          "память, сверь факты и только потом отвечай.")
TPL_REMIND = ("[factcheck] Твой прошлый ответ не ушёл: фраза об отсутствии результата или отказе проходит только "
              "точной, одна и без добавлений, и только если в том же ходе было её событие. Прочитай источник или "
              "ответь одной точной фразой из SOUL.")

# --- template answers bound to a turn event ---------------------------------------------------------------------
TEMPLATES = {
    "E-R": "Поиск в общей памяти по этому запросу ничего не дал. Подтверждённого ответа дать не могу.",
    "E-G": "Документ по этому пути в общей памяти не найден. Подтверждённого ответа дать не могу.",
    "F": "Не удалось получить подтверждённый результат обращения. Подтверждённого ответа дать не могу.",
    "R": "Эти сведения не раскрываю без прямого разрешения владельца.",
}
EVENT_KEYS = ("EMPTY_R", "NULL_G", "FAIL", "READ_R", "READ_G")
TPL_VERDICTS = {"tpl-addition", "tpl-unbound", "template-mismatch", "tpl-history-lost", "tpl-saturated"}
_ZW_RE = re.compile("[\u200b\u200c\u200d\ufeff]")
_WS_RE = re.compile(r"\s+")  # str pattern: Unicode whitespace incl. NBSP, U+2028/2029/0085
# Strong lexicon: any reads. Weak: only when nothing was read this turn. Case-insensitive on purpose. Each rule has a
# fixed id: the log carries the id, never the matched text. Result verbs, «пуст» and «не найден» are listed form by
# form, whole words only («верно», «запустить», «проверено», «пустяк» are not caught). Text is normalized first.
_I = re.IGNORECASE
RESULT_VERB = (r"(?:дал[аои]?|нашел|нашл(?:[аои]|ось|ись)|найден[аоы]?|"
               r"вернул(?:[аои]|ось|ся|ась|ись)?)(?![\w-])")
EMPTY_WORD = r"(?<![\w-])пуст(?:[аоы]|ой|ая|ое|ые|ую|ым|ыми|ых|ом|ого|ому)?(?![\w-])"
NOT_FOUND = r"(?<![\w-])не\s+(?:найден[аоы]?|нашел|нашл(?:[аои]|ось|ись))(?![\w-])"
STRONG_RULES = (
    ("S-mem-empty", re.compile(r"(общ\w*\s+)?памят\w*[^.!?]{0,40}((?<![\w-])ничего\s+не\s+" + RESULT_VERB +
                               "|" + NOT_FOUND + "|" + EMPTY_WORD + ")", _I)),
    ("S-no-disclose-ru", re.compile(r"не\s+раскрыва[юе]|не\s+(могу|буду)\s+раскры|не\s+раскрою", _I)),
    ("S-en-nothing-memory", re.compile(r"nothing\s+(was\s+)?found\s+in\s+(the\s+)?(shared\s+)?memory", _I)),
    ("S-en-cant-disclose", re.compile(r"(can'?t|cannot|won'?t)\s+disclose", _I)),
)
WEAK_RULES = (
    ("W-nothing-result", re.compile(r"(?<![\w-])ничего\s+не\s+" + RESULT_VERB, _I)),
    ("W-not-found-ru", re.compile(NOT_FOUND, _I)),
    ("W-failed-get", re.compile(r"не\s+удалось\s+получить", _I)),
    ("W-permission", re.compile(r"без\s+(прямого\s+)?разрешени", _I)),
    ("W-confidential-ru", re.compile(r"конфиденц", _I)),
    ("W-en-no-results", re.compile(r"no\s+results?", _I)),
    ("W-en-not-found", re.compile(r"not\s+found", _I)),
    ("W-en-returned-nothing", re.compile(r"returned\s+nothing", _I)),
    ("W-en-confidential", re.compile(r"confidential", _I)),
)
TPL_BLOCK = ("[шаблон-гейт] Фраза об отсутствии результата или отказе проходит только целиком, одна, без добавлений, "
             "и только если в этом ходе было её событие (пустой recall, null от get, ошибка обращения). Прочитай "
             "источник или отправь ровно одну точную фразу.")
# One record per turn, created ONLY at turn start (pre_llm_call with session_id and turn_id) and closed ONLY by the
# final answer of that turn (ended=True, frozen). Events go into a live record only: a late event of an ended or
# forgotten turn, or of a turn that never started, is ignored. At the MAX_TURNS cap an ended record is dropped first.
# EVERY dropped key goes to _lost, so a forgotten turn never gets a clean record again; when _lost would exceed
# MAX_LOST the plugin switches to _saturated = fail-closed for E-R/E-G/F until restart. R is not affected.
MAX_LOST = 20000

_lock = threading.Lock()
_reads: "OrderedDict[tuple[str, str], int]" = OrderedDict()
_stubbed: "OrderedDict[str, bool]" = OrderedDict()
_subagents: "OrderedDict[str, bool]" = OrderedDict()
_events: "OrderedDict[tuple[str, str], dict[str, Any]]" = OrderedDict()
_lost: "OrderedDict[tuple[str, str], None]" = OrderedDict()
_saturated = False


def normalize(text: str) -> str:
    """NFKC, ё->е, zero-width removed, any Unicode whitespace -> one space, edges trimmed. Case and punctuation kept."""
    t = unicodedata.normalize("NFKC", text).replace("ё", "е").replace("Ё", "Е")
    return _WS_RE.sub(" ", _ZW_RE.sub("", t)).strip()


_TPL_NORM = {tid: normalize(t) for tid, t in TEMPLATES.items()}
_TPL_FULL = {tid: re.compile(re.escape(t)) for tid, t in _TPL_NORM.items()}  # no flags: case-sensitive fullmatch
# every sentence of every template, for the «contains, but not whole» branch; compared casefolded
_TPL_SENTENCES = sorted({s.strip().casefold() for t in _TPL_NORM.values() for s in re.findall(r"[^.]+\.", t)})


def _bump(od: OrderedDict, key: Any, value: Any, cap: int = MAX_TURNS) -> None:
    od[key] = value
    od.move_to_end(key)
    while len(od) > cap:
        od.popitem(last=False)


def _new_record() -> dict[str, Any]:
    return {**{k: 0 for k in EVENT_KEYS}, "READS": 0, "ended": False}


def _forget(key: tuple[str, str]) -> None:
    """Caller holds _lock. Remember an evicted key for good; no room left -> global fail-closed, irreversibly."""
    global _saturated
    if _saturated:
        return
    if len(_lost) >= MAX_LOST:
        _saturated = True
        return
    _lost[key] = None


def _put_record(key: tuple[str, str], rec: dict[str, Any]) -> None:
    """Caller holds _lock. Insert a turn record; over the cap drop an ended record first, else the oldest live one."""
    _events[key] = rec
    _events.move_to_end(key)
    while len(_events) > MAX_TURNS:
        victim = next((k for k, r in _events.items() if r["ended"]), None)
        if victim is None:
            victim, _ = _events.popitem(last=False)  # a live turn loses its history
        else:
            del _events[victim]
        _forget(victim)


def start_turn(session_id: Any, turn_id: Any) -> None:
    """Turn start: create the turn record. An id that already has a record or lost its history is left as it is."""
    if not session_id or not turn_id:
        return
    key = (str(session_id), str(turn_id))
    with _lock:
        if key not in _events and key not in _lost:
            _put_record(key, _new_record())


def snapshot(session_id: Any, turn_id: Any, end: bool = False) -> dict[str, Any]:
    """Reads, the turn record (copy) and the loss label in ONE lock section; end=True closes the turn there too."""
    ids = bool(session_id and turn_id)
    key = (str(session_id or ""), str(turn_id or ""))
    with _lock:
        rec = _events.get(key) if ids else None
        snap = {"ids": ids, "reads": _reads.get(key, 0) if ids else 0, "rec": dict(rec) if rec else None,
                "lost": ids and key in _lost, "saturated": _saturated}
        if end and rec is not None:
            rec["ended"] = True
    return snap


def _events_of(rec: dict[str, Any] | None) -> dict[str, int]:
    return {k: (rec or {}).get(k, 0) for k in EVENT_KEYS}


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


def unwrap_bridge(name: str, args: dict) -> tuple[str, dict]:
    """A «tool_call» wrapper of one recall read -> (inner name, inner args); anything else is returned unchanged."""
    if name != BRIDGE_CALL:
        return name, args
    calls = args.get("calls")
    if calls is None:
        calls = [{"name": args.get("name"), "arguments": args.get("arguments")}]
    if isinstance(calls, str):
        calls = _parse(calls)
    if isinstance(calls, dict):
        calls = [calls]
    if not isinstance(calls, list) or len(calls) != 1 or not isinstance(calls[0], dict):
        return name, args
    inner = str(calls[0].get("name") or "").strip()
    inner_args = calls[0].get("arguments")
    if inner_args is None or (isinstance(inner_args, str) and not inner_args.strip()):
        inner_args = {}
    elif isinstance(inner_args, str):
        inner_args = _parse(inner_args)  # unparseable text stays None and is refused below
    if inner not in RECALL_READ_TOOLS or not isinstance(inner_args, dict):
        return name, args
    return inner, inner_args


def is_read_tool(name: str, args: dict) -> bool:
    if name not in READ_TOOLS and name not in RECALL_READ_TOOLS:
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
    if name in RECALL_READ_TOOLS:
        return recall_ok(RECALL_READ_TOOLS[name], data)
    return False


def _recall_payload(data: dict) -> Any:
    """What the recall server returned, from the Hermes MCP envelope: {"result": "<json text>"} when the server sent
    text, {"result": {"result": ...}} when it sent only structured content (an empty list comes this way)."""
    res = data.get("result")
    if isinstance(res, str):
        res = _parse(res)
    if isinstance(res, dict) and set(res) == {"result"}:
        res = res["result"]
    return res


def recall_ok(kind: str, data: dict) -> bool:
    """recall: a non-empty hit list with a real snippet; get: a found document with a real body. Empty, null and any
    other shape are not a read (an MCP error already arrived as {"error": ...} and was rejected by the caller)."""
    res = _recall_payload(data)
    if kind == "recall":
        return isinstance(res, list) and any(_recall_item_ok(r, "snippet") for r in res)
    if kind == "get":
        return _recall_item_ok(res, "body")
    return False


def _recall_item_ok(item: Any, text_key: str) -> bool:
    """One hit / one document: a real path, real text, no error marker of its own."""
    return (isinstance(item, dict) and not item.get("error") and item.get("success") is not False
            and isinstance(item.get("path"), str) and _words(item["path"]) > 0 and _words(item.get(text_key)) >= 3)


def recall_event(kind: str, ok: bool, result: Any, status: Any) -> str:
    """One event per call of the two recall tools. EMPTY_R only from recall, NULL_G only from get, each only by its
    exact shape and status "ok"; anything that is neither a read nor that shape is FAIL."""
    if ok:
        return "READ_R" if kind == "recall" else "READ_G"
    data = _parse(result)
    if status != "ok" or not isinstance(data, dict):
        return "FAIL"
    keys = set(data) - {"_meta"}
    res = data.get("result")
    if kind == "recall" and keys == {"result"} and (res == "[]" or res == {"result": []}):
        return "EMPTY_R"
    if kind == "get" and ((keys == {"result"} and (res == "null" or res == {"result": None}))
                          or (keys == {"result", "structuredContent"} and res == "null"
                              and data["structuredContent"] == {"result": None})):
        return "NULL_G"
    return "FAIL"


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


def check(text: str, reads: int) -> tuple[str, list[str]]:
    """The fact check: (verdict, reasons)."""
    why = has_fact(text)
    return ("fact-unread" if why and reads <= 0 else ("pass:read" if why else "pass:no-fact")), why


def template_bound(tid: str, snap: dict[str, Any]) -> bool:
    """The template's event happened in THIS turn's record. No ids -> nothing (R too); no record -> no event template."""
    if not snap["ids"]:
        return False
    if tid == "R":
        return True
    ev = snap["rec"]
    if ev is None:
        return False
    if tid == "E-R":
        return ev["EMPTY_R"] >= 1 and ev["READ_R"] == 0 and ev["FAIL"] == 0
    if tid == "E-G":
        return ev["NULL_G"] >= 1 and ev["READ_G"] == 0 and ev["FAIL"] == 0
    return tid == "F" and ev["FAIL"] >= 1 and ev["READS"] == 0 and snap["reads"] <= 0


def match_template(norm: str) -> str | None:
    hits = [tid for tid, rx in _TPL_FULL.items() if rx.fullmatch(norm)]
    return hits[0] if len(hits) == 1 else None


def lexicon_rule(norm: str, reads: int) -> str | None:
    """Id of the first strong rule (any reads) or weak rule (reads == 0) that matches the normalized text."""
    for rid, rx in STRONG_RULES + (WEAK_RULES if reads <= 0 else ()):
        if rx.search(norm):
            return rid
    return None


def decide(text: str, snap: dict[str, Any]) -> tuple[str, list[str], str | None]:
    """(verdict, reasons, template id) from ONE snapshot; the four branches are kept apart."""
    reads = snap["reads"]
    norm = normalize(text)
    tid = match_template(norm)
    if tid is not None:  # 1: exact template -> only now the event condition
        if tid != "R" and snap["saturated"]:
            return "tpl-saturated", [], tid
        if tid != "R" and snap["rec"] is None and snap["lost"]:
            return "tpl-history-lost", [], tid
        if not template_bound(tid, snap):
            return "tpl-unbound", [], tid
        return f"pass:tpl-{tid}", [], tid
    if any(s in norm.casefold() for s in _TPL_SENTENCES):  # 2: a template sentence, but not the whole answer
        return "tpl-addition", [], None
    rid = lexicon_rule(norm, reads)
    if rid:  # 3: lexicon, a list and not a proof; only the rule id is reported
        return "template-mismatch", [f"lex:{rid}"], None
    verdict, why = check(text, reads)  # 4: the fact check, unchanged
    return verdict, why, None


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
                      turn_id: str = "", status: Any = None, **_: Any) -> None:
    try:
        name, a = unwrap_bridge(str(tool_name or ""), args if isinstance(args, dict) else {})
        if not session_id or not turn_id or not is_read_tool(name, a):
            return
        ok = read_ok(name, result)
        key = (str(session_id), str(turn_id))
        ev = recall_event(RECALL_READ_TOOLS[name], ok, result, status) if name in RECALL_READ_TOOLS else None
        with _lock:
            if ok:
                _bump(_reads, key, _reads.get(key, 0) + 1)
            rec = _events.get(key)
            if rec is not None and not rec["ended"]:  # never-started / ended / forgotten turns stay as they are
                if ev:
                    rec[ev] += 1
                if ok:
                    rec["READS"] += 1
                _events.move_to_end(key)
    except Exception as exc:  # noqa: BLE001 - an observer must never break a tool call
        log.debug("factcheck post_tool_call failed: %s", type(exc).__name__)


def on_transform_llm_output(response_text: str = "", session_id: str = "", platform: str = "", turn_id: str = "",
                            **_: Any) -> str | None:
    try:
        if not isinstance(response_text, str) or not response_text.strip() or is_subagent(session_id, platform):
            return None
        snap = snapshot(session_id, turn_id, end=True)  # the final answer closes the turn
        reads = snap["reads"]
        verdict, why, tid = decide(response_text, snap)
        write_log({"event": "final", "session": str(session_id)[:24], "turn": str(turn_id)[:12],
                   "platform": str(platform), "reads": reads, "verdict": verdict, "why": why[:4], "tpl": tid,
                   "events": _events_of(snap["rec"]), "hash": _h(response_text), "chars": len(response_text)})
        if verdict.startswith("pass"):
            with _lock:
                _stubbed.pop(str(session_id), None)
            return None
        with _lock:
            _bump(_stubbed, str(session_id), verdict)
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
        snap = snapshot(session_id, turn_id)
        reads = snap["reads"]
        verdict, why, tid = decide(text, snap)
        if verdict.startswith("pass"):
            return None
        write_log({"event": "tool", "tool": str(tool_name), "session": str(session_id)[:24],
                   "turn": str(turn_id)[:12], "reads": reads, "verdict": "block:" + verdict, "why": why[:4],
                   "tpl": tid, "events": _events_of(snap["rec"]), "hash": _h(text)})
        return {"action": "block", "message": TPL_BLOCK if verdict in TPL_VERDICTS else FACT_BLOCK}
    except Exception as exc:  # noqa: BLE001 - fail open on a checker bug; the final-answer check still runs
        log.warning("factcheck pre_tool_call failed: %s", type(exc).__name__)
        return None


def on_pre_llm_call(session_id: str = "", turn_id: str = "", platform: str = "", **_: Any) -> dict | None:
    try:
        if not is_subagent(session_id, platform):
            start_turn(session_id, turn_id)  # turn start: the turn record is born here
    except Exception as exc:  # noqa: BLE001 - a missing record only makes event templates fail closed
        log.debug("factcheck start_turn failed: %s", type(exc).__name__)
    with _lock:
        was = _stubbed.pop(str(session_id or ""), None)
    if not was:
        return None
    write_log({"event": "pre_llm", "session": str(session_id)[:24], "verdict": "remind"})
    return {"context": TPL_REMIND if was in TPL_VERDICTS else REMIND}


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
