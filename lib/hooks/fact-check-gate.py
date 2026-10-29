#!/usr/bin/env python3
"""PreToolUse gate (matcher mcp__dashi-channel__reply|mcp__dashi-channel__edit_message): the final check of a
message before it goes out. Main agent only.

Installed by neurootdel-install. Everything owner-specific comes from guard.conf (lib/guard_conf.py):
OWNER_TG_ID (the owner's chat), FACT_GATE_SELF_IDS / FACT_GATE_BOT_IDS (the agent's own and other known bot
accounts), FACT_GATE_CHIP_URL + FACT_GATE_CHIP_ENV (optional Telegram user-account chip), FACT_GATE_STYLE_BANNED
(optional banned words, empty by default). The deny state and gate.log live in the directory given as argv[1].

1. Fact check (the owner's chat and groups): a reply with status words, digits, news claims (суд, арест, заявил,
   млн...) or longer than LONG_FACT_CHARS is denied the first time this exact text is sent. The SAME text passes
   later only if a source was read after that deny (WebFetch, WebSearch, Read, Grep, Glob, Agent, or a reading Bash
   command: curl, cat, sed -n, grep, pdftotext...). A changed text passes only if a source was read after the latest
   fact deny of its earlier version (similar text, same chat: a fix made after reading); an unrelated text is not
   opened by another message's deny. A read made before the first attempt never counts.
   The turn and the reads are taken from the transcript: the current promptId plus everything within WINDOW_SEC of
   the send (a new incoming message does not wipe a deny and the read after it). No transcript -> deny once per
   text per session (state file), then let it through, so the gate never wedges the reply.
2. Optional style list (FACT_GATE_STYLE_BANNED, empty = off): words that must not be in the agent's own words.
   Quotes, code and links are not checked.
3. Optional, only with a chip configured (FACT_GATE_CHIP_URL and FACT_GATE_CHIP_ENV):
   a. tag in groups (reply only): a person addressed by name («Анна, готово») must be tagged with @username, else
      Telegram sends no notification. Names come from the chip /participants (cached MEMBERS_TTL); a person
      without a username and a chip that cannot answer never block.
   b. a ready post a HUMAN wrote in this GROUP (author and text verified in Telegram via the chip, a listed member
      who is not a bot) is not style-checked when sent near-verbatim. Facts are checked on the whole text.
   Without a chip both are off and the gate makes no network calls at all.

An edit (chat_id, message_id, text) is checked exactly like a reply, and a deny of a reply or of an edit with the
same chat+text is the same deny (the hash ignores the tool).

Stop: delete the PreToolUse entry with this script from plugin/.claude/settings.json.
"""
import difflib
import hashlib
import http.client
import json
import math
import re
import shlex
import sys
import threading
import time
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import guard_conf  # noqa: E402  (lives one level up, next to guard.conf)

_CONF = guard_conf.load()
_RAW = guard_conf.read_raw()


def _id_set(value: str) -> set[int]:
    """Telegram ids from a space- or comma-separated guard.conf value; anything else is ignored."""
    return {int(t) for t in re.split(r"[\s,]+", value or "") if re.fullmatch(r"\d{1,15}", t)}


def _chip_url(value: str) -> str:
    """The chip base URL from guard.conf, or "" (chip off) when it is not a plain http(s)://host[:port] URL."""
    try:
        u = urllib.parse.urlsplit((value or "").strip())
        if u.scheme not in ("http", "https") or not u.hostname or u.path not in ("", "/") or u.query or u.fragment:
            return ""
        u.port  # noqa: B018 - raises on a bad port
    except ValueError:  # «http://[» and the like: chip off, the fact check still runs
        return ""
    return f"{u.scheme}://{u.netloc}"


def _chip_env(value: str) -> Path | None:
    v = (value or "").strip()
    return Path(v) if v.startswith("/") else None


def build_style_re(value: str) -> "re.Pattern[str] | None":
    """FACT_GATE_STYLE_BANNED: comma-separated words or phrases; a trailing «*» matches the stem. Empty = None."""
    alts = []
    for w in (value or "").split(","):
        w = w.strip()
        stem = w.endswith("*")
        w = w.rstrip("*").strip()
        if not w:
            continue
        rx = r"\s+".join(re.escape(p) for p in w.split())
        alts.append(rx + (r"\w*" if stem else ""))
    if not alts:
        return None
    return re.compile(r"(?<![\w-])(" + "|".join(sorted(alts, key=len, reverse=True)) + r")(?![\w-])", re.IGNORECASE)


OWNER_CHAT = _CONF.owner_tg_id if re.fullmatch(r"\d{1,15}", _CONF.owner_tg_id or "") else ""
SELF_IDS = _id_set(_RAW.get("FACT_GATE_SELF_IDS", ""))  # the agent's own bot account(s)
BOT_IDS = SELF_IDS | _id_set(_RAW.get("FACT_GATE_BOT_IDS", ""))  # never a «human» author
CHIP_URL = _chip_url(_RAW.get("FACT_GATE_CHIP_URL", ""))
CHIP_ENV = _chip_env(_RAW.get("FACT_GATE_CHIP_ENV", ""))
STYLE_RE = build_style_re(_RAW.get("FACT_GATE_STYLE_BANNED", ""))
LOG_TZ = _CONF.owner_timezone

