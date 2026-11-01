#!/usr/bin/env python3
"""Group watcher: wakes a channel agent on messages in a Telegram group its plugin does not see.

The channel plugin drops group updates, so this watcher reads the group through a Telegram
user-account chip (HTTP wrapper around Telethon, `?raw=true` gives sender ids) and wakes the agent
through its own webhook (/hooks/agent) via the local helper group-wake.sh. Read-only towards the
group: it never sends anything there; the agent answers with its own bot.

Default behaviour:
  * the agent is woken by a call: a tag of its bot, a reply to its message, or (GW_NAME_REGEX set)
    its name in the text; GW_ALL_HUMAN=1 makes every human message wake it (off by default);
  * people always wake it: there is no hourly cap on human wakes. Bots (GW_PEER_BOT_IDS, any member
    whose username ends in «bot», senders not verified as members) obey GW_BOT_WAKES_PER_HOUR, the
    bot<->bot loop backstop; a dropped bot call is named in the next wake;
  * messages are delivered whole. A batch that does not fit the webhook limit is split into several
    wakes sent in id order; a single message too big alone is sent in consecutive pieces;
  * edits: a tag added by an edit wakes it, a woken message corrected later is delivered again;
  * a call not answered in the group within NUDGE_AFTER_SEC gets one repeat wake;
  * media of the trigger (and of the message it answers) is downloaded via the chip and stored in
    the agent's group-media dir; voice is transcribed when GW_WHISPER_URL is set;
  * GW_FEED=1: every new message is appended as one line to a feed file of the agent (off by default).

Configuration: GW_* environment (see the unit's env file); paths and the agent user come from
guard.conf (guard_conf.py). Stop: touch <GW_BASE>/STOP, or systemctl disable --now the unit.
"""
from __future__ import annotations

import fcntl
import hashlib
import http.client
import json
import logging
import os
import re
import socket
import stat
import subprocess
import sys
import threading
import time
import urllib.parse
from concurrent.futures import ThreadPoolExecutor
from concurrent.futures import TimeoutError as FuturesTimeout
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

sys.path.insert(0, str(Path(__file__).resolve().parent))
import guard_conf  # noqa: E402  (lives next to this script)

CONF = guard_conf.load()
_ENV = os.environ.get


def _ids(value: str | None) -> frozenset[int]:
    return frozenset(int(x) for x in re.split(r"[\s,]+", value or "") if re.fullmatch(r"-?\d+", x))


def _int(name: str, default: int) -> int:
    raw = (_ENV(name) or "").strip()
    return int(raw) if re.fullmatch(r"-?\d+", raw) else default


CHAT_ID = _int("GW_CHAT_ID", 0)
GROUP_TITLE = _ENV("GW_TITLE") or str(CHAT_ID)
CHIP = (_ENV("GW_CHIP") or "").rstrip("/")
CHIP_ENV_FILE = _ENV("GW_CHIP_ENV_FILE", "")  # file with CHIP_API_TOKEN=...; empty = chip without auth
AGENT = _ENV("GW_AGENT") or CONF.main_agent
HELPER = _ENV("GW_HELPER") or str(CONF.lib_dir / "group-wake.sh")
FEED_ENABLED = _ENV("GW_FEED", "0") == "1"
WHISPER_URL = _ENV("GW_WHISPER_URL", "")  # empty = no transcription, the voice stays a file
MEDIA_PREFIX = _ENV("GW_MEDIA_PREFIX") or f"g{abs(CHAT_ID)}_"  # the media dir is per agent, shared by groups
# Every human message wakes the agent, no tag needed. Off by default; bots still need a tag and obey the bot cap.
ALL_HUMAN = _ENV("GW_ALL_HUMAN", "0") == "1"
_NAME = _ENV("GW_NAME_REGEX", "")
NAME_RE = re.compile(_NAME, re.I) if _NAME else None
NAME_TRIGGER = NAME_RE is not None
BASE = Path(_ENV("GW_BASE") or f"/var/lib/{CONF.agent_user}-group-watch/{abs(CHAT_ID)}")
STATE = BASE / "last_id"
STOP = BASE / "STOP"
WAKES = BASE / "wakes"  # record of wakes in the last hour (bounded; no cap on people)
# A chip unit with ProtectSystem=strict + ProtectHome=read-only can only write its own dir and /dev/shm.
STAGING = Path(_ENV("GW_STAGING") or f"/dev/shm/{CONF.agent_user}-group-watch-{abs(CHAT_ID)}")
STAGING_UID = _int("GW_STAGING_UID", os.getuid())  # owner of staging = the chip's user
POLL_SEC = 12
FEED_EVERY_SEC = 60
MAX_BOT_WAKES_PER_HOUR = _int("GW_BOT_WAKES_PER_HOUR", 6)  # wakes caused by bots: the bot<->bot loop backstop
NUDGE_AFTER_SEC = 180
NUDGE_TRIES = 3  # attempts of the one repeat wake
PENDING_MAX_AGE_SEC = 3600
NUDGE_SEND_TIMEOUT = 30
WAKE_MEDIA_WAIT_SEC = 20  # wake loop waits this long for the feed thread busy with the same file, then retries
MAX_MSGS_PER_TICK = 20
MAX_MEDIA_BYTES = 50 * 1024 * 1024
FEED_STATE = BASE / "feed_last_id"
MAX_FEED_PER_TICK = 50
FEED_SPEECH_BUDGET_SEC = 60  # per tick: feed transcription never holds up the next wake check for long
FEED_SPEECH_MAX_BYTES = 3 * 1024 * 1024  # longer voices stay «[голосовое]» in the feed unless woken
FEED_RECOVER_SEC = 300
FEED_TICK_BUDGET_SEC = 90  # whole feed pass incl. the append; cursor stops at the last processed id
FEED_APPEND_RESERVE_SEC = 30  # kept for the final feed-append; reads and speech get the rest
FAIL_BACKOFF_MAX_SEC = 300  # consecutive failed polls back off up to this (no hourly cap bounds a send storm)
try:
    TZ = ZoneInfo(CONF.owner_timezone)
except (ZoneInfoNotFoundError, ValueError):
    TZ = timezone.utc
LINEBREAKS = re.compile(r"[\r\n  \x85\x0b\x0c]+")
MEDIA_LABEL = {"photo": "фото", "voice": "голосовое", "audio": "аудио", "video": "видео", "video_note": "кружок",
               "sticker": "стикер", "animation": "gif", "poll": "опрос", "geo": "геолокация", "contact": "контакт",
               "unknown": "медиа"}

BOT_ID = _int("GW_BOT_ID", 0)
BOT_USERNAME = (_ENV("GW_BOT_USERNAME") or "").lstrip("@")
BOT_TAG = f"@{BOT_USERNAME}" if BOT_USERNAME else ""
# Exact username: "@<bot>_backup" is someone else.
TAG_RE = re.compile(r"(?<![A-Za-z0-9_@])" + re.escape(BOT_TAG) + r"(?![A-Za-z0-9_])", re.I) if BOT_TAG \
    else re.compile(r"(?!x)x")
PEER_BOT_IDS = _ids(_ENV("GW_PEER_BOT_IDS")) - {BOT_ID}  # bots allowed to wake it (under the bot cap)
IGNORE_IDS = _ids(_ENV("GW_IGNORE_IDS")) | {BOT_ID}  # never wake on these (its own bot always)
MEDIA_RETRIES = 3
DOWNLOADABLE = frozenset({"photo", "voice", "audio", "video", "video_note", "document", "animation", "sticker"})
SPEECH = frozenset({"voice", "audio", "video_note"})
NOT_FOUND = "Message not found"
HEAD = re.compile(r"ID: (\d+) \| ")
SAFE_NAME = re.compile(r"[^A-Za-z0-9._-]")
TAG = "[group-watch]"

log = logging.getLogger(__name__)


@dataclass
class Msg:
    id: int
    sender_name: str
    sender_id: int | None
    text: str
    reply_to: int | None
    media: str | None
    media_size: int | None
    file_name: str | None
    service: bool
    date: str = ""
    attachments: list[str] = field(default_factory=list)
    media_failed: bool = False  # transient chip/helper failure: the tick defers the wake and retries
    grouped_id: int | None = None  # album: parts share it
    fwd: str = ""  # «переслано от ...»
    links: list[str] = field(default_factory=list)  # hidden urls / mentions by name
    media_note: str = ""  # poll / geo / contact content (never downloaded)
    quote: str = ""  # quoted part of the replied message
    reply_elsewhere: bool = False  # reply_to points into ANOTHER chat: not fetched from this one
    action: str = ""  # service message: what happened
    album: list["Msg"] = field(default_factory=list)  # other parts of the album (on a trigger)
    up: "Msg | None" = None  # the message the parent itself answered (one level of context)
    edited: str = ""  # "tag" = tag added by an edit, "fix" = a woken message corrected later
    media_key: str = ""  # id of the attached photo/document: a replaced file is a new version
    reply_to_bot: bool = False  # answers ITS message: a call that needs no «is a person» check
    again: bool = False  # re-delivery of something it was already given (correction / unconfirmed send)


_POOL = ThreadPoolExecutor(max_workers=8, thread_name_prefix="chip")
_chip_token: str | None = None