FALLBACK_SEC = 1800
TAIL_BYTES = 4 * 1024 * 1024
FACT_MARK = "[факт-гейт]"
STYLE_MARK = "[стиль-гейт]"
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
# News-type claims: a text with no digit and no status word («...просят суд взять человека под стражу») is a fact
# text too. Who did what to whom, courts, arrests, money, quotes of sources.
NEWS_RE = re.compile(
    r"\b(суд\w*|арест\w*|страж\w*|сизо|задерж\w*|приговор\w*|осуд\w*|штраф\w*|закон\w*|следовател\w*|"
    r"следств\w*|полиц\w*|прокур\w*|обвин\w*|уголовн\w*|статья|стать[еи]|заявил\w*|рассказал\w*|сообщил\w*|"
    r"сообщает|сообщают|объявил\w*|подписал\w*|принял\w*|запретил\w*|разрешил\w*|млн|млрд|тыс|рубл\w*|"
    r"процент\w*|по\s+данным|по\s+словам|источник\w*)\b",
    re.IGNORECASE,
)
LONG_FACT_CHARS = 280
SIMILAR_RATIO = 0.5  # a fix of a denied text vs. a different message (difflib ratio)

FACT_REASON = (FACT_MARK + " Каждая фактическая фраза проверена вызовом в ЭТОМ ходе? Открой исходник (ссылку, "
               "файл, переписку) и сверь каждый факт: кто, что сделал, цифры, даты, суммы. Чего нет "
               "в исходнике, убери, непроверенное помечай «не проверено». Источник, прочитанный до этой попытки, не "
               "засчитывается: открой его ещё раз и отправь. После чтения источника пройдёт и "
               "тот же, и исправленный текст; без чтения не пройдёт ни тот, ни другой. Ответ про возможности чужого "
               "сервиса (Telegram, Instagram, сервисы оплаты...) = сначала WebSearch или документация в этом ходе.")
REPEAT_REASON = (FACT_MARK + " Этот же текст уже остановлен проверкой фактов, а источник после "
                 "остановки ты не открывал (прочитанный до остановки не засчитывается). Повтор без сверки не "
                 "пройдёт: открой исходник (WebFetch/WebSearch/Read/переписку), сверь каждый факт, убери то, чего в "
                 "исходнике нет, и отправь снова.")

READ_TOOLS = {"WebFetch", "WebSearch", "Read", "Grep", "Glob", "Agent", "Task", "mcp__dashi-channel__download_attachment"}
# A Bash call counts as a read only when one of its commands (not an argument, not `echo cat`) is a reader.
BASH_READERS = {"curl", "wget", "cat", "head", "tail", "grep", "rg", "jq", "pdftotext", "less", "awk", "zcat"}
BACKGROUND_RE = re.compile(r"running in background|moved to the background|Output is being written to", re.I)
READ_FAIL_RE = re.compile(r"No such file|Permission denied|command not found|Is a directory|curl: \(\d+\)|"
                          r"Could not resolve|Connection refused|unauthorized|Traceback|Exit code [1-9]|"
                          r"\"success\"\s*:\s*false|\"error\"\s*:\s*\"[^\"]+\"|\b(?:HTTP/[\d.]+\s+)?[45]\d\d\s+[A-Z][a-z]+|"
                          r"Access denied|Forbidden|Not Found|authentication required|Internal Server Error|"
                          r"<title>[^<]*\b[45]\d\d\b|"
                          r"%\s+Total\s+%\s+Received|Dload\s+Upload|Spent\s+Left\s+Speed|"  # curl progress meter
                          r"^[\s\d.:%kKMG-]*$", re.IGNORECASE)
BASH_WRAPPERS = {"sudo", "timeout", "env", "nice", "command", "time", "xargs"}

# An incoming message starts a new promptId; denies and reads of earlier promptIds within WINDOW_SEC of the send
# still count, with the same rule: a read counts only AFTER a deny of this text (or of its earlier similar
# version) in this chat.
WINDOW_SEC = 900

# --- optional chip: group members and message authors ---------------------------------------------------------
MEMBERS_TTL = 600
MEMBERS_STALE_OK = 86400
CHIP_TIMEOUT = 3
CHIP_BUDGET_SEC = 6.0  # hook timeout is 10 s
CHIP_MAX_BYTES = 2 * 1024 * 1024
MENTION_MARK = "[тег-гейт]"
NAME_END = r"(?:а|я|ы|и|е|у|ю|ой|ей|ою|ею|ом|ем|ём|ь)?"
PATRONYMIC = r"(?:\s+[А-ЯЁ][а-яё]+(?:овна|евна|ична|инична|ович|евич|ич))?"
# Direct address only: a name that opens the message/line/sentence and is followed by «,» «!» «:», or a name after a
# comma that closes the sentence («Готово, Анна.»). «рассказала Анна Иванова» is third person: not matched.
ADDRESS_A = r"(?m)(?:^|(?<=[.!?…]))[ \t]*(?<![\w@-])(?P<n>(?:{forms})" + NAME_END + ")" + PATRONYMIC + r"(?![\w-])[ \t]*[,!:]"
ADDRESS_B = r",[ \t]*(?<![\w@-])(?P<n>(?:{forms})" + NAME_END + ")" + PATRONYMIC + r"(?![\w-])[ \t]*(?=[.!?…]|\n|$)"
# «Спасибо, Анна, за помощь»: between commas only the name as written counts, so a list of names in other cases
# («передал Ольге, Марии, Анне») does not.
ADDRESS_C = r",[ \t]*(?<![\w@-])(?P<n>(?:{exact}))" + PATRONYMIC + r"(?![\w-])[ \t]*,"
ADDRESS_HINT = re.compile(r"(?m)(?:^|(?<=[.!?…]))[ \t*_~]*[A-ZА-ЯЁ][a-zа-яё]{2,}(?:\s+[А-ЯЁ][а-яё]+)?[*_~]*[ \t]*[,!:]|"
                          r",[ \t*_~]*[A-ZА-ЯЁ][a-zа-яё]{2,}(?:\s+[А-ЯЁ][а-яё]+)?[*_~]*[ \t]*(?:[.!?…,]|\n|$)")


def chip_enabled() -> bool:
    """The chip is used only when both its URL and its token file are configured."""
    return bool(CHIP_URL) and CHIP_ENV is not None


def strip_quoted(text: str) -> str:
    """Remove the parts of a message that are not the agent's own words: code, links, quotes, mentions."""
    t = re.sub(r"```.*?```|~~~.*?~~~", " ", text, flags=re.S)
    t = re.sub(r"`[^`\n]*`", " ", t)
    t = re.sub(r"https?://\S+|t\.me/\S+|www\.\S+", " ", t)
    t = re.sub(r"(?m)^\s*>.*$", " ", t)
    prev = None
    while prev != t:  # innermost quotes first, so «а „б“ в» and «а «б» в» are removed whole
        prev = t
        t = re.sub(r"«[^«»]*»", " ", t)
        t = re.sub(r"„[^„“”]*[“”]", " ", t)
        t = re.sub(r"\"[^\"\n]*\"", " ", t)
        t = re.sub(r"“[^“”\n]*”", " ", t)
    t = re.sub(r"@\w+", " ", t)
    t = re.sub(r"(?:~|\.{0,2})/[\w./~-]+", " ", t)
    return t


def _int(v: object) -> int | None:
    """A finite integer id, or None (bool, inf, nan, huge floats, junk are not ids)."""
    if isinstance(v, bool):
        return None
    if isinstance(v, float) and (not math.isfinite(v) or v != int(v)):
        return None
    try:
        n = int(str(v)) if not isinstance(v, (int, float)) else int(v)
    except (TypeError, ValueError, OverflowError):
        return None
    return n if 0 < abs(n) < 10 ** 15 else None


# --- chip access (trusted structured data: members, message author and text) -------------------------------

_chip_deadline = 0.0  # monotonic; set per hook run: all chip calls together stay under CHIP_BUDGET_SEC


def chip_token() -> str | None:
    if CHIP_ENV is None:
        return None
    try:
        for line in CHIP_ENV.read_text().splitlines():
            if line.startswith("CHIP_API_TOKEN="):
                return line.split("=", 1)[1].strip().strip("'\"") or None
    except (OSError, UnicodeDecodeError):
        return None
    return None


def chip_get(path: str) -> object | None:
    """GET a chip endpoint in a daemon worker; the caller waits at most until _chip_deadline and then abandons it
    (connect, headers and body all included). None = chip off, no answer in time, or any failure."""
    if not CHIP_URL:
        return None
    left = _chip_deadline - time.monotonic()
    if left <= 0.2:
        return None
    box: list[object] = []
    worker = threading.Thread(target=lambda: box.append(_chip_get_blocking(path)), daemon=True)
    worker.start()
    worker.join(left)
    return box[0] if box else None


def _chip_get_blocking(path: str) -> object | None:
    if not CHIP_URL or _chip_deadline - time.monotonic() <= 0.2:
        return None
    token = chip_token()
    if not token:
        return None
    u = urllib.parse.urlsplit(CHIP_URL)
    conn_cls = http.client.HTTPSConnection if u.scheme == "https" else http.client.HTTPConnection
    conn = conn_cls(u.hostname or "", u.port,
                    timeout=max(0.1, min(CHIP_TIMEOUT, _chip_deadline - time.monotonic())))
    try:
        conn.request("GET", path, headers={"X-Chip-Token": token})
        r = conn.getresponse()
        if r.status != 200:
            return None
        buf = bytearray()
        while True:
            left = _chip_deadline - time.monotonic()
            if left <= 0 or len(buf) > CHIP_MAX_BYTES:
                return None
            if conn.sock is not None:
                conn.sock.settimeout(max(0.05, min(CHIP_TIMEOUT, left)))
            chunk = r.read1(65536)
            if not chunk:
                break
            buf += chunk
        body = json.loads(bytes(buf).decode("utf-8", "replace"))
    except (OSError, ValueError, http.client.HTTPException):
        return None
    finally:
        conn.close()
    if not isinstance(body, dict) or not body.get("success"):
        return None
    data = body.get("data")
    if isinstance(data, str):
        try:
            data = json.loads(data)
        except ValueError:
            return None
    return data