def chip_headers() -> dict[str, str]:
    """x-chip-token for a chip with auth. Read once from its env file, never logged."""
    global _chip_token
    if not CHIP_ENV_FILE:
        return {}
    if _chip_token is None:
        lines = Path(CHIP_ENV_FILE).read_text(encoding="utf-8").splitlines()
        token = next((l.split("=", 1)[1].strip().strip('"') for l in lines if l.startswith("CHIP_API_TOKEN=")), "")
        if not token:
            raise RuntimeError("no CHIP_API_TOKEN in chip env file")
        _chip_token = token
    return {"x-chip-token": _chip_token}


def _fetch(conn: http.client.HTTPConnection, path: str) -> bytes:
    conn.request("GET", path, headers=chip_headers())
    r = conn.getresponse()
    if r.status != 200:
        raise RuntimeError(f"chip HTTP {r.status}")
    return r.read()


def _abort(sock: socket.socket | None, conn: http.client.HTTPConnection) -> None:
    # The socket saved right after connect(): with "Connection: close" getresponse() clears conn.sock while the
    # response keeps reading from it, so conn.sock is not enough.
    if sock is not None:
        try:
            sock.shutdown(socket.SHUT_RDWR)  # the worker's blocking recv returns at once
        except OSError:
            pass
    conn.close()


def _get(url: str, timeout: int = 30) -> dict:
    """GET with an OVERALL deadline covering headers and body. The connection is opened here and the worker
    only talks over it; at the deadline the socket is shut down, so the worker thread is released at once
    and the pool can never fill up with stuck requests. auto_open=0 stops a reconnect."""
    u = urllib.parse.urlsplit(url)
    conn = http.client.HTTPConnection(u.hostname, u.port, timeout=timeout)
    conn.connect()
    conn.auto_open = 0
    sock = conn.sock
    fut = _POOL.submit(_fetch, conn, u.path + (f"?{u.query}" if u.query else ""))
    try:
        raw = fut.result(timeout=timeout)
    except FuturesTimeout as e:
        fut.cancel()
        _abort(sock, conn)
        raise RuntimeError(f"chip request over {timeout}s") from e
    finally:
        conn.close()
    body = json.loads(raw)
    if not body.get("success"):
        err = str(body.get("error") or "")
        if not _misflagged(err):
            raise RuntimeError(f"chip error: {err[:200]}")
        body = {"success": True, "data": err}
    return body


def _misflagged(err: str) -> bool:
    """The chip calls ANY answer with "Error" in its first 50 chars an error, so a member named «ErrorMan» turns
    his message, and the listing that starts with it, into a failure: the walk would retry that id forever and
    nothing after it would ever reach the agent. A real error never looks like a listing or a message."""
    if HEAD.match(err):
        return True
    if not err.startswith("{"):
        return False
    try:
        obj = json.loads(err)
    except ValueError:
        return False
    return isinstance(obj, dict) and isinstance(obj.get("id"), int) and "raw" in obj


def fetch_top(timeout: int = 30) -> int:
    data = _get(f"{CHIP}/chats/{CHAT_ID}/messages?page=1&page_size=1", timeout=timeout).get("data") or ""
    m = HEAD.match(data)
    if not m:
        raise RuntimeError(f"unexpected listing head: {data[:80]!r}")
    return int(m.group(1))


RECENT_N = 20  # newest messages re-checked for edits every tick, in the SAME one listing call
RECENT_DEEP_N = 100  # once in RECENT_DEEP_SEC the same call looks deeper: a correction made after 20 newer messages
RECENT_DEEP_SEC = 300  # still reaches the agent; seen keeps 200 entries, so these ids are known
_deep_at = [0.0]
RECENT_SPLIT = re.compile(r"(?m)^ID: (\d+) \| ")