def fetch_members(chat: str) -> list[dict] | None:
    """Chip /participants of a group: [{"id", "name", "username"}]. None when the chip cannot say."""
    rows = chip_get(f"/chats/{chat}/participants")
    if not isinstance(rows, list):
        return None
    return [{"id": r.get("id"), "name": str(r.get("name") or ""), "username": str(r.get("username") or "")}
            for r in rows if isinstance(r, dict) and _int(r.get("id")) is not None]


def fetch_message(chat: str, mid: int) -> tuple[int, str] | None:
    """(sender user_id, text) of one group message straight from Telegram via the chip (raw from_id), or None."""
    data = chip_get(f"/chats/{chat}/messages/{mid}?raw=true")
    if not isinstance(data, dict):
        return None
    raw = data.get("raw")
    from_id = raw.get("from_id") if isinstance(raw, dict) else None
    uid = _int(from_id.get("user_id")) if isinstance(from_id, dict) else None
    if uid is None:
        return None
    return uid, str(data.get("text") or "")


MEMBERS_FETCH = fetch_members  # tests replace both: no network in tests
MESSAGE_FETCH = fetch_message


def members_for(chat: str, state_dir: Path, now: float) -> list[dict] | None:
    """Members of a group, cached MEMBERS_TTL; a failed refresh falls back to a cache up to MEMBERS_STALE_OK old.
    A malformed cache is ignored, never an exception. Chip off -> None."""
    if not chip_enabled():
        return None
    cache = state_dir / f"members{chat}.json"
    rows_old, ts_old = None, None
    try:
        old = json.loads(cache.read_text())
        if (isinstance(old, dict) and isinstance(old.get("rows"), list) and isinstance(old.get("ts"), (int, float))
                and not isinstance(old.get("ts"), bool) and math.isfinite(old["ts"])):
            rows_old = [r for r in old["rows"] if isinstance(r, dict) and _int(r.get("id")) is not None]
            ts_old = float(old["ts"])
    except (OSError, ValueError, UnicodeDecodeError):
        rows_old = None
    if rows_old is not None and ts_old is not None and 0 <= now - ts_old < MEMBERS_TTL:
        return rows_old
    rows = MEMBERS_FETCH(chat)
    if isinstance(rows, list):
        try:
            state_dir.mkdir(parents=True, exist_ok=True)
            cache.write_text(json.dumps({"ts": now, "rows": rows}, ensure_ascii=False))
        except OSError:
            pass
        return rows
    if rows_old is not None and ts_old is not None and 0 <= now - ts_old < MEMBERS_STALE_OK:
        return rows_old
    return None


def is_human_member(uid: int | None, members: list[dict] | None) -> bool:
    """Positively a person: listed in the group, username not ending in «bot» (Telegram demands it of every bot),
    not a known bot id. Unknown sender = not a person."""
    if uid is None or uid in BOT_IDS or not members:
        return False
    for m in members:
        if _int(m.get("id")) == uid:
            return not str(m.get("username") or "").lower().endswith("bot")
    return False


# --- tag check: the person addressed in a group must be tagged -------------------------------------------------

def _word_pattern(w: str) -> str:
    """«Анна» -> «Анн» + case endings; a Latin spelling only as written."""
    if re.fullmatch(r"[A-Za-z]+", w):
        return re.escape(w)
    stem = w[:-1] if len(w) > 3 and w[-1] in "аяйь" else w
    return re.escape(stem)


def name_words(member: dict) -> set[str]:
    """The words of a member's display name that can be used to call them (capitalized, 3+ letters)."""
    return {t for t in re.findall(r"[A-Za-zА-ЯЁа-яё]{3,}", str(member.get("name") or "")) if t[0].isupper()}


def addressed(text: str, members: list[dict]) -> dict[str, list[dict]]:
    """Word used in a direct address -> the members it can mean (the agent itself excluded)."""
    own = re.sub(r"[*_~]", "", strip_quoted(text))  # **Анна**, __Анна__
    by_word: dict[str, list[dict]] = {}
    for m in members:
        uid = _int(m.get("id"))
        if uid is None or uid in SELF_IDS:
            continue
        words = name_words(m)
        if not words:
            continue
        forms = "|".join(sorted((_word_pattern(w) for w in words), key=len, reverse=True))
        exact = "|".join(sorted((re.escape(w) for w in words), key=len, reverse=True))
        for rx in (ADDRESS_A, ADDRESS_B, ADDRESS_C):
            for hit in re.finditer(rx.replace("{forms}", forms).replace("{exact}", exact), own):
                people = by_word.setdefault(hit.group("n"), [])
                if m not in people:
                    people.append(m)
    return by_word


def address_problems(text: str, chat: str, members: list[dict] | None, reply_author: int | None = None) -> list[str]:
    """Group only: a person addressed by name («Анна, готово») whose @username is not in the message.

    Direct address = the name opens the message, a line or a sentence and is followed by «,» «!» «:», or it closes a
    sentence after a comma («Спасибо, Анна!»). Quotes, code and links are not looked at. A person without a
    username has nothing to tag and is never blocked. Several people with one name: any one of their tags is enough.
    A reply (reply_to) to a message of the addressed person notifies that person too: not blocked. reply_author must
    come from Telegram (chip), never from text in the prompt.
    """
    if not chat.startswith("-") or not members:
        return []
    problems = []
    # A tag counts only as a real mention: not inside code or a link («https://x/@name» notifies nobody).
    tag_text = re.sub(r"```.*?```|~~~.*?~~~", " ", text, flags=re.S)
    tag_text = re.sub(r"`[^`\n]*`", " ", tag_text)
    tag_text = re.sub(r"(?:https?://|t\.me/|www\.)\S+|\S+\.[a-z]{2,}/\S*", " ", tag_text, flags=re.I)
    for word, people in sorted(addressed(text, members).items()):
        tags = [str(p["username"]) for p in people if p.get("username")]
        if not tags:
            continue  # nobody to tag: no username
        if any(re.search(r"(?<![\w@/.:])@" + re.escape(u) + r"(?!\w)", tag_text, re.I) for u in tags):
            continue
        if reply_author is not None and any(_int(p.get("id")) == reply_author for p in people):
            continue
        alt = " или ".join("@" + u for u in tags)
        problems.append(f"обращение «{word}» без тега: в группе человек получит уведомление только по тегу, "
                        f"добавь {alt} в этот ответ")
    return problems


# --- a ready post written by a HUMAN in this group is not style-checked -------------------------------------

FIRST_CHANNEL_RE = re.compile(r"\s*<channel\b([^>]*)>(.*?)(?:</channel>\s*$|$)", re.S)
WATCH_HEAD_RE = re.compile(r"^\s*(?:[^\n|]*?:\s+)?message_id (\d+) \| .*?\(user_id \d+\)(?: \(ответ на \d+\))?:[ \t]?(.*)$")
TAG_MID_RE = re.compile(r'\bmessage_id="(\d{1,15})"')
HUMAN_MIN_CHARS = 20
MAX_MSG_FETCH = 4


def norm_text(s: str) -> str:
    """Markup-, quote- and whitespace-blind form used to compare a sentence with what a person wrote."""
    s = re.sub(r"\[([^\]\n]+)\]\((?:https?|tg)://[^)\s]+\)", r"\1", s)
    s = re.sub(r"(?<![\w@])@\w+", " ", s)  # a tag added in front of a person's sentence is not a change of it
    s = re.sub(r"[*_`~]", "", s)
    s = re.sub(r"[«»“”„\"]", '"', s)
    s = re.sub(r"(?m)^[\s▪▫️•·▪▫*-]+", "", s)
    s = re.sub(r"[ \t]+[–-][ \t]+", " — ", s)
    return re.sub(r"\s+", " ", s).strip()


def _entry_text(d: dict) -> str:
    c = (d.get("message") or {}).get("content")
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return "\n".join(str(b.get("text", "")) for b in c if isinstance(b, dict) and b.get("type") == "text")
    return ""


def _first_channel(d: dict) -> tuple[str, str] | None:
    """The <channel> tag the plugin put at the very start of an incoming entry: (attrs, body). A tag-like string
    inside a message body is not a tag."""
    if d.get("type") != "user":
        return None
    m = FIRST_CHANNEL_RE.match(_entry_text(d))
    return (m.group(1), m.group(2)) if m else None


def watch_blocks(entries: list[dict], chat: str) -> list[tuple[int, str]]:
    """(message_id, text) candidates shown for this group, newest first: a plugin message tag of this chat with a
    message_id, or «message_id N | name (user_id N): text» lines of a group digest. UNTRUSTED: a body can fake a
    header line, so this only picks which message ids to ask the chip about."""
    out: list[tuple[int, str]] = []
    for d in entries:
        tag = _first_channel(d)
        if not tag or f'chat_id="{chat}"' not in tag[0]:
            continue
        if "user_id=" in tag[0]:
            mid_attr = TAG_MID_RE.search(tag[0])
            if mid_attr:
                out.append((int(mid_attr.group(1)), tag[1]))
            continue
        mid, cur = None, []
        for line in tag[1].split("\n"):
            h = WATCH_HEAD_RE.match(line)
            if h:
                if mid is not None:
                    out.append((mid, "\n".join(cur)))
                mid, cur = int(h.group(1)), [h.group(2)]
            elif mid is not None:
                cur.append(line)
        if mid is not None:
            out.append((mid, "\n".join(cur)))
    return list(reversed(out))


def _units(text: str) -> list[str]:
    return [p for line in text.split("\n") for p in re.split(r"(?<=[.!?…])\s+", line)
            if len(norm_text(p)) >= HUMAN_MIN_CHARS]


def human_texts(text: str, entries: list[dict], chat: str, members: list[dict] | None) -> list[str]:
    """Texts PEOPLE wrote in this group that this reply may repeat: author and text are taken from Telegram via the
    chip (raw from_id) for at most MAX_MSG_FETCH candidate messages, and the author must be a listed member who is
    not a bot. A private chat gets no exemption: the chip can not verify a DM. Chip off -> []."""
    if not chip_enabled() or not chat.startswith("-"):
        return []
    units = [norm_text(u) for u in _units(text)]
    if not units or not members:
        return []
    picks: list[int] = []
    for mid, body in watch_blocks(entries, chat):
        nb = norm_text(body)
        if mid not in picks and any(u in nb for u in units):
            picks.append(mid)
        if len(picks) >= MAX_MSG_FETCH:
            break
    out = []
    for mid in picks:
        got = MESSAGE_FETCH(chat, mid)
        if got and is_human_member(got[0], members):
            out.append(got[1])
    return out