def text_hash(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8", "replace")).hexdigest()[:16]


def fetch_recent(timeout: int = 30) -> tuple[int, dict[int, str]]:
    """Top id plus id -> hash of the text of the newest RECENT_N messages (edits). The listing is a change
    detector only: a forged «ID: N |» line costs one raw fetch, the raw content hash decides (find_edits)."""
    deep = time.time() - _deep_at[0] >= RECENT_DEEP_SEC
    n = RECENT_DEEP_N if deep else RECENT_N
    data = _get(f"{CHIP}/chats/{CHAT_ID}/messages?page=1&page_size={n}", timeout=timeout).get("data") or ""
    if not HEAD.match(data):
        raise RuntimeError(f"unexpected listing head: {data[:80]!r}")
    marks = list(RECENT_SPLIT.finditer(data))
    out: dict[int, str] = {}
    for i, mk in enumerate(marks):
        chunk = data[mk.start():marks[i + 1].start() - 1 if i + 1 < len(marks) else len(data)]
        mid = int(mk.group(1))
        if mid not in out:
            out[mid] = text_hash(chunk.split(" | Message: ", 1)[1] if " | Message: " in chunk else "")
    if deep:
        _deep_at[0] = time.time()
    return int(marks[0].group(1)), out


def _document_info(raw: dict) -> tuple[int | None, str | None]:
    doc = (raw.get("media") or {}).get("document") or {}
    size = doc.get("size")
    name = next((a.get("file_name") for a in doc.get("attributes") or [] if a.get("file_name")), None)
    return (int(size) if isinstance(size, int) else None), name


def parse(mid: int, data: str) -> Msg | None:
    """Chip answer -> Msg. None for a missing id. Malformed answers raise so state never skips them."""
    if data == NOT_FOUND:
        return None
    msg = _clean(json.loads(data or ""))
    raw = msg.get("raw")
    if not isinstance(raw, dict) or "_" not in raw:
        raise RuntimeError(f"message {mid}: no raw object")
    service = raw["_"] == "MessageService"
    from_id = raw.get("from_id") or {}
    if not service and not from_id:
        raise RuntimeError(f"message {mid}: no from_id")
    sender = from_id.get("user_id")
    size, name = _safe(_document_info, raw, fallback=(None, None))
    rt = raw.get("reply_to") if isinstance(raw.get("reply_to"), dict) else {}
    reply = rt.get("reply_to_msg_id") if isinstance(rt.get("reply_to_msg_id"), int) else None
    text = str(msg.get("text") or "")
    grouped = raw.get("grouped_id")
    return Msg(id=mid, sender_name=str(msg.get("sender") or "?"),
               sender_id=int(sender) if sender is not None else None, text=text,
               reply_to=reply or None, media=msg.get("media_kind") if isinstance(msg.get("media_kind"), str) else None,
               media_size=size,
               file_name=name, service=service, date=str(msg.get("date") or ""),
               grouped_id=int(grouped) if isinstance(grouped, int) else None,
               fwd=_safe(_fwd, raw.get("fwd_from"), fallback="переслано (автор не прочитан)" if raw.get("fwd_from") else ""),
               links=_safe(_links, text, raw.get("entities"), fallback=["[ссылки сообщения не прочитаны]"]),
               media_note=_safe(_media_note, msg, raw.get("media"), fallback="[содержимое вложения не прочитано]"),
               quote=_safe(lambda r: str(r.get("quote_text") or ""), rt, fallback=""),
               reply_elsewhere=bool(rt.get("reply_to_peer_id")),
               action=_safe(_action, raw.get("action"), fallback="служебное") if service else "",
               media_key=_safe(_media_key, raw.get("media"), fallback=""))


def _clean(obj):
    """A lone UTF-16 surrogate (\\ud83d from the chip's JSON) cannot be encoded anywhere downstream (render, pending,
    the helper's stdin) and would jam the walk on that id forever: replace it once, here."""
    if isinstance(obj, str):
        return obj.encode("utf-8", "replace").decode("utf-8")
    if isinstance(obj, list):
        return [_clean(x) for x in obj]
    if isinstance(obj, dict):
        return {k: _clean(v) for k, v in obj.items()}
    return obj


def _safe(fn, *args, fallback):
    """Optional metadata never blocks the message itself: an unexpected raw shape becomes an explicit note."""
    try:
        return fn(*args)
    except (AttributeError, TypeError, ValueError, KeyError) as e:
        log.warning("metadata %s unreadable: %s", getattr(fn, "__name__", "?"), e)
        return fallback


def _media_key(media: object) -> str:
    if not isinstance(media, dict):
        return ""
    obj = media.get("photo") or media.get("document") or {}
    return f"{media.get('_')}:{obj.get('id')}" if isinstance(obj, dict) and obj.get("id") else ""


def content_hash(m: "Msg") -> str:
    """What the agent was given: text, hidden links, the attached file. Confirms an edit seen in the listing."""
    return text_hash("\x00".join([m.text, "|".join(m.links), m.media_key]))


def _who(uid: int) -> str:
    if uid == BOT_ID:
        return f"ты сам (user_id {uid})"
    user = _usernames.get(uid)
    kind = "бот " if uid in PEER_BOT_IDS else ""
    return f"{kind}@{user} (user_id {uid})" if user else f"{kind}user_id {uid}"


def _fwd(f: object) -> str:
    """A forward must read as a forward and say from whom: without it a quoted post looks like the member's own
    words."""
    if not isinstance(f, dict):
        return ""
    peer = f.get("from_id") or {}
    if peer.get("user_id"):
        who = _who(int(peer["user_id"]))
    elif peer.get("channel_id"):
        who = f"канал/группа id {peer['channel_id']}"
    elif peer.get("chat_id"):
        who = f"группа id {peer['chat_id']}"
    else:
        who = str(f.get("from_name") or "скрытого автора")
    if f.get("post_author"):
        who += f", автор поста {f['post_author']}"
    when = f", оригинал {local_time(str(f['date']))}" if f.get("date") else ""
    return f"переслано от {who}{when}"


def _u16_slice(text: str, offset: int, length: int) -> str:
    """Telegram entity offsets count UTF-16 units: an emoji before the link shifts a plain str slice."""
    b = text.encode("utf-16-le", "surrogatepass")
    return b[2 * offset:2 * (offset + length)].decode("utf-16-le", "replace")


def _links(text: str, entities: object) -> list[str]:
    """Hidden urls (text with a link under it) and mentions of people without a username: the visible text alone
    loses where the link goes and whom the name means."""
    out = []
    for e in entities if isinstance(entities, list) else []:
        if not isinstance(e, dict) or not isinstance(e.get("offset"), int) or not isinstance(e.get("length"), int):
            continue
        part = _u16_slice(text, e["offset"], e["length"])
        if e.get("_") == "MessageEntityTextUrl" and e.get("url"):
            out.append(f"«{part}» → {e['url']}")
        elif e.get("_") in ("MessageEntityMentionName", "InputMessageEntityMentionName") and e.get("user_id"):
            out.append(f"«{part}» = user_id {e['user_id']}")
    return out


def _media_note(msg: dict, media: object) -> str:
    """Content of media that is never downloaded: a poll, a place, a contact would read as «[без текста]»."""
    def plain(x: object) -> str:  # raw TextWithEntities {"text": ...} or a plain string
        return str(x.get("text") or "") if isinstance(x, dict) else str(x or "")
    poll = msg.get("poll")
    if not isinstance(poll, dict) and isinstance(media, dict) and media.get("_") == "MessageMediaPoll":
        poll = media.get("poll")  # the chip's top-level "poll" is optional: fall back to the raw object
    if isinstance(poll, dict):
        answers = " / ".join(plain(a.get("text")) for a in poll.get("answers") or [] if isinstance(a, dict))
        return f"опрос: {plain(poll.get('question'))}; варианты: {answers}"
    if not isinstance(media, dict):
        return ""
    kind = media.get("_", "")
    geo = media.get("geo") or {}
    where = f"{geo.get('lat')}, {geo.get('long')}" if isinstance(geo, dict) and "lat" in geo else ""
    if kind == "MessageMediaVenue":
        return f"место: {media.get('title') or ''}, {media.get('address') or ''} ({where})"
    if kind in ("MessageMediaGeo", "MessageMediaGeoLive"):
        return f"геолокация: {where}"
    if kind == "MessageMediaContact":
        name = " ".join(str(x) for x in (media.get("first_name"), media.get("last_name")) if x)
        return f"контакт: {name}, {media.get('phone_number') or ''}"
    if kind == "MessageMediaDice":
        return f"кубик {media.get('emoticon') or ''}: {media.get('value')}"
    return ""


def _action(a: object) -> str:
    """Service message: name the action and its ids instead of an empty «[пусто]»."""
    if not isinstance(a, dict):
        return "служебное"
    name = str(a.get("_") or "").removeprefix("MessageAction") or "?"
    bits = [f"{k} {v}" for k, v in a.items() if k in ("users", "user_id", "title", "inviter_id") and v]
    return f"служебное: {name}" + (f" ({', '.join(bits)})" if bits else "")


def fetch_one(mid: int, timeout: int = 30) -> Msg | None:
    return parse(mid, _get(f"{CHIP}/chats/{CHAT_ID}/messages/{mid}?raw=true", timeout=timeout).get("data"))


KNOWN_BOTS = frozenset({BOT_ID} | PEER_BOT_IDS)


def is_human(uid: int | None) -> bool:
    """A listed member whose username does not end in «bot» (Telegram requires it of every bot), not a known bot id.
    Not in the member list = NOT known to be human: see is_unverified."""
    return uid is not None and uid in _members and uid not in KNOWN_BOTS and \
        not _usernames.get(uid, "").lower().endswith("bot")


def is_unverified(uid: int | None) -> bool:
    """Sender missing from the member list even after a forced refresh (list failed, joined just now, left)."""
    return (ALL_HUMAN or NAME_TRIGGER) and uid is not None and uid not in KNOWN_BOTS and uid not in _members \
        and uid not in IGNORE_IDS


def refresh_members_for(uids: set[int]) -> None:
    """Unknown sender: re-read /participants at once, at most every MEMBERS_FORCE_SEC (chip load stays flat)."""
    global _usernames_at, _members_forced_at
    if uids - _members and time.time() - _members_forced_at >= MEMBERS_FORCE_SEC:
        _members_forced_at = time.time()
        _usernames_at = 0.0
        usernames()


def is_call(m: Msg, parent: Msg | None) -> bool:
    """A real call to the agent: tag, reply to its message, or its name. Only these get the repeat wake."""
    if m.service or m.sender_id is None or m.sender_id in IGNORE_IDS:
        return False
    if TAG_RE.search(m.text) or (parent is not None and parent.sender_id == BOT_ID):
        return True
    if NAME_RE is None or not NAME_RE.search(m.text) or named_bot(m.sender_id):  # bots: tag + bot cap only
        return False
    return is_human(m.sender_id) or is_unverified(m.sender_id)  # unverified: woken under the bot cap


def is_trigger(m: Msg, parent: Msg | None) -> bool:
    if is_call(m, parent):
        return True
    if not ALL_HUMAN or m.service or m.sender_id in IGNORE_IDS:
        return False
    return is_human(m.sender_id) or is_unverified(m.sender_id)  # unverified: woken, but under the BOT cap


def named_bot(uid: int | None) -> bool:
    """A peer bot, or any member whose username ends in «bot» (its own bot never wakes it)."""
    return uid is not None and uid != BOT_ID and (uid in PEER_BOT_IDS or _usernames.get(uid, "").lower().endswith("bot"))


def _needs_person(m: Msg) -> bool:
    """Woken only because the sender counts as a person (all-human mode, name), not by a tag or a reply to it."""
    return not TAG_RE.search(m.text) and not m.reply_to_bot and not m.again and m.edited != "fix"


_bot_inflight_ids: set[int] = set()  # ids whose last send counted as a bot wake and is not confirmed yet


def bot_like(m: Msg) -> bool:
    """Wakes that count against the bot cap: any bot, and a sender not verified as a person when only that
    classification woke it. A tag or a reply to it from an unknown sender is an ordinary call: an empty member
    list (chip down) must not queue every tagged person at the bot rate. A repeat of an unconfirmed bot-class
    send stays bot-class, so a failing re-send never escapes the cap."""
    return named_bot(m.sender_id) or (is_unverified(m.sender_id) and (_needs_person(m) or m.id in _bot_inflight_ids))


def bot_inflight_path() -> Path:
    return BASE / "bot_inflight.json"


def load_bot_inflight() -> set[int]:
    try:
        return {int(x) for x in json.loads(bot_inflight_path().read_text())}
    except (FileNotFoundError, ValueError, TypeError):
        return set()


def save_bot_inflight(ids: set[int]) -> None:
    tmp = bot_inflight_path().with_suffix(".tmp")
    tmp.write_text(json.dumps(sorted(ids)[-200:]))
    tmp.replace(bot_inflight_path())


def quota_class(m: Msg) -> str:
    """For the repeat wake: "bot" = dropped at the bot cap, "unv" = held back, "" = person (never capped)."""
    return "bot" if named_bot(m.sender_id) else ("unv" if bot_like(m) else "")


def remote(args: list[str], data: bytes | str = b"", timeout: int = 120) -> str:
    """Run the local helper: <helper> <command> <agent> <chat_id> [arg...]. The webhook token stays in the helper."""
    payload = data.encode("utf-8", "replace") if isinstance(data, str) else data  # lone surrogate = no jam
    cmd = [HELPER, args[0], AGENT, str(CHAT_ID), *args[1:]]
    env = dict(os.environ, GW_WHISPER_URL=WHISPER_URL)
    r = subprocess.run(cmd, input=payload, capture_output=True, timeout=timeout, env=env)
    if r.returncode != 0:
        raise RuntimeError(f"helper {args[0]} rc={r.returncode}: {r.stderr.decode('utf-8', 'replace')[:300]}")
    return r.stdout.decode("utf-8", "replace").strip()


def ensure_staging() -> None:
    """/dev/shm is shared: refuse a dir someone else pre-created, a loose one, or a symlink."""
    STAGING.mkdir(mode=0o700, parents=True, exist_ok=True)
    st = STAGING.lstat()
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != STAGING_UID or st.st_mode & 0o077:
        raise RuntimeError(f"unsafe staging dir {STAGING}")


# (message id, media key) -> delivered attachment notes (path, transcript). Keyed by the file version: a file replaced
# by an edit is a new key, so a feed pass still busy with the old file can not hand the old one back.
_media_done: dict[tuple[int, str], list[str]] = {}
_media_guard = threading.Lock()  # guards _media_done and _media_locks (wake loop + feed thread)
_media_locks = [threading.Lock() for _ in range(64)]  # striped by id: the same file is never fetched twice at once


def _lock_for(mid: int) -> threading.Lock:
    return _media_locks[mid % len(_media_locks)]


def media_name(m: Msg, local: Path) -> str:
    ver = f"v{hashlib.sha256(m.media_key.encode()).hexdigest()[:8]}_" if m.media_key else ""  # one file per version:
    # A -> B -> A never hands it B's file under A's cached path
    return SAFE_NAME.sub("_", f"{MEDIA_PREFIX}m{m.id}_{ver}{m.media}{local.suffix}")[:120]


def open_staging() -> int:
    """Pinned fd of the staging dir, created without following links. As root a dir we just made is handed to the
    chip user via fchown on the pinned fd; anything else must already be a 0700 dir of STAGING_UID. All file ops
    then go through this fd, so swapping the dir for a symlink after the check changes nothing."""
    try:
        os.mkdir(STAGING, 0o700)  # mkdir never follows a symlink in the last component
    except FileExistsError:
        pass
    fd = os.open(STAGING, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        st = os.fstat(fd)
        if st.st_uid != STAGING_UID and st.st_uid == 0 == os.getuid() and not st.st_mode & 0o077:
            os.fchown(fd, STAGING_UID, -1)
            st = os.fstat(fd)
        if not stat.S_ISDIR(st.st_mode) or st.st_uid != STAGING_UID or st.st_mode & 0o077:
            raise RuntimeError(f"unsafe staging dir {STAGING}")
        return fd
    except BaseException:
        os.close(fd)
        raise


def staged_name(local: Path) -> str:
    """The chip's path must name a direct child of STAGING (compared as text, nothing resolved)."""
    norm = Path(os.path.normpath(local))
    if not local.name or norm.parent != Path(os.path.normpath(STAGING)) or norm.name in (".", ".."):
        raise RuntimeError(f"chip gave no file in staging: {str(local)[:120]}")
    return norm.name


def read_staged(dfd: int, name: str) -> bytes:
    """Read the chip's file relative to the pinned staging fd: no links (O_NOFOLLOW), no FIFO hang (O_NONBLOCK,
    then S_ISREG), only a single-link regular file of the chip user (no hardlink to root data)."""
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dfd)
    with os.fdopen(fd, "rb") as f:
        st = os.fstat(f.fileno())
        if not stat.S_ISREG(st.st_mode) or st.st_uid != STAGING_UID or st.st_nlink != 1:
            raise RuntimeError("staged file is not a plain file of the chip user")
        return f.read()


def deliver_media(m: Msg, deadline: float | None = None) -> None:
    """Download m's attachment via the chip, store it in the agent's media dir, transcribe speech. Every
    failure becomes a note in the wake text: a missing file must never block the wake itself.
    deadline (feed path): every stage gets at most the time left, and a stage is not started with <5 s left."""
    def budget(default: int) -> int:
        if deadline is None:
            return default
        left = deadline - time.time()
        if left < 5:
            raise RuntimeError("feed budget exhausted")
        return int(min(default, left))
    if m.media not in DOWNLOADABLE:
        return
    lock = _lock_for(m.id)
    if deadline is None:
        if not lock.acquire(timeout=WAKE_MEDIA_WAIT_SEC):  # feed thread busy with this file (<= its budget)
            m.attachments.append(f"{m.media}: ещё обрабатывается, повторю")
            m.media_failed = True  # the tick retries in POLL_SEC and then reuses the feed's result
            return
    elif not lock.acquire(timeout=max(0.0, deadline - time.time() - 5)):
        return  # the wake loop is fetching this very file; the feed line stays a plain label
    try:
        _deliver_locked(m, deadline, budget)
    finally:
        lock.release()


def _deliver_locked(m: Msg, deadline: float | None, budget) -> None:
    with _media_guard:
        done = _media_done.get((m.id, m.media_key))
    if done is not None:  # already stored/transcribed by the feed or an earlier wake: reuse, no 2nd download
        m.attachments.extend(done)
        return
    if deadline is not None and deadline - time.time() < 5:
        return
    if m.media_size and m.media_size > MAX_MEDIA_BYTES:
        m.attachments.append(f"{m.media}: файл {m.media_size // 1048576} МБ, больше лимита, не скачан")
        return
    try:
        dfd = open_staging()
        try:
            qs = urllib.parse.urlencode({"output_path": f"{STAGING}/"})
            body = _get(f"{CHIP}/chats/{CHAT_ID}/messages/{m.id}/media?{qs}", timeout=budget(330))
            inner = body.get("data")
            inner = json.loads(inner) if isinstance(inner, str) else inner
            local = Path((inner or {}).get("path") or "")
            staged = staged_name(local)
            try:
                name = media_name(m, local)
                data = read_staged(dfd, staged)
            finally:
                try:
                    os.unlink(staged, dir_fd=dfd)
                except FileNotFoundError:
                    pass
        finally:
            os.close(dfd)
        path = remote(["put", name], data, timeout=budget(300))
        label = f"{m.media} ({m.file_name})" if m.file_name else m.media  # the stored name is ours, keep the real one
        m.attachments.append(f"{label}: {path}")
        remember = not (m.media_size and len(data) != m.media_size)  # not the file that was read: never cached
        if m.media in SPEECH and WHISPER_URL:
            try:
                text = remote(["transcribe", name], timeout=budget(330))
                m.attachments.append(f"расшифровка: {_clip_transcript(text) or '[пусто]'}")
            except Exception as e:  # noqa: BLE001 - transcript is optional, the file is delivered
                log.warning("transcribe %s failed: %s", m.id, e)
                m.attachments.append("расшифровка не получилась, файл выше")
                remember = False
        if remember and m.media_key:  # the file was fetched by id, i.e. the CURRENT one: cached under this version
            try:  # only if it still is this version, so a swap during the download never poisons it
                cur = fetch_one(m.id)
                remember = cur is not None and cur.media_key == m.media_key
            except Exception as e:  # noqa: BLE001 - not cached, downloaded again next time
                log.warning("media %s recheck failed: %s", m.id, e)
                remember = False
        if remember:
            with _media_guard:
                _media_done[(m.id, m.media_key)] = list(m.attachments)
                while len(_media_done) > 300:
                    _media_done.pop(next(iter(_media_done)))
    except Exception as e:  # noqa: BLE001 - see docstring
        log.warning("media %s failed: %s", m.id, e)
        m.attachments.append(f"{m.media}: не скачалось ({str(e)[:120]})")
        m.media_failed = True


TRANSCRIPT_MAX = 3000  # keeps a feed line far below the helper's 64 KiB tail scan


def _clip_transcript(text: str) -> str:
    if len(text) <= TRANSCRIPT_MAX:
        return text
    return f"{text[:TRANSCRIPT_MAX]}…[расшифровка обрезана, всего {len(text)} знаков; файл выше, дорасшифруй его сам]"


def bot_hint(uid: int | None, mid: int) -> str:
    """Bots often cannot reply_to each other in a group (Telegram 400): tell the agent how to answer a peer bot."""
    if uid not in PEER_BOT_IDS:
        return ""
    user = _usernames.get(uid or 0)
    tag = f"с @{user}" if user else "с тегом этого бота"
    return (f"\n    это бот: reply_to на его сообщение может не пройти (400), ответь обычным сообщением без reply_to, "
            f"{tag} и номером {mid}")


WAKE_MAX_CHARS = 60000  # the webhook rejects a message over 64K chars; a rejected wake repeats forever
NUDGE_CUTS = (None, 1500, 300)  # the repeat wake only: the full texts were in the first wake


def _clip(text: str, cap: int | None) -> str:
    return text if cap is None or len(text) <= cap else f"{text[:cap]}…[обрезано, всего {len(text)} знаков]"


EDITED = {"tag": " [тег добавлен правкой сообщения]", "fix": " [ИСПРАВЛЕНО после побудки, ниже новый текст]"}


def _line(m: Msg, tag: str) -> str:
    """One message, whole: a silently cut text reads as the full one."""
    label = media_label(m.media, m.file_name, None) if m.media and not m.attachments else ""
    body = " ".join(x for x in (m.action, label, m.text) if x) or "[без текста]"
    reply = ""
    if m.reply_to:
        reply = f" (ответ на {m.reply_to} из другого чата)" if m.reply_elsewhere else f" (ответ на {m.reply_to})"
    fwd = f" [{m.fwd}]" if m.fwd else ""
    notes = [f"цитата из того сообщения: «{m.quote}»"] if m.quote else []
    notes += [m.media_note] if m.media_note else []
    notes += [f"ссылка: {x}" for x in m.links]
    extra = "".join(f"\n    {a}" for a in notes + m.attachments)
    hint = bot_hint(m.sender_id, m.id) if not tag else ""
    return (f"{tag}message_id {m.id} | {m.sender_name} (user_id {m.sender_id}){reply}{fwd}{EDITED.get(m.edited, '')}: "
            f"{body}{extra}{hint}")


def _u16(s: str) -> int:
    """Length as the webhook's schema counts it (JS string length, UTF-16 units): an emoji is two."""
    return len(s.encode("utf-16-le", "surrogatepass")) // 2


def _u16_head(s: str, limit: int) -> str:
    """Longest prefix of s within limit UTF-16 units."""
    if _u16(s) <= limit:
        return s
    lo, hi = 0, min(len(s), limit)
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if _u16(s[:mid]) <= limit:
            lo = mid
        else:
            hi = mid - 1
    return s[:lo]


def render(items: list[tuple[Msg, Msg | None]], label: str = "") -> str:
    """The whole wake text, nothing cut. May exceed WAKE_MAX_CHARS: render_chunks splits it."""
    return label + _render(items)


PIECE_RESERVE = 200  # room for the «piece k of n» line


def render_chunks(items: list[tuple[Msg, Msg | None]], label: str = "") -> list[str]:
    """Wakes to send, in order. One wake if the whole text fits; otherwise (a single message too big alone,
    split_items leaves only that) consecutive pieces of the same whole text, so nothing is ever cut off."""
    text = render(items, label)
    if _u16(text) <= WAKE_MAX_CHARS:
        return [text]
    pieces, rest, room = [], text, WAKE_MAX_CHARS - PIECE_RESERVE
    while rest:
        head = _u16_head(rest, room)
        cut = head.rfind("\n")
        if len(head) < len(rest) and cut > len(head) // 2:
            head = head[:cut + 1]  # prefer a line boundary
        pieces.append(head)
        rest = rest[len(head):]
    ids = ", ".join(str(m.id) for m, _ in items)
    return [f"{TAG} (побудка не влезла в одну: кусок {k} из {len(pieces)}, сообщения {ids}; куски идут по порядку, "
            f"дождись всех)\n{p}" for k, p in enumerate(pieces, 1)]


def split_items(items: list[tuple[Msg, Msg | None]]) -> list[list[tuple[Msg, Msg | None]]]:
    """Consecutive parts in id order, each fitting the webhook limit with WHOLE texts: a run of long posts is never
    cut to fit one wake. Only a single message too big alone ends up in render_chunks' pieces."""
    parts: list[list[tuple[Msg, Msg | None]]] = []
    for it in items:
        if parts and _u16(_render(parts[-1] + [it])) + 100 <= WAKE_MAX_CHARS:
            parts[-1].append(it)
        else:
            parts.append([it])
    return parts


def _render(items: list[tuple[Msg, Msg | None]]) -> str:
    lines = []
    for m, parent in items:
        lines.append(_line(m, ""))
        lines += [_line(x, "  другая часть того же альбома: ") for x in m.album]
        if parent is not None:
            tag = "  ответили на твоё сообщение: " if parent.sender_id == BOT_ID else "  контекст, на что ответили: "
            lines.append(_line(parent, tag))
            if parent.up is not None:
                lines.append(_line(parent.up, "  контекст уровнем выше (на что отвечало то сообщение): "))
        elif m.reply_to and not m.reply_elsewhere:
            lines.append(f"  (сообщение {m.reply_to}, на которое ответили, удалено или недоступно)")
    head = (f"{TAG} Новые сообщения людей в группе «{GROUP_TITLE}» (chat_id {CHAT_ID}), по порядку: "
            "здесь ты получаешь ВСЕ сообщения людей, не только обращения. Отвечай на то, что к тебе или ждёт твоего "
            "ответа. Ответ в группу своим ботом: reply, chat_id " if ALL_HUMAN else
            f"{TAG} Тебя позвали в группе «{GROUP_TITLE}» (chat_id {CHAT_ID}): тег, "
            "реплай на твоё сообщение или имя. Ответь в группу своим ботом: reply, chat_id ")
    return (head +
            f"{CHAT_ID}, reply_to = message_id (кроме ботов, см. строку). Группа общая: не пиши туда ключи, пароли и "
            "внутренние детали. Файлы ниже уже лежат у тебя, открывай их по пути.\n" + "\n".join(lines))


def local_time(date_iso: str) -> str:
    try:
        return datetime.fromisoformat(date_iso.replace("Z", "+00:00")).astimezone(TZ).strftime("%d.%m %H:%M %Z")
    except ValueError:
        return "?"


def media_label(kind: str | None, file_name: str | None, transcript: str | None) -> str:
    if not kind or kind == "link_preview":
        return ""
    if kind == "document":
        return f"[файл: {file_name}]" if file_name else "[файл]"
    label = MEDIA_LABEL.get(kind, kind)
    return f"[{label}: {transcript}]" if transcript else f"[{label}]"


def feed_line(mid: int, date_iso: str, name: str, username: str | None, reply_to: int | None, text: str,
              media: str | None, file_name: str | None, transcript: str | None = None,
              path: str | None = None, extra: str = "") -> str:
    """One message = one line, so the id prefix is the dedupe key and no text can forge another entry."""
    who = f"{name} (@{username})" if username else name
    parts = [f"[{mid}] {local_time(date_iso)}", who]
    if reply_to:
        parts.append(f"ответ на {reply_to}")
    body = " ".join(x for x in (media_label(media, file_name, transcript), text.strip(), extra) if x)
    if path:
        body += f" (файл у тебя: {path})"
    parts.append(body or "[пусто]")
    return LINEBREAKS.sub(" ⏎ ", " | ".join(parts))


def feed_payload(lines: list[str]) -> bytes:
    """Batch for feed-init/feed-append with the integrity trailer the helper checks."""
    body = "".join(l + "\n" for l in lines).encode("utf-8", "replace")
    return body + f"#END {len(lines)} {hashlib.sha256(body).hexdigest()}\n".encode("ascii")


_usernames: dict[int, str] = {}
_members: set[int] = set()  # every member id from /participants, with or without a username
_usernames_at = 0.0
_members_forced_at = 0.0
MEMBERS_FORCE_SEC = 60


def usernames() -> dict[int, str]:
    """Current members id -> @username, refreshed hourly; a failure keeps the old map."""
    global _usernames_at
    if time.time() - _usernames_at > 3600:
        try:
            data = _get(f"{CHIP}/chats/{CHAT_ID}/participants").get("data")
            rows = json.loads(data) if isinstance(data, str) else data
            _usernames.clear()
            _usernames.update({int(u["id"]): u["username"] for u in rows or [] if u.get("username")})
            _members.clear()
            _members.update(int(u["id"]) for u in rows or [] if u.get("id") is not None)
            _usernames_at = time.time()
        except Exception as e:  # noqa: BLE001 - usernames are cosmetic
            _usernames_at = time.time() - 3600 + 600  # next attempt in 10 min, not on every message
            log.warning("participants failed: %s", e)
    return _usernames


def feed_entry(m: Msg, deadline: float, names: dict[int, str]) -> str:
    transcript = path = None
    if m.media in SPEECH and ((m.id, m.media_key) in _media_done or (m.media_size or 0) <= FEED_SPEECH_MAX_BYTES):
        deliver_media(m, deadline)  # live voices get a transcript; failure/over budget = plain «[голосовое]»
        for a in m.attachments:
            if a.startswith("расшифровка: "):
                transcript = a[len("расшифровка: "):]
            elif a.startswith(m.media) and ": /" in a:
                path = a[a.index(": /") + 2:]
    name = m.sender_name if not m.service else "служебное"
    extra = [f"[{m.fwd}]"] if m.fwd else []
    extra += [f"[{m.action}]"] if m.action else []
    extra += [f"[цитата: {m.quote}]"] if m.quote else []
    extra += [f"[{m.media_note}]"] if m.media_note else []
    extra += [f"[ссылка: {x}]" for x in m.links]
    return feed_line(m.id, m.date, name, names.get(m.sender_id or 0), m.reply_to, m.text, m.media,
                     m.file_name, transcript, path, " ".join(extra))


_recover_at = 0.0


def read_feed_cursor() -> int | None:
    try:
        return int(FEED_STATE.read_text().strip())
    except (FileNotFoundError, ValueError):
        return None


def write_feed_cursor(value: int) -> None:
    FEED_STATE.parent.mkdir(parents=True, exist_ok=True)
    tmp = FEED_STATE.with_suffix(".tmp")
    tmp.write_text(str(value))
    tmp.replace(FEED_STATE)


def recover_feed_cursor() -> int | None:
    """Local cursor lost (or never set): take it from the feed itself, at most every FEED_RECOVER_SEC. No feed yet
    ("none") = start it now with one marker line at the current top: the feed covers messages from here on."""
    global _recover_at
    if time.time() - _recover_at < FEED_RECOVER_SEC:
        return None
    _recover_at = time.time()
    out = remote(["feed-last"], timeout=60)
    if out == "none":
        top = fetch_top()
        now = datetime.now(timezone.utc).isoformat()
        remote(["feed-init"], feed_payload([feed_line(top, now, "group-watch", None, None,
                                                      "лента начата, дальше все новые сообщения группы", None, None)]),
               timeout=60)
        write_feed_cursor(top)
        log.info("feed started at %s", top)
        return top
    last = int(out)
    write_feed_cursor(last)
    log.info("feed cursor recovered at %s", last)
    return last


def feed_tick() -> None:
    """Append every new message to the agent's feed. Cursor moves only after the helper accepted the batch;
    the helper itself drops ids it already has, so a repeat after a crash is harmless."""
    last = read_feed_cursor()
    if last is None:  # missing, empty or garbage (crash mid-write): take it from the feed itself
        last = recover_feed_cursor()
        if last is None:
            return
    start = time.time()
    reads_end = start + FEED_TICK_BUDGET_SEC - FEED_APPEND_RESERVE_SEC

    def left() -> int:
        return max(1, min(30, int(reads_end - time.time())))

    top = fetch_top(timeout=left())
    if top <= last:
        return
    upto = min(top, last + MAX_FEED_PER_TICK)
    deadline = min(start + FEED_SPEECH_BUDGET_SEC, reads_end)
    names = usernames()  # once per batch
    lines: list[str] = []
    done = last
    for mid in range(last + 1, upto + 1):
        if done > last and time.time() >= reads_end:
            break  # the rest goes next minute; at least one id per pass always moves
        try:
            m = fetch_one(mid, timeout=left())
        except Exception:  # noqa: BLE001 - keep what is already read; this id is retried next pass
            if done == last:
                raise
            log.warning("feed read %s failed, writing the %s lines read so far", mid, len(lines))
            break
        if m is not None:
            lines.append(feed_entry(m, deadline, names))
        done = mid
    if lines:
        remote(["feed-append"], feed_payload(lines), timeout=FEED_APPEND_RESERVE_SEC)
    write_feed_cursor(done)


def save_state(value: int) -> None:
    tmp = STATE.with_suffix(".tmp")
    tmp.write_text(str(value))
    tmp.replace(STATE)


def load_state() -> int | None:
    try:
        return int(STATE.read_text().strip())
    except FileNotFoundError:
        return None


def recent_wakes(now: float, path: Path | None = None) -> list[float]:
    path = path or WAKES
    try:
        stamps = [float(x) for x in path.read_text().split()]
    except FileNotFoundError:
        return []
    return [t for t in stamps if now - t < 3600]


def note_wake(now: float, path: Path | None = None) -> None:
    path = path or WAKES
    tmp = path.with_suffix(".tmp")
    tmp.write_text(" ".join(f"{t:.0f}" for t in recent_wakes(now, path) + [now]))
    tmp.replace(path)


def bot_wakes_path() -> Path:
    return BASE / "bot_wakes"


def bot_cap_full(now: float, calls: int = 1) -> bool:
    """No room for `calls` more bot-caused webhook calls this hour. An empty quota always lets one wake through,
    even if it is a single message sent in more pieces than the cap: otherwise it could never be delivered."""
    used = len(recent_wakes(now, bot_wakes_path()))
    return used >= MAX_BOT_WAKES_PER_HOUR or (used > 0 and used + calls > MAX_BOT_WAKES_PER_HOUR)


def pending_path() -> Path:
    return BASE / "pending.json"


def load_pending() -> list[dict]:
    try:
        data = json.loads(pending_path().read_text())
    except (FileNotFoundError, ValueError):
        return []
    return [p for p in data if isinstance(p, dict) and isinstance(p.get("id"), int)] if isinstance(data, list) else []


def save_pending(items: list[dict]) -> None:
    path = pending_path()
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(items[-100:], ensure_ascii=False))
    tmp.replace(path)