def drop_human_parts(text: str, humans: list[str]) -> str:
    """The text without sentences/lines a person wrote in this chat (near-verbatim: markup, quotes, spaces aside).
    What remains (the agent's own words around the post) is style-checked as usual."""
    if not humans:
        return text
    corpus = "\n".join(norm_text(h) for h in humans)
    out_lines = []
    for line in text.split("\n"):
        parts = re.split(r"(?<=[.!?…])\s+", line)
        kept = [p for p in parts if not (len(norm_text(p)) >= HUMAN_MIN_CHARS and norm_text(p) in corpus)]
        out_lines.append(" ".join(kept) if len(kept) != len(parts) else line)
    return "\n".join(out_lines)


# --- transcript time ------------------------------------------------------------------------------------------


def _ts(d: dict) -> float | None:
    v = d.get("timestamp")
    if not isinstance(v, str):
        return None
    try:
        return datetime.fromisoformat(v.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def style_problems(text: str) -> list[str]:
    """Banned words of FACT_GATE_STYLE_BANNED in the agent's own words. No list configured -> []."""
    if STYLE_RE is None:
        return []
    banned = sorted({m.group(1).lower() for m in STYLE_RE.finditer(strip_quoted(text))})
    if not banned:
        return []
    return [f"запрещённые слова ({', '.join(banned)}): перепиши без них"]


# --- fact check ---------------------------------------------------------------------------------------------

def text_hash(chat: str, text: str) -> str:
    norm = re.sub(r"\s+", " ", text).strip()
    return hashlib.sha256(f"{chat}\n{norm}".encode()).hexdigest()


def read_tail(path: Path) -> list[dict]:
    size = path.stat().st_size
    with path.open("rb") as fh:
        if size > TAIL_BYTES:
            fh.seek(size - TAIL_BYTES)
            fh.readline()
        raw = fh.read()
    out = []
    for line in raw.decode("utf-8", "replace").splitlines():
        try:
            d = json.loads(line)
        except ValueError:
            continue
        if isinstance(d, dict) and d.get("type") in ("user", "assistant") and not d.get("isSidechain"):
            out.append(d)
    return out


def is_read_call(name: str, args: dict) -> bool:
    if name in READ_TOOLS or name.startswith("mcp__gbrain-recall__"):
        return True
    if name == "Bash":
        cmd = str(args.get("command", ""))
        if "codex-check" in cmd:
            return False  # Codex is a reviewer, not a source
        return bash_reads(cmd)
    return False


def strip_heredoc_bodies(cmd: str) -> str:
    """Drop heredoc bodies: text fed to a command is data, its lines are not commands that run."""
    out: list[str] = []
    lines = cmd.split("\n")
    i = 0
    while i < len(lines):
        line = lines[i]
        out.append(line)
        delims = re.findall(r"<<-?\s*(['\"]?)([A-Za-z_]\w*)\1", line)
        i += 1
        for _q, delim in delims:
            while i < len(lines) and lines[i].strip() != delim:
                i += 1
            i += 1  # the closing delimiter line
    return "\n".join(out)


def bash_reads(cmd: str) -> bool:
    """True if some command of the Bash line is a reader (curl, cat, sed -n, grep...), not just mentions one.

    The line is tokenized with shell quoting (so `echo 'x; cat f'` is one echo), and a command after «||» is
    skipped: it runs only when the previous one failed.
    """
    cmd = strip_heredoc_bodies(cmd)
    try:
        lex = shlex.shlex(cmd.replace("\n", " ; "), posix=True, punctuation_chars=";&|()<>")
        lex.whitespace_split = True
        tokens = list(lex)
    except ValueError:
        return False
    seps = {";", "&&", "||", "|", "&", "(", ")", ";;"}
    segments: list[tuple[str, list[str]]] = []
    cur: list[str] = []
    prev_sep = ";"
    for tok in tokens:
        if tok in seps:
            segments.append((prev_sep, cur))
            cur, prev_sep = [], tok
        else:
            cur.append(tok)
    segments.append((prev_sep, cur))
    for sep, words in segments:
        if sep == "||":
            continue
        while words and (re.fullmatch(r"\w+=\S*", words[0]) or words[0] in BASH_WRAPPERS
                         or (words[0].startswith("-") and len(words) > 1) or re.fullmatch(r"\d+[smh]?", words[0])):
            words = words[1:]
        if not words:
            continue
        if any(w.startswith((">", "<<")) for w in words):
            continue  # `cat > f <<EOF`, `grep x > out`: writing a file, not reading a source into the answer
        prog = words[0].rsplit("/", 1)[-1]
        if prog in BASH_READERS:
            return True
        if prog == "sed" and any(w == "-n" or (w.startswith("-") and "n" in w and "i" not in w) for w in words[1:]):
            return True
    return False


def read_succeeded(name: str, args: dict, output: str) -> bool:
    """A read whose output is empty or only error lines did not open anything (any length of errors)."""
    out = output.strip()
    if args.get("run_in_background") or BACKGROUND_RE.search(out):
        return False  # the read has not finished yet: its result is not in this answer
    if name != "Bash":
        return bool(out)
    titles = [t for t in re.findall(r"<title>(.*?)</title>", out, re.I | re.S) if t.strip()]
    if any(READ_FAIL_RE.search(t) for t in titles):
        return False  # an error page as a whole (nginx 404 and the like)
    plain = re.sub(r"<[^>]+>", " ", out)
    useful = " ".join(line for line in plain.splitlines() if not READ_FAIL_RE.search(line))
    useful = re.sub(r"\b(nginx|apache|cloudflare|openresty|html|body|head)\b", " ", useful, flags=re.I)
    return len(re.findall(r"\w", useful)) >= 20  # real text besides error lines and markup came back


def similar(a: str, b: str) -> bool:
    """A corrected version of the same message, not an unrelated one."""
    a, b = re.sub(r"\s+", " ", a).strip(), re.sub(r"\s+", " ", b).strip()
    return difflib.SequenceMatcher(None, a, b, autojunk=False).ratio() >= SIMILAR_RATIO


def turn_state(entries: list[dict], chat: str, h: str, text: str = "",
               now: float | None = None) -> tuple[bool, bool, bool] | None:
    """For the current turn: (this text was denied, a source was read after that deny, a source was read after
    the LATEST fact deny in this chat of a SIMILAR text, i.e. this message's earlier version). None if no turn.

    The third value lets a text corrected after reading the source go out (otherwise every fixed version is a
    «new» text and is blocked again).

    A read counts only if its tool_use comes after the deny RESULT line: a read issued before the block (or in
    parallel with the blocked reply) was not a reaction to it.

    The turn is the current promptId plus every result of an earlier promptId timestamped within
    [now - WINDOW_SEC, now] (an incoming message does not wipe a deny and the read after it). Without `now`, or
    for a line without a timestamp, only the current promptId counts.
    """
    prompt_id = None
    for d in reversed(entries):
        if d.get("type") == "user" and d.get("promptId"):
            prompt_id = d["promptId"]
            break
    if prompt_id is None:
        return None

    def in_scope(d: dict) -> bool:
        if d.get("promptId") == prompt_id:
            return True
        t = _ts(d)
        return now is not None and t is not None and now - WINDOW_SEC <= t <= now

    uses: dict[str, tuple[int, str, dict]] = {}
    results: list[tuple[int, str, bool, str]] = []
    for i, d in enumerate(entries):
        content = (d.get("message") or {}).get("content")
        if not isinstance(content, list):
            continue
        for b in content:
            if not isinstance(b, dict):
                continue
            if b.get("type") == "tool_use":
                uses[str(b.get("id"))] = (i, str(b.get("name", "")), b.get("input") or {})
            elif b.get("type") == "tool_result" and in_scope(d):
                c = b.get("content")
                if isinstance(c, list):
                    c = " ".join(str(x.get("text", "")) for x in c if isinstance(x, dict))
                results.append((i, str(b.get("tool_use_id")), bool(b.get("is_error")), str(c)))
    last_deny = None
    last_chat_deny = None
    for i_res, uid, err, c in results:
        u = uses.get(uid)
        if not u or not err or FACT_MARK not in c or not u[1].startswith("mcp__dashi-channel__"):
            continue
        if str(u[2].get("chat_id", "")) != chat:
            continue
        if similar(text, str(u[2].get("text", ""))):
            last_chat_deny = i_res if last_chat_deny is None else max(last_chat_deny, i_res)
        if text_hash(chat, str(u[2].get("text", ""))) == h:
            last_deny = i_res if last_deny is None else max(last_deny, i_res)

    def read_after(idx: int | None) -> bool:
        if idx is None:
            return False
        for _, uid, err, c in results:
            u = uses.get(uid)
            if u and not err and u[0] > idx and is_read_call(u[1], u[2]) and read_succeeded(u[1], u[2], c):
                return True
        return False

    return (last_deny is not None, read_after(last_deny), read_after(last_chat_deny))


def fallback_decide(state_dir: Path, session: str, chat: str, h: str, now: float) -> str | None:
    """No transcript: deny each text once per session, then let it through (never an endless loop)."""
    state = state_dir / "denied.json"
    try:
        data = json.loads(state.read_text()) if state.exists() else {}
    except (OSError, ValueError, UnicodeDecodeError):
        return None
    if not isinstance(data, dict):
        return None
    data = {k: v for k, v in data.items() if isinstance(v, (int, float)) and now - v < FALLBACK_SEC}
    key = f"{session}:{h}"
    if key in data:
        return None
    data[key] = now
    try:
        state_dir.mkdir(parents=True, exist_ok=True)
        state.write_text(json.dumps(data))
    except OSError:
        return None
    return FACT_REASON


def fact_decide(payload: dict, now: float, state_dir: Path,
                entries: list[dict] | None = None) -> tuple[str | None, str]:
    args = payload.get("tool_input") or {}
    chat = str(args.get("chat_id", ""))
    if not re.fullmatch(r"-?\d+", chat):
        return None, "fact:skip-chat"
    if chat != OWNER_CHAT and not chat.startswith("-"):
        return None, "fact:skip-chat"
    text = str(args.get("text", ""))
    if not (STATUS_RE.search(text) or CANT_RE.search(text) or NEWS_RE.search(text)
            or len(text.strip()) >= LONG_FACT_CHARS):
        return None, "fact:no-fact"
    h = text_hash(chat, text)
    tp = payload.get("transcript_path")
    st = None
    if entries is None and tp:
        try:
            entries = read_tail(Path(tp))
        except OSError:
            entries = None
    if entries is not None:
        st = turn_state(entries, chat, h, text, now)
    if st is None:
        r = fallback_decide(state_dir, str(payload.get("session_id", "")), chat, h, now)
        return r, "fact:fallback-deny" if r else "fact:fallback-pass"
    denied, read_after, read_after_chat_deny = st
    if denied:
        if read_after:
            return None, "fact:pass-after-read"
        return REPEAT_REASON, "fact:deny-repeat-unread"
    if read_after_chat_deny:
        return None, "fact:pass-changed-after-read"
    return FACT_REASON, "fact:deny-new"


def decide(payload: dict, now: float, state_dir: Path) -> str | None:
    """Return a deny reason, or None to let the call through."""
    reason, _ = decide_verbose(payload, now, state_dir)
    return reason


def decide_verbose(payload: dict, now: float, state_dir: Path) -> tuple[str | None, str]:
    args = payload.get("tool_input")
    if not isinstance(args, dict):
        return None, "skip"
    chat = str(args.get("chat_id", ""))
    text = str(args.get("text", ""))
    entries = None
    tp = payload.get("transcript_path")
    if tp:
        try:
            entries = read_tail(Path(tp))
        except OSError:
            entries = None
    global _chip_deadline
    _chip_deadline = time.monotonic() + CHIP_BUDGET_SEC
    is_group = bool(re.fullmatch(r"-\d+", chat))
    is_reply = str(payload.get("tool_name", "")).endswith("__reply")
    problems = style_problems(text)
    tag_problems: list[str] = []
    notes: list[str] = []
    # Tags and the human-post exemption need the chip; without it they are off and nothing goes to the network.
    # Any failure there leaves style and facts exactly as without them.
    if chip_enabled():
        try:
            members = None
            need_tag = is_group and is_reply and bool(ADDRESS_HINT.search(strip_quoted(text)))
            if is_group and (need_tag or problems):
                members = members_for(chat, state_dir, now)
            if problems and entries:
                humans = human_texts(text, entries, chat, members)
                own_text = drop_human_parts(text, humans)
                if own_text != text:  # a person's ready post is not restyled
                    problems = style_problems(own_text)
                    notes.append("human-text")
            if need_tag and members is None:
                notes.append("tag:no-members")
            elif need_tag:
                tag_problems = address_problems(text, chat, members)  # the WHOLE text: a copied address needs a tag
                reply_to = _int(args.get("reply_to"))
                if tag_problems and reply_to is not None:
                    got = MESSAGE_FETCH(chat, reply_to)
                    if got is None:  # Telegram can not say whose message it is: never block on a guess
                        tag_problems = []
                        notes.append("tag:reply-unverified")
                    else:
                        tag_problems = address_problems(text, chat, members, got[0])
        except Exception:  # noqa: BLE001 - extras must never stop the fact check below; baseline style is restored
            problems = style_problems(text)
            tag_problems = []
            notes.append("extras-error")
    fact, verdict = fact_decide(payload, now, state_dir, entries)  # facts: the WHOLE text
    for n in notes:
        verdict = n + ";" + verdict
    if tag_problems:
        verdict = "tag-deny;" + verdict
    if problems:
        verdict = "style-deny;" + verdict
    parts = []
    if problems:
        parts.append(STYLE_MARK + " Исправь до отправки: " + "; ".join(f"{i}) {p}" for i, p in
                                                                    enumerate(problems, 1)) + ".")
    if tag_problems:
        parts.append(MENTION_MARK + " " + "; ".join(tag_problems) + ".")
    if fact:
        parts.append(fact)
    return (" ".join(parts) if parts else None), verdict


def _log_time() -> str:
    try:
        from zoneinfo import ZoneInfo
        return datetime.now(ZoneInfo(LOG_TZ)).isoformat(timespec="seconds")
    except Exception:  # noqa: BLE001 - unknown zone or no tzdata: UTC
        return datetime.now(timezone.utc).isoformat(timespec="seconds")


def log(state_dir: Path, payload: dict, verdict: str) -> None:
    args = payload.get("tool_input") or {}
    if not isinstance(args, dict):
        args = {}
    rec = {"ts": _log_time(),
           "session": str(payload.get("session_id", ""))[:8],
           "tool": str(payload.get("tool_name", "")).rsplit("__", 1)[-1], "chat": str(args.get("chat_id", "")),
           "hash": text_hash(str(args.get("chat_id", "")), str(args.get("text", "")))[:12], "verdict": verdict}
    try:
        state_dir.mkdir(parents=True, exist_ok=True)
        with (state_dir / "gate.log").open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except OSError:
        pass


def main() -> int:
    if len(sys.argv) < 2:
        return 0
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError, UnicodeDecodeError):
        return 0
    if not isinstance(payload, dict):
        return 0
    state_dir = Path(sys.argv[1])
    reason, verdict = decide_verbose(payload, time.time(), state_dir)
    log(state_dir, payload, verdict)
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