def answers(m: Msg, p: dict) -> bool:
    """Does its message m answer pending trigger p? A reply to it; or, after it, a message without a reply, one
    tagging the trigger's sender (bots cannot reply_to each other, so a peer bot is answered by tag), or one
    naming the trigger's message number."""
    if m.sender_id != BOT_ID or m.service:
        return False
    if m.reply_to == p["id"]:
        return True
    batch = p.get("batch") or []
    if m.reply_to in batch and m.id > p["id"]:  # one reply to any post of the same wake answers the whole wake
        return True
    if m.id <= p["id"]:
        return False
    if m.reply_to is None:
        return True
    user = p.get("user")
    if user and re.search(r"(?<![A-Za-z0-9_])@" + re.escape(user) + r"(?![A-Za-z0-9_])", m.text, re.I):
        return True
    return re.search(r"(?<!\d)" + str(p["id"]) + r"(?!\d)", m.text) is not None


def sender_username(uid: int | None) -> str | None:
    return _usernames.get(uid or 0)


def add_pending(msgs: list[Msg], now: float, walked: list[Msg], batch: list[int] | None = None) -> None:
    """Remember woken triggers until it answers in the group (safety net). A trigger its answer already
    follows in this same walk is not remembered."""
    items = load_pending()
    have = {p["id"] for p in items}
    for m in msgs:
        p = {"id": m.id, "name": m.sender_name, "uid": m.sender_id, "user": sender_username(m.sender_id),
             "text": m.text, "woke_at": now, "tries": 0,  # whole text: the repeat cuts only to fit
             "batch": sorted(set(batch or []) | {m.id}), "q": quota_class(m)}
        if m.id not in have and not any(answers(x, p) for x in walked):
            items.append(p)
    save_pending(items)


def refresh_pending(fixes: list[Msg], now: float) -> None:
    """A delivered correction replaces the old text an unanswered trigger would be repeated with:
    the repeat must never bring back «переведи 100» after «ОТМЕНА»."""
    if not fixes:
        return
    new = {m.id: m for m in fixes}
    items = load_pending()
    hit = False
    for p in items:
        m = new.get(p["id"])
        if m is not None:
            p["text"] = m.text if len(m.text) <= 300 else \
                f"{m.text[:300]}…[обрезано, всего {len(m.text)} знаков, полный текст был в первой побудке]"
            p["woke_at"], p["tries"], hit = now, 0, True
    if hit:
        save_pending(items)


def mark_answers(walked: list[Msg]) -> None:
    items = load_pending()
    if not items:
        return
    keep = [p for p in items if not any(answers(m, p) for m in walked)]
    if len(keep) != len(items):
        log.info("answered ids=%s", sorted({p["id"] for p in items} - {p["id"] for p in keep}))
        save_pending(keep)


def render_nudge(items: list[dict]) -> str:
    for cap in NUDGE_CUTS:
        text = _render_nudge(items, cap)
        if _u16(text) <= WAKE_MAX_CHARS:
            return text
    return _u16_head(text, WAKE_MAX_CHARS - 100) + "\n…[повтор обрезан по лимиту]"  # one pending alone always fits


def _render_nudge(items: list[dict], cap: int | None) -> str:
    def body(t: str) -> str:
        return t if cap is None or len(t) <= cap else f"{t[:cap]}…[обрезано, всего {len(t)} знаков, полный текст был в первой побудке]"
    lines = [f"message_id {p['id']} | {p['name']} (user_id {p['uid']}): {body(p['text']) or '[без текста]'}"
             f"{bot_hint(p['uid'], p['id'])}" for p in items]
    return (f"{TAG} СРОЧНО, ответь строкой. Больше {NUDGE_AFTER_SEC // 60} минут назад тебя позвали "
            f"в группе «{GROUP_TITLE}» (chat_id {CHAT_ID}), твоего ответа в группе нет. Ответь сейчас одной строкой "
            "реплаем (reply, reply_to = message_id; боту без reply_to, тегом, см. строку), длинную работу отдай "
            "фоновому субагенту. Если уже ответил, ничего не пиши.\n" + "\n".join(lines))


def nudge_overdue(now: float) -> None:
    """One repeat wake for triggers it left unanswered. Called only after the walk reached the top, so every
    message of its own is already seen. Each try is recorded before sending: at most NUDGE_TRIES sends ever.
    People are never capped; bot calls obey the bot cap."""
    loaded = load_pending()
    items = [p for p in loaded if now - p["woke_at"] < PENDING_MAX_AGE_SEC and p["tries"] < NUDGE_TRIES]
    due = [p for p in items if now - p["woke_at"] >= NUDGE_AFTER_SEC]
    if not due:
        if len(items) != len(loaded):  # no rewrite every 12 s when nothing changed
            save_pending(items)
        return

    def qc(p: dict) -> str:
        return p.get("q") or ("bot" if p["uid"] in PEER_BOT_IDS else "")
    if any(qc(p) for p in due) and \
            len(recent_wakes(now, bot_wakes_path())) >= MAX_BOT_WAKES_PER_HOUR:  # repeats obey the bot cap too
        log.warning("bot wake cap reached, dropping nudge ids=%s, holding ids=%s",
                    [p["id"] for p in due if qc(p) == "bot"], [p["id"] for p in due if qc(p) == "unv"])
        items = [p for p in items if not (qc(p) == "bot" and p in due)]
        due = [p for p in due if not qc(p)]  # "unv" stays pending, tries untouched
        save_pending(items)
        if not due:
            return
    while len(due) > 1 and _u16(_render_nudge(due, NUDGE_CUTS[-1])) > WAKE_MAX_CHARS:
        due = due[:-1]  # the rest waits for the next repeat; nothing is cut off unseen
    for p in due:
        p["tries"] += 1
    save_pending(items)
    note_wake(now)
    if any(qc(p) for p in due):  # reserved before sending, like the main path
        note_wake(now, bot_wakes_path())
    remote(wake_args(), render_nudge(due), timeout=NUDGE_SEND_TIMEOUT)
    log.info("nudged agent ids=%s", [p["id"] for p in due])
    done = {p["id"] for p in due}
    save_pending([p for p in load_pending() if p["id"] not in done])


def wake_args() -> list[str]:
    return ["wake"]


media_attempts: dict[int, int] = {}  # message id -> failed media rounds, lives with the loop process


def safe_nudge() -> None:
    try:
        nudge_overdue(time.time())
    except Exception as e:  # noqa: BLE001 - the safety net never blocks fresh wakes
        log.warning("nudge failed: %s", e)


def seen_path() -> Path:
    return BASE / "seen.json"


def load_seen() -> dict[int, list]:
    """id -> [listing hash, was given to it, edit pending, content hash it was given (committed), send in flight]
    for recently walked ids. in flight = a wake with it may or may not have gone out: deliver again."""
    try:
        data = json.loads(seen_path().read_text())
        return {int(k): (v + [False, "", False])[:5] for k, v in data.items() if isinstance(v, list) and len(v) >= 2}
    except (FileNotFoundError, ValueError, AttributeError):
        return {}


def save_seen(seen: dict[int, list], top: int) -> None:
    keep = {k: v for k, v in seen.items() if k > top - 200 or v[2] or v[4]}  # open work is never pruned
    tmp = seen_path().with_suffix(".tmp")
    tmp.write_text(json.dumps({str(k): v for k, v in sorted(keep.items())}))
    tmp.replace(seen_path())


def album_delivered(m: Msg, get, seen: dict[int, list]) -> bool:
    """An earlier part of m's album (consecutive ids, same grouped_id) was already given to it."""
    mid = m.id - 1
    for _ in range(9):
        if mid < 1:
            break
        x = get(mid)
        if x is not None:
            if x.grouped_id != m.grouped_id:
                break
            if (seen.get(mid) or [None, False])[1]:
                return True
        mid -= 1
    return False


def album_parts(m: Msg, get, skip: set[int], top: int) -> list[Msg]:
    """Other parts of m's album (Telegram: up to 10, consecutive ids, one grouped_id). The tag usually sits in ONE
    caption, so without this only that one photo would reach the agent. A deleted part (None) does not end the
    search, another message does."""
    parts = []
    for step in (-1, 1):
        mid = m.id + step
        for _ in range(9):
            if mid > top or mid < 1:
                break
            x = get(mid)
            if x is None:
                mid += step
                continue
            if x.grouped_id != m.grouped_id:
                break
            if x.id not in skip:
                parts.append(x)
            mid += step
    return sorted(parts, key=lambda x: x.id)


def detect_edits(recent: dict[int, str], last: int, seen: dict[int, list]) -> bool:
    """Listing hash changed for a walked id: mark it pending in seen and SAVE at once, so a later failure/defer or the
    message leaving the 20-message window can not lose it. Returns True if seen changed."""
    changed = False
    for mid, h in recent.items():
        if mid > last:
            continue
        old = seen.get(mid)
        if old is None:  # walked before this check existed (or a burst older than the listing): start watching
            seen[mid] = [h, None, False, "", False]
            changed = True
        elif old[0] != h:
            seen[mid] = [h, old[1], True, old[3], old[4]]
            changed = True
    return changed


def find_edits(seen: dict[int, list], last: int, get) -> tuple[list[tuple[Msg, Msg | None]], dict[int, list]]:
    """Pending edits and in-flight sends of already walked ids -> wakes. The raw object confirms an edit (content
    hash vs the COMMITTED version it was given), so a text forging a listing line can not replay an old trigger.
    A tag added by an edit wakes it; a woken message corrected later wakes it with the new text even if the tag is
    gone («ОТМЕНА»). An in-flight send is always repeated with the current text: whether it went out is unknown,
    and a revert to the old text must still reach it. Updates are committed with the state."""
    items, updates = [], {}
    for mid in sorted(k for k, v in seen.items() if k <= last and (v[2] or v[4])):
        h, was, pending, old_content, inflight = seen[mid]
        m = get(mid)
        if m is None:  # deleted: nothing left to deliver
            updates[mid] = [h, was, False, old_content, False]
            continue
        content = content_hash(m)
        if not inflight and old_content and content == old_content:  # listing changed, the message did not
            updates[mid] = [h, was, False, content, False]
            continue
        parent = get(m.reply_to) if m.reply_to and not m.reply_elsewhere else None
        m.reply_to_bot = parent is not None and parent.sender_id == BOT_ID
        trig = is_trigger(m, parent)
        updates[mid] = [h, bool(trig or was), False, content, False]
        if trig or was:
            m.edited = "fix" if was and old_content and content != old_content else ("tag" if not was else "")
            m.again = was
            items.append((m, parent))
    return items, updates


def mark_inflight(items: list[tuple[Msg, Msg | None]], seen: dict[int, list], updates: dict[int, list],
                  recent: dict[int, str], top: int) -> None:
    """Before the webhook: flag every message of the wake «in flight» (and «given to it»), keeping the committed
    content hash. Until commit clears the flag, every later tick re-sends the CURRENT text: a crash after a good send,
    a failed re-send, a revert to the old text, none of them can end in silence."""
    for x in [m for m, _ in items] + [a for m, _ in items for a in m.album]:
        e = seen.get(x.id)
        if e is not None:
            seen[x.id] = [e[0], True, e[2], e[3], True]
        else:
            h = updates.get(x.id, [recent.get(x.id, text_hash(x.text))])[0]
            seen[x.id] = [h, True, False, "", True]
    save_seen(seen, top)


def deferred_path() -> Path:
    return BASE / "deferred.json"


def _load_deferred() -> dict:
    try:
        d = json.loads(deferred_path().read_text())
        return d if isinstance(d, dict) else {}
    except (FileNotFoundError, ValueError):
        return {}


def _save_deferred(d: dict) -> None:
    tmp = deferred_path().with_suffix(".tmp")
    tmp.write_text(json.dumps(d))
    tmp.replace(deferred_path())


def note_bot_dropped(ids: list[int]) -> None:
    """The bot cap drops bot calls (the bot<->bot loop backstop), but not silently: the ids are named in the next
    wake. No extra wake of its own, so the backstop keeps holding."""
    d = _load_deferred()
    ids_all = list(dict.fromkeys(list(d.get("bot_dropped") or []) + ids))  # a re-dropped id is named once
    if len(ids_all) > 200:  # never silently: the count of the oldest ones stays
        d["bot_dropped_more"] = int(d.get("bot_dropped_more") or 0) + len(ids_all) - 200
        ids_all = ids_all[-200:]
    d["bot_dropped"] = ids_all
    _save_deferred(d)


def deferred_header() -> str:
    d = _load_deferred()
    if not d.get("bot_dropped"):
        return ""
    return (f"(пропущены потолком побудок от ботов, {MAX_BOT_WAKES_PER_HOUR} в час: сообщения "
            f"{', '.join(map(str, d['bot_dropped']))}"
            + (f" и ещё {d['bot_dropped_more']} более ранних" if d.get("bot_dropped_more") else "")
            + ". Если там было что-то к тебе, прочитай и ответь тегом)\n")


def clear_deferred() -> None:
    try:
        deferred_path().unlink()
    except FileNotFoundError:
        pass


def batch_msgs(items: list[tuple[Msg, Msg | None]]) -> list[Msg]:
    out = []
    for m, p in items:
        out += [m, *m.album] + ([p] if p is not None else []) + ([p.up] if p is not None and p.up is not None else [])
    return out


def tick() -> None:
    """One poll. Ids walked one by one from last+1; state moves only after a successful wake (or when
    nothing needs one). At-least-once: a crash between wake and save repeats that wake."""
    last = load_state()
    top, recent = fetch_recent()
    if last is None:
        save_state(top)
        log.info("seeded last_id=%s", top)
        return
    upto = min(top, last + MAX_MSGS_PER_TICK) if top > last else last
    cache: dict[int, Msg | None] = {}

    def get(mid: int) -> Msg | None:
        if mid not in cache:
            cache[mid] = fetch_one(mid)
        return cache[mid]

    seen = load_seen()
    if detect_edits(recent, last, seen):  # saved BEFORE any read that can fail
        save_seen(seen, top)
    usernames()  # people vs bots: member list + usernames (bots end in «bot»)
    if ALL_HUMAN or NAME_TRIGGER:
        refresh_members_for({m.sender_id for mid in range(last + 1, upto + 1) if (m := get(mid)) is not None
                             and m.sender_id is not None and not m.service
                             and (ALL_HUMAN or (NAME_RE is not None and NAME_RE.search(m.text)))})
    items: list[tuple[Msg, Msg | None]] = []
    walked: list[Msg] = []
    updates: dict[int, list] = {}
    for mid in range(last + 1, upto + 1):
        m = get(mid)
        if m is None:
            continue
        walked.append(m)
        parent = get(m.reply_to) if m.reply_to and not m.reply_elsewhere else None
        m.reply_to_bot = parent is not None and parent.sender_id == BOT_ID
        trig = is_trigger(m, parent)
        old = seen.get(mid)
        was = bool(old and old[1])  # re-walk after a crash between send and commit
        content = content_hash(m)
        updates[mid] = [recent.get(mid, text_hash(m.text)), trig or was, False, content, False]
        if was and old[3] and old[3] != content:
            m.edited = "fix"  # it was given another version: deliver the correction
            items.append((m, parent))
        elif not trig and not was and m.grouped_id is not None and album_delivered(m, get, seen):
            m.again = True  # the rest of an album whose tagged part it already got: the parts arrived after that
            updates[mid][1] = True  # given to it: its later corrections reach it too
            items.append((m, parent))  # tick's snapshot and would never reach it otherwise
        elif trig and was and old[3] == content and not old[4]:
            pass  # this very version is confirmed delivered (an album part past the tick's end): no second wake
        elif trig or (old is not None and old[4]):  # in flight: maybe never delivered, send the current text
            m.again = not trig
            items.append((m, parent))
    edits, edit_updates = find_edits(seen, last, get)
    updates.update(edit_updates)
    items += edits
    trigger_ids = {m.id for m, _ in items}  # grows with every album part taken: two tagged captions of one
    for m, parent in items:  # album never print the third part twice
        if m.grouped_id is not None and not m.album:
            m.album = album_parts(m, get, trigger_ids, top)
            trigger_ids |= {x.id for x in m.album}
        for x in m.album:  # delivered with the trigger: its later corrections reach it too
            updates[x.id] = [recent.get(x.id, text_hash(x.text)), True, False, content_hash(x), False]
        if parent is not None and parent.reply_to and not parent.reply_elsewhere and parent.up is None:
            parent.up = get(parent.reply_to)

    def commit() -> None:  # seen first: a crash in between repeats the walk (at-least-once), never loses «was woken»
        if updates:
            seen.update(updates)
            save_seen(seen, top)
        if upto != last:
            save_state(upto)

    mark_answers(walked)
    inflight = load_bot_inflight()
    _bot_inflight_ids.clear()
    _bot_inflight_ids.update(inflight)
    if any(bot_like(m) for m, _ in items) and \
            len(recent_wakes(time.time(), bot_wakes_path())) >= MAX_BOT_WAKES_PER_HOUR:
        drop = [m.id for m, _ in items if named_bot(m.sender_id) and m.id not in inflight]
        if drop:
            log.warning("bot wake cap reached, dropping ids=%s", drop)
            note_bot_dropped(drop)  # dropped (loop backstop), but named in its next wake
            items = [(m, p) for m, p in items if m.id not in drop]
        # held back, never dropped: a sender not verified as a person, and a bot call whose send may have failed
        held = [m.id for m, _ in items if bot_like(m)]
        if held:
            log.warning("bot wake cap reached, deferring ids=%s", held)
            held_new = [i for i in held if i > last]
            if held_new:  # the walk stops right before it
                upto = min(held_new) - 1
            # a held edit (id <= last) simply stays pending/in flight in seen: its update is not committed
            items = [(m, p) for m, p in items if m.id not in held and m.id <= upto]
            for i in [k for k in updates if k > upto or k in held]:
                updates.pop(i)
    if not items:
        commit()
        if upto == top:  # the walk saw everything of its own: safe to judge «no answer»
            safe_nudge()
        return
    for m, parent in items:
        deliver_media(m)
        for x in m.album:
            if not x.attachments and not x.media_failed:
                deliver_media(x)
        if parent is not None and not parent.attachments and not parent.media_failed:
            deliver_media(parent)
        up = parent.up if parent is not None else None
        if up is not None and not up.attachments and not up.media_failed:
            deliver_media(up)  # the original question may be a voice: file + transcript, not a bare label
    msgs = batch_msgs(items)
    batch_ids = {x.id for x in msgs}
    failed = sorted({x.id for x in msgs if x.media_failed})
    # Failures are counted CUMULATIVELY per file while this batch is pending and cleared only after its
    # wake: alternating failures (A fails, then B, then A...) still exhaust in bounded ticks.
    for i in failed:
        media_attempts[i] = media_attempts.get(i, 0) + 1
    pending = [i for i in failed if media_attempts[i] < MEDIA_RETRIES]
    if pending:  # every file gets its own MEDIA_RETRIES rounds; the whole batch waits for the slowest
        raise RuntimeError(f"media failed for ids={pending}, retrying next tick")
    parts = split_items(items)
    header = deferred_header()
    saved = last  # the state only grows: a later part of old edits never moves it back
    delivered_bots: list[int] = []

    def clear_bot_class() -> None:
        nonlocal inflight
        if delivered_bots:
            inflight = load_bot_inflight() - set(delivered_bots)
            save_bot_inflight(inflight)
            _bot_inflight_ids.difference_update(delivered_bots)
            delivered_bots.clear()

    for k, part in enumerate(parts, 1):
        now = time.time()
        label = f"(часть {k} из {len(parts)}, сообщения идут по порядку)\n" if len(parts) > 1 else ""
        chunks = render_chunks(part, header + label)  # the budget counts the header too
        if any(bot_like(m) for m, _ in part) and \
                bot_cap_full(now, len(chunks)):  # every part obeys it, every piece counts
            if any(is_unverified(m.sender_id) or m.id in inflight for m, _ in part):
                log.warning("bot wake cap reached, deferring ids=%s", [m.id for m, _ in part])
                return  # state is at the previous part's end: this part comes again, in order
            dropped = [m.id for m, _ in part if named_bot(m.sender_id)]
            log.warning("bot wake cap reached, dropping ids=%s", dropped)
            note_bot_dropped(dropped)
            part = [(m, p) for m, p in part if not named_bot(m.sender_id)]
            if not part:
                continue
            chunks = render_chunks(part, header + label)
        # album parts too: each may come back alone as an in-flight repeat and must stay bot-class then
        bots = [x.id for m, _ in part if bot_like(m) for x in [m, *m.album]]
        if bots:  # bot class first, before «in flight» in seen: a crash at any later point keeps the repeat
            save_bot_inflight(inflight | set(bots))  # under the cap (held, never dropped, never uncapped)
            _bot_inflight_ids.update(bots)
        mark_inflight(part, seen, updates, recent, top)
        note_wake(now)  # record only (people are never capped); an unwritable state dir stops the wake
        if bots:  # the bot quota is reserved BEFORE sending: this bounds a failing-send storm
            for _ in chunks:  # one stamp per webhook call
                note_wake(now, bot_wakes_path())
        for text in chunks:
            remote(wake_args(), text)
        if header:
            clear_deferred()
            header = ""
        delivered_bots += bots  # bot class is cleared only after seen commits the delivery (below)
        log.info("woke agent ids=%s%s%s", [m.id for m, _ in part], f" part {k}/{len(parts)}" if len(parts) > 1 else "",
                 f" edited={[m.id for m, _ in part if m.edited]}" if any(m.edited for m, _ in part) else "")
        add_pending([m for m, p in part if is_call(m, p) and m.edited != "fix"], time.time(), walked,
                    [m.id for m, _ in part])  # a correction needs no new repeat, it refreshes the old one
        refresh_pending([m for m, _ in part], time.time())  # any delivered version replaces the repeat text
        if k < len(parts):  # this part is delivered: commit its seen entries, then the state, so a crash resumes
            done = {x.id for m, _ in part for x in [m, *m.album]}  # after it without re-sending it
            saved = max([saved] + [m.id for m, _ in part])
            later = {x.id for p in parts[k:] for m, _ in p for x in [m, *m.album]}
            # the walked messages the cursor passes are committed too: a tag added to one of them later by an
            # edit must find its seen entry, or it is neither re-walked nor detected
            seen.update({i: updates.pop(i) for i in list(updates) if i in done or (last < i <= saved and i not in later)})
            save_seen(seen, top)
            clear_bot_class()
            if saved != last:
                save_state(saved)
    for i in batch_ids:
        media_attempts.pop(i, None)
    commit()
    clear_bot_class()
    if upto == top:  # after the fresh wake: a repeat never delays a new call
        safe_nudge()


def config_errors() -> list[str]:
    errs = []
    if not CHAT_ID:
        errs.append("GW_CHAT_ID is not set")
    if not BOT_ID:
        errs.append("GW_BOT_ID is not set")
    if not CHIP.startswith("http://"):
        errs.append("GW_CHIP must be an http:// url of the chip")
    if not re.fullmatch(r"[a-z0-9-]+", AGENT):
        errs.append("GW_AGENT is not a valid agent name")
    return errs


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
    errs = config_errors()
    if errs:
        log.error("group-watch not started: %s", "; ".join(errs))
        sys.exit(2)
    os.umask(0o077)  # state holds group texts (pending, seen): private to root
    BASE.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(BASE, 0o700)  # a dir left by an older run with looser rights
    for f in BASE.iterdir():
        if f.is_file() and not f.is_symlink():
            os.chmod(f, 0o600)
    lock = (BASE / "lock").open("w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log.warning("another instance holds the lock, exiting")
        return
    if FEED_ENABLED:
        threading.Thread(target=feed_loop, name="feed", daemon=True).start()  # own thread: never delays a wake
    fails = 0
    while not STOP.exists():
        try:
            tick()
            fails = 0
        except Exception as e:  # noqa: BLE001 - keep polling on transient chip/helper errors
            fails += 1
            log.warning("poll failed: %s", e)
        time.sleep(min(FAIL_BACKOFF_MAX_SEC, POLL_SEC * 2 ** min(fails, 5)) if fails > 2 else POLL_SEC)


def feed_loop() -> None:
    while not STOP.exists():
        try:
            feed_tick()
        except Exception as e:  # noqa: BLE001 - the feed must never block the wakes
            log.warning("feed failed: %s", e)
        time.sleep(FEED_EVERY_SEC)


if __name__ == "__main__":
    main()
