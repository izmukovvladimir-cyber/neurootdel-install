#!/usr/bin/env python3
"""Tests for lib/group-watch.py: parse, trigger rules, seeding, state, caps, media notes, render, helper.

All ids, names and groups below are synthetic. Run: python3 tests/test_group_watch.py
"""
import importlib.util, json, os, sys, tempfile, time
sys.dont_write_bytecode = True
REAL_SLEEP, REAL_TIME = time.sleep, time.time
from pathlib import Path
REPO = Path(__file__).resolve().parent.parent
WATCH = str(REPO / "lib" / "group-watch.py")
HELPER = str(REPO / "lib" / "group-wake.sh")
_T0 = Path(tempfile.mkdtemp())
BASE_ENV = {"NEUROOTDEL_GUARD_CONF": str(_T0 / "no-guard.conf"), "GW_CHAT_ID": "-5550001", "GW_TITLE": "Тестовая группа",
            "GW_CHIP": "http://127.0.0.1:9", "GW_BOT_ID": "900001", "GW_BOT_USERNAME": "@team_agent_bot",
            "GW_PEER_BOT_IDS": "900002", "GW_IGNORE_IDS": "900003,900004", "GW_FEED": "1",
            "GW_WHISPER_URL": "http://127.0.0.1:9/v1/audio/transcriptions", "GW_BASE": str(_T0 / "base"),
            "GW_NAME_REGEX": r"(?<!\w)(?:тим(?:а|ы|е|у|ой|очка)|тимофе(?:й|я|ю|ем|е))(?!\w)"}
def load(name, extra=None, drop=()):
    env = {**BASE_ENV, **(extra or {})}
    saved = {k: os.environ.get(k) for k in list(env) + list(drop) + ["GW_ALL_HUMAN"]}
    os.environ.update(env)
    for k in drop:
        os.environ.pop(k, None)
    try:
        sp = importlib.util.spec_from_file_location(name, WATCH)
        mod = importlib.util.module_from_spec(sp); sys.modules[name] = mod; sp.loader.exec_module(mod)
    finally:
        for k, v in saved.items():
            if v is None: os.environ.pop(k, None)
            else: os.environ[k] = v
    return mod
w = load("w")
w.MEDIA_PREFIX = ""
PEER = 900002
J = PEER
REAL_FETCH_TOP, REAL_FETCH_ONE, REAL_REMOTE, REAL_FETCH_RECENT = w.fetch_top, w.fetch_one, w.remote, w.fetch_recent
w.fetch_recent = lambda timeout=30: (w.fetch_top(), {})  # #1740: tick reads top + recent hashes in one call
fails = 0
def ok(label, cond):
    global fails; fails += not cond; print("PASS" if cond else "FAIL", label)
def raises_any(fn):
    try:
        fn(); return False
    except (RuntimeError, OSError):
        return True
def raises(fn):
    try:
        fn(); return False
    except RuntimeError:
        return True

def raw_msg(mid, sender, text="t", reply_to=None, media=None, service=False, from_id=True, size=None, fname=None):
    raw = {"_": "MessageService" if service else "Message"}
    if from_id: raw["from_id"] = {"_": "PeerUser", "user_id": sender}
    if reply_to: raw["reply_to"] = {"_": "MessageReplyHeader", "reply_to_msg_id": reply_to}
    if size or fname:
        raw["media"] = {"_": "MessageMediaDocument", "document": {"size": size, "attributes": [{"file_name": fname}] if fname else []}}
    return json.dumps({"id": mid, "sender": f"S{sender}", "text": text, "media_kind": media, "raw": raw})

# --- parse ---
m = w.parse(5, raw_msg(5, 700001, "@Team_Agent_Bot привет", reply_to=3, media="voice", size=10, fname="a.ogg"))
ok("parse: отправитель, reply_to из raw, медиа, размер, имя", m.sender_id == 700001 and m.reply_to == 3
   and m.media == "voice" and m.media_size == 10 and m.file_name == "a.ogg" and not m.service)
ok("parse: нет сообщения = None", w.parse(5, "Message not found") is None)
ok("parse: без raw = ошибка", raises(lambda: w.parse(5, json.dumps({"id": 5, "text": "x"}))))
ok("parse: обычное без from_id = ошибка", raises(lambda: w.parse(5, raw_msg(5, 1, from_id=False))))
ok("parse: служебное без from_id допустимо", w.parse(5, raw_msg(5, 1, service=True, from_id=False)).service)

# --- is_trigger ---
P = lambda mid, sender, **k: w.parse(mid, raw_msg(mid, sender, **k))
bot_msg = P(3, w.BOT_ID, text="ответ Тимофея")
other = P(4, 700001, text="просто текст")
ok("тег бота = триггер (регистр не важен)", w.is_trigger(P(5, 700001, text="@TEAM_agent_bot глянь"), None))
ok("реплай на Тимофея = триггер", w.is_trigger(P(5, 700002, text="да", reply_to=3), bot_msg))
ok("реплай на другого без тега = нет", not w.is_trigger(P(5, 700002, text="да", reply_to=4), other))
ok("сообщение без тега = нет", not w.is_trigger(P(5, 700001, text="всем привет"), None))
ok("Владелец с тегом = триггер", w.is_trigger(P(5, 700003, text="@team_agent_bot тест"), None))
for uid in (w.BOT_ID, 900003, 900004):
    ok(f"свой/бот {uid} с тегом = нет", not w.is_trigger(P(5, uid, text="@team_agent_bot"), None))
# (b) Daria's bot wakes him (tag 1727 was dropped), with loop protection
ok("бот-помощник с тегом = триггер (случай 1727)", w.is_trigger(P(5, J, text="@team_agent_bot Тимофей, перескажи"), None))
ok("бот-помощник с тегом без реплая и без вопроса = триггер", w.is_trigger(P(5, J, text="@team_agent_bot Тимофей, всё верно."), None))
ok("бот-помощник реплаем Тимофею с вопросом = триггер", w.is_trigger(P(5, J, text="а что дальше?", reply_to=3), bot_msg))
ok("бот-помощник реплаем Тимофею = триггер (защита от петли только потолком)", w.is_trigger(P(5, J, text="принято", reply_to=3), bot_msg))
ok("бот-помощник реплаем другому без тега = нет", not w.is_trigger(P(5, J, text="да?", reply_to=4), other))
ok("человек реплаем Тимофею без вопроса = триггер (как раньше)", w.is_trigger(P(5, 700001, text="ок", reply_to=3), bot_msg))
ok("(a) опрос раз в 10-15 с", 10 <= w.POLL_SEC <= 15)
ok("чужой username с тем же началом = нет", not w.is_trigger(P(5, 700001, text="@team_agent_bot_backup глянь"), None))
ok("username внутри слова = нет", not w.is_trigger(P(5, 700001, text="abc@team_agent_bot"), None))
ok("тег в начале строки = триггер", w.is_trigger(P(5, 700001, text="(@team_agent_bot)"), None))
ok("тег с запятой после = триггер", w.is_trigger(P(5, 700001, text="@team_agent_bot, глянь"), None))
ok("служебное = нет", not w.is_trigger(P(5, 1, text="@team_agent_bot", service=True), None))

# --- staging must be writable by the sandboxed chip (ProtectSystem=strict, ProtectHome=read-only) ---
ok("staging в /dev/shm, не в /home (чип пишет только туда)", str(w.STAGING).startswith("/dev/shm/"))

# --- tick with fakes ---
tmp = Path(tempfile.mkdtemp())
w.BASE = tmp; w.STATE = tmp / "last_id"; w.WAKES = tmp / "wakes"; w.STAGING = tmp / "media"
store = {}
w.fetch_top = lambda: max(store)
w.fetch_one = lambda mid: w.parse(mid, store[mid]) if mid in store else None
calls = []
def fake_remote(args, data=b"", timeout=120):
    calls.append((args, data)); return "woken"
w.remote = fake_remote
store[10] = raw_msg(10, 700001, "@team_agent_bot старое")
w.tick()
ok("первый запуск: засев без побудки", w.STATE.read_text() == "10" and not calls)
store[11] = raw_msg(11, 700001, "обычное")
store[12] = raw_msg(12, w.BOT_ID, "я Тимофей")
w.tick()
ok("без триггеров: state двигается, побудки нет", w.STATE.read_text() == "12" and not calls)
store[13] = raw_msg(13, 700002, "ок, сделай", reply_to=12)
store[14] = raw_msg(14, 700001, "@team_agent_bot посмотри это", reply_to=11)
w.tick()
ok("одна побудка на пачку", len(calls) == 1 and calls[0][0] == ["wake"])
text = calls[0][1]
ok("в тексте chat_id, message_id обоих, контекст ответа", "-5550001" in text and "message_id 13" in text
   and "message_id 14" in text and "контекст, на что ответили: message_id 11" in text)
ok("ответ Тимофею помечен как ответ на его сообщение", "ответили на твоё сообщение: message_id 12" in text)
ok("state после побудки", w.STATE.read_text() == "14")

calls.clear()
def failing(args, data=b"", timeout=120):
    raise RuntimeError("helper down")
w.remote = failing
store[15] = raw_msg(15, 700001, "@team_agent_bot ещё")
ok("побудка упала = ошибка наружу", raises(w.tick))
ok("и state не двинулся", w.STATE.read_text() == "14")
w.remote = fake_remote
w.WAKES.write_text(" ".join(str(int(time.time())) for _ in range(500)))
w.tick()
ok("людей без часового потолка: 500 побудок за час не мешают, будим", len(calls) == 1 and "message_id 15 " in calls[0][1]
   and w.STATE.read_text() == "15" and "ОЧЕРЕДЬ" not in calls[0][1])
ok("в модуле нет часового потолка на людей", not hasattr(w, "MAX_WAKES_PER_HOUR") and not hasattr(w, "overflow_notice"))

# --- wake reservation: unwritable wakes file = no wake at all ---
calls.clear()
store[16] = raw_msg(16, 700001, "@team_agent_bot резерв")
real_note = w.note_wake
w.note_wake = lambda now: (_ for _ in ()).throw(OSError("disk full"))
try:
    w.tick(); note_failed = False
except OSError:
    note_failed = True
ok("не записали резерв = не будим, state стоит", note_failed and not calls and w.STATE.read_text() == "15")
w.note_wake = real_note
before = len(w.recent_wakes(time.time()))
w.remote = failing
ok("упавшая побудка тоже записана в учёт побудок", raises(w.tick) and len(w.recent_wakes(time.time())) == before + 1)
w.remote = fake_remote
w.tick()
ok("следующий тик доставил", len(calls) == 1 and w.STATE.read_text() == "16")

# --- media failure: retry the batch up to MEDIA_RETRIES, then wake with the note ---
calls.clear(); w.WAKES.write_text("")
store[17] = raw_msg(17, 700001, "@team_agent_bot голос", media="voice")
real_get = w._get
w._get = lambda url, timeout=30: (_ for _ in ()).throw(RuntimeError("chip down"))
r1 = raises(w.tick); r2_ = raises(w.tick)
ok("медиа упало: 2 раунда без побудки, state стоит", r1 and r2_ and not calls and w.STATE.read_text() == "16")
w.tick()
ok("3-й раунд: будим с заметкой", len(calls) == 1 and "не скачалось" in calls[0][1] and w.STATE.read_text() == "17"
   and 17 not in w.media_attempts)
w._get = real_get

# --- two files failing alternately: each gets its own MEDIA_RETRIES rounds ---
calls.clear(); w.WAKES.write_text(""); w.media_attempts.clear()
store[18] = raw_msg(18, 700001, "фото A", media="photo")
store[19] = raw_msg(19, 700002, "@team_agent_bot смотри", media="photo", reply_to=18)
plan = {18: [True, True, True], 19: [False, False, True]}  # True = fails on that round
rnd = [0]
def fake_deliver(m):
    if plan[m.id][rnd[0]]:
        m.attachments.append("не скачалось"); m.media_failed = True
    else:
        m.attachments.append("ok")
real_deliver = w.deliver_media
w.deliver_media = fake_deliver
res = []
for r in range(3):
    rnd[0] = r
    try:
        w.tick(); res.append("woke")
    except RuntimeError:
        res.append("retry")
ok("19 упал впервые на 3-м раунде: побудки нет, ждём его повторов", res == ["retry", "retry", "retry"] and not calls)
plan = {18: [True], 19: [True]}; rnd[0] = 0
for _ in range(2):
    try:
        w.tick(); res.append("woke")
    except RuntimeError:
        res.append("retry")
ok("после исчерпания у обоих: побудка", res[-1] == "woke" and len(calls) == 1 and w.STATE.read_text() == "19"
   and not w.media_attempts)
w.deliver_media = real_deliver

# --- alternating failures must still end in a wake ---
calls.clear(); w.WAKES.write_text(""); w.media_attempts.clear()
store[22] = raw_msg(22, 700001, "фото A", media="photo")
store[23] = raw_msg(23, 700002, "@team_agent_bot смотри", media="photo", reply_to=22)
tickno = [0]
def alt_deliver(m):
    bad = (m.id == 22) == (tickno[0] % 2 == 0)
    m.attachments.append("не скачалось" if bad else "ok"); m.media_failed = bad
w.deliver_media = alt_deliver
woke_at = None
for t in range(10):
    tickno[0] = t
    try:
        w.tick(); woke_at = t; break
    except RuntimeError:
        pass
ok("чередование сбоев: побудка за конечное число тиков", woke_at is not None and woke_at <= 2 * w.MEDIA_RETRIES
   and len(calls) == 1 and w.STATE.read_text() == "23")
w.deliver_media = real_deliver

# --- reply to the agent's own media: parent media delivered too ---
calls.clear(); w.WAKES.write_text("")
store[24] = raw_msg(24, w.BOT_ID, "вот аудио", media="voice")
store[25] = raw_msg(25, 700001, "расшифруй", reply_to=24)
seen = []
w.deliver_media = lambda m: seen.append(m.id)
w.tick()
ok("медиа сообщения Тимофея, на которое ответили, тоже доставляется", 24 in seen and len(calls) == 1)
w.deliver_media = real_deliver

# --- media ---
big = w.parse(20, raw_msg(20, 1, media="video", size=w.MAX_MEDIA_BYTES + 1))
w.deliver_media(big)
ok("большой файл: заметка вместо скачивания", "больше лимита" in big.attachments[0])
link = w.parse(21, raw_msg(21, 1, media="link_preview"))
w.deliver_media(link)
ok("превью ссылки не качаем", link.attachments == [])
w._get = lambda url, timeout=30: (_ for _ in ()).throw(RuntimeError("chip down"))
v = w.parse(22, raw_msg(22, 1, media="voice"))
w.deliver_media(v)
ok("сбой скачивания = заметка, без исключения", "не скачалось" in v.attachments[0])
def chip_ok(url, timeout=30):
    f = w.STAGING / "tg_media_x_23.oga"; f.write_bytes(b"OGG")
    return {"data": json.dumps({"success": True, "path": str(f)})}
w._get = chip_ok
rcalls = []
def r2(args, data=b"", timeout=120):
    rcalls.append(args)
    return "/home/neurootdel/x/m23_voice.oga" if args[0] == "put" else "привет это голос"
w.remote = r2
v = w.parse(23, raw_msg(23, 1, media="voice"))
w.deliver_media(v)
ok("голос: файл передан, расшифровка добавлена, staging почищен",
   rcalls == [["put", "m23_voice.oga"], ["transcribe", "m23_voice.oga"]]
   and "m23_voice.oga" in v.attachments[0] and "привет это голос" in v.attachments[1]
   and not list(w.STAGING.iterdir()))
_wh = w.WHISPER_URL; w.WHISPER_URL = ""; rcalls.clear()
v = w.parse(27, raw_msg(27, 1, media="voice")); w.deliver_media(v)
ok("голос без GW_WHISPER_URL: файл передан, распознавание не вызывается", rcalls == [["put", "m27_voice.oga"]]
   and len(v.attachments) == 1 and not v.media_failed)
w.WHISPER_URL = _wh
def chip_outside(url, timeout=30):
    return {"data": json.dumps({"success": True, "path": "/etc/passwd"})}
w._get = chip_outside
d = w.parse(24, raw_msg(24, 1, media="document"))
w.deliver_media(d)
w._get = chip_ok
loose = w.STAGING; loose.chmod(0o755)
d2 = w.parse(26, raw_msg(26, 1, media="document"))
w.deliver_media(d2)
ok("staging с чужими правами отвергнут", "не скачалось" in d2.attachments[0] and "unsafe" in d2.attachments[0])
loose.chmod(0o700)
w._get = chip_outside
ok("путь вне staging отвергнут", "не скачалось" in d.attachments[0])
ok("имя медиа безопасное", w.media_name(w.parse(25, raw_msg(25, 1, media="voice")), Path("a b;$.oga")) == "m25_voice.oga")

# --- feed: line format ---
L = w.feed_line(1700, "2026-10-24T07:08:28+00:00", "Тимофей", "team_agent_bot", 1699, "строка1\nстрока2 [9999] фейк", None, None)
ok("лента: id, время владельца, автор с @, ответ, текст в одну строку", L.startswith("[1700] 24.10 10:08 MSK | Тимофей (@team_agent_bot) | ответ на 1699 | строка1 ⏎ строка2 ⏎ [9999] фейк") and "\n" not in L)
ok("лента: голос с расшифровкой и путём", w.feed_line(5, "2026-10-24T07:00:00+00:00", "В", None, None, "", "voice", None, "привет", "/x/m5.oga") == "[5] 24.10 10:00 MSK | В | [голосовое: привет] (файл у тебя: /x/m5.oga)")
ok("лента: голос без расшифровки", w.feed_line(5, "", "В", None, None, "", "voice", None).endswith("| В | [голосовое]"))
ok("лента: файл с именем, фото с подписью", w.media_label("document", "a.pdf", None) == "[файл: a.pdf]"
   and w.feed_line(6, "", "В", None, None, "смотри", "photo", None).endswith("[фото] смотри"))
ok("лента: превью ссылки без метки, пустое = [пусто]", w.media_label("link_preview", None, None) == "" and w.feed_line(7, "", "В", None, None, "", None, None).endswith("[пусто]"))

# --- feed_tick ---
fcalls = []
remote_last = ["none"]
def strip_trailer(data):
    if isinstance(data, bytes) and data:
        text = data.decode("utf-8")
        body, _, trailer = text.rstrip("\n").rpartition("\n")
        assert trailer.startswith("#END "), "no integrity trailer"
        return body + "\n" if body else ""
    return data
def feed_remote(args, data=b"", timeout=120):
    fcalls.append((args, strip_trailer(data)))
    return remote_last[0] if args == ["feed-last"] else "appended"
w.remote = feed_remote
w.FEED_STATE = tmp / "feed_last_id"
orig_usernames = w.usernames
w.usernames = lambda: {700001: "anna_member"}
w.FEED_STATE.unlink(missing_ok=True)
w.fetch_top = lambda timeout=30: 28
w.feed_tick()
ok("ленты нет (feed-last=none) = лента начата меткой на текущем верху", [c[0] for c in fcalls] == [["feed-last"], ["feed-init"]]
   and fcalls[1][1].startswith("[28] ") and fcalls[1][1].count("\n") == 1 and w.FEED_STATE.read_text() == "28")
w.FEED_STATE.unlink(); fcalls.clear(); w.feed_tick()
ok("повторный запрос курсора не чаще раза в 5 мин", not fcalls)
w._recover_at = 0.0; remote_last[0] = "29"; fcalls.clear()
fstore0 = {}
w.fetch_top = lambda timeout=30: 29
w.feed_tick()
ok("потерянный локальный курсор восстановлен из ленты", w.FEED_STATE.read_text() == "29" and fcalls == [(["feed-last"], b"")])
fcalls.clear()
fstore = {30: raw_msg(30, 700001, "привет"), 31: raw_msg(31, 900002, "я бот-помощник, бот"), 32: raw_msg(32, 1, service=True, from_id=False)}
w.fetch_top = lambda timeout=30: max(fstore)
w.fetch_one = lambda mid, timeout=30: w.parse(mid, fstore[mid]) if mid in fstore else None
w.FEED_STATE.write_text("29")
w.feed_tick()
ok("лента: все новые, включая ботов и служебные, одной пачкой", len(fcalls) == 1 and fcalls[0][0] == ["feed-append"]
   and fcalls[0][1].count("\n") == 3 and "(@anna_member)" in fcalls[0][1] and "я бот-помощник, бот" in fcalls[0][1])
ok("курсор ленты сдвинут", w.FEED_STATE.read_text() == "32")
fstore[33] = raw_msg(33, 1, "x")
w.remote = lambda args, data=b"", timeout=120: (_ for _ in ()).throw(RuntimeError("helper down"))
ok("сбой записи = ошибка, курсор стоит", raises(w.feed_tick) and w.FEED_STATE.read_text() == "32")
w.remote = feed_remote

# --- feed transcription budget: over deadline or too big = plain label, no download ---
dcalls = []
w.deliver_media = lambda m, deadline=None: dcalls.append((m.id, deadline is not None))
big_v = w.parse(40, raw_msg(40, 1, text="", media="voice", size=w.FEED_SPEECH_MAX_BYTES + 1))
ok("большой голос в ленте без скачивания", w.feed_entry(big_v, time.time() + 60, {}).endswith("[голосовое]") and not dcalls)
w.feed_entry(w.parse(42, raw_msg(42, 1, media="voice", size=1000)), time.time() + 60, {})
ok("в бюджете: доставка с дедлайном", dcalls == [(42, True)])
w.deliver_media = real_deliver
late_v = w.parse(41, raw_msg(41, 1, text="", media="voice", size=1000))
got = []
w._get = lambda url, timeout=30: got.append(timeout) or (_ for _ in ()).throw(RuntimeError("x"))
ok("бюджет исчерпан = без скачивания", w.feed_entry(late_v, time.time() - 1, {}).endswith("[голосовое]") and not got)
v43 = w.parse(43, raw_msg(43, 1, media="voice", size=1000))
w.deliver_media(v43, time.time() + 20)
ok("таймаут этапа не больше остатка бюджета", got and got[0] <= 20)
w._get = real_get

# --- participants failure: one attempt per batch, backoff ---
pcalls = []
w.usernames = orig_usernames
w._usernames_at = 0.0
def part_get(url, timeout=30):
    if "/participants" in url:
        pcalls.append(url); raise RuntimeError("participants timeout")
    raise AssertionError(url)
w._get = part_get
for i in (50, 51, 52):
    fstore[i] = raw_msg(i, 1, "x")
w.FEED_STATE.write_text("49")
w.fetch_top = lambda timeout=30: 52
w.feed_tick()
ok("отказ participants: одна попытка на пачку", len(pcalls) == 1 and w.FEED_STATE.read_text() == "52")
fstore[53] = raw_msg(53, 1, "y"); w.fetch_top = lambda timeout=30: 53
w.feed_tick()
ok("и следующая не раньше чем через 10 мин", len(pcalls) == 1)
w._get = real_get

# --- empty cursor (crash mid-write) is recovered from the feed ---
w.FEED_STATE.write_text("")
w._recover_at = 0.0; remote_last[0] = "53"; fcalls.clear()
w.feed_tick()
ok("пустой курсор восстановлен с сервера", w.FEED_STATE.read_text() == "53" and fcalls[0][0] == ["feed-last"])

# (a) the feed runs in its own thread: a feed pass stuck for long does not stop the wake polls
import threading as _thr
order = []
real_tick, real_feed_tick = w.tick, w.feed_tick
feed_gate = _thr.Event()
def stuck_feed():
    order.append("feed"); feed_gate.wait(10)
def counting_tick():
    order.append("tick")
    if order.count("tick") >= 5:
        w.STOP.write_text("1")
w.tick = counting_tick
w.feed_tick = stuck_feed
w.STOP = tmp / "STOP_loop"
w.time.sleep = lambda s_: REAL_SLEEP(0.01)
_um0 = os.umask(0o022); os.umask(_um0)
w.main()
os.umask(_um0)
feed_gate.set()
ok("лента в своём потоке: зависшая лента не держит побудки", order.count("tick") >= 5 and order.count("feed") == 1)
w.time.sleep = lambda s_: w.STOP.write_text("1")
w.tick, w.feed_tick = real_tick, real_feed_tick

# --- helper feed logic (embedded python of lib/group-wake.sh, run locally) ---
import subprocess
src = Path(HELPER).read_text()
feed_py = src.split("readonly feed_py='\n")[1].split("\n'\n")[0]
fd = tmp / "feed"
def run(mode, data, trailer=True):
    lines = [l for l in data.split("\n") if l]
    payload = w.feed_payload(lines) if trailer and mode != "last" else data.encode()
    return subprocess.run([sys.executable, "-c", feed_py, str(fd), mode], input=payload, capture_output=True)
ok("append до init = отказ", run("append", "[1] a\n").returncode != 0)
r = run("init", "[1] a\n[2] b\n")
ok("init пишет ленту", r.returncode == 0 and (fd / "feed.md").read_text() == "[1] a\n[2] b\n")
ok("повторный init = отказ", run("init", "[3] c\n").returncode != 0)
r = run("append", "[2] b\n[3] c\n")
ok("append отбрасывает уже записанные id", r.returncode == 0 and (fd / "feed.md").read_text() == "[1] a\n[2] b\n[3] c\n")
ok("строка без [id] = отказ целиком", run("append", "[4] d\nподделка\n").returncode != 0 and "[4]" not in (fd / "feed.md").read_text())
with open(fd / "feed.md", "a") as f:
    f.write("[4] обрыв посреди стро")
ok("feed-last чинит оборванный хвост и берёт id последней целой строки", run("last", "").stdout.decode().strip() == "3"
   and (fd / "feed.md").read_text().endswith("[3] c\n"))
r = run("append", "[4] d\n[5] e\n")
ok("после обрыва та же пачка дописывается целиком, без дублей", (fd / "feed.md").read_text() == "[1] a\n[2] b\n[3] c\n[4] d\n[5] e\n")
fd2 = tmp / "feed2"
ok("feed-last до засева = none", subprocess.run([sys.executable, "-c", feed_py, str(fd2), "last"], capture_output=True).stdout.decode().strip() == "none")
ok("init атомарный: нет хвостового .tmp", subprocess.run([sys.executable, "-c", feed_py, str(fd2), "init"], input=w.feed_payload(["[7] x"]), capture_output=True).returncode == 0
   and not (fd2 / "feed.md.tmp").exists() and (fd2 / "feed.md").read_text() == "[7] x\n")

# --- feed pass budget: slow fetches stop the pass, cursor = last processed, next pass continues ---
w.usernames = lambda: {}
w.remote = feed_remote; fcalls.clear()
for i in range(60, 66):
    fstore[i] = raw_msg(i, 1, f"m{i}")
w.write_feed_cursor(59)
w.fetch_top = lambda timeout=30: 65
clock = [1000.0]
real_time = time.time
w.time.time = lambda: clock[0]
tos = []
def slow_fetch(mid, timeout=30):
    tos.append(timeout)
    clock[0] += 25
    return w.parse(mid, fstore[mid])
w.fetch_one = slow_fetch
w._recover_at = 0.0
w.feed_tick()
first = w.FEED_STATE.read_text()
ok("медленные чтения: проход остановлен по бюджету", first == "62" and fcalls[-1][1].count("\n") == 3)
ok("таймаут чтения не больше остатка, дозапись в резерве", max(tos) <= 30 and tos[-1] <= 60 - 50 and fcalls[-1][0] == ["feed-append"])
w.feed_tick(); w.feed_tick()
ok("следующие проходы продолжают без пропусков", w.FEED_STATE.read_text() == "65"
   and sum(c[1].count("\n") for c in fcalls if c[0] == ["feed-append"]) == 6)
w.time.time = real_time

# --- _get: overall deadline covers slow headers and slow body (real local HTTP server) ---
import http.server, socketserver, threading
class SlowHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            if self.path == "/headers":
                self.wfile.write(b"HTTP/1.1 200 OK\r\n")
                for i in range(100):
                    self.wfile.write(f"X-{i}: y\r\n".encode()); self.wfile.flush(); REAL_SLEEP(0.05)
                return
            if self.path == "/endless":  # HTTP/1.0 => Connection: close, body never ends
                self.send_response(200); self.end_headers()
                for _ in range(1200):
                    self.wfile.write(b" "); self.wfile.flush(); REAL_SLEEP(0.05)
                return
            body = json.dumps({"success": True, "data": "ok"}).encode()
            self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers()
            if self.path == "/slowbody":
                for ch in body:
                    self.wfile.write(bytes([ch])); self.wfile.flush(); REAL_SLEEP(0.1)
            else:
                self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass
    def log_message(self, *a): pass
srv = socketserver.ThreadingTCPServer(("127.0.0.1", 0), SlowHandler); srv.daemon_threads = True
threading.Thread(target=srv.serve_forever, daemon=True).start()
base = f"http://127.0.0.1:{srv.server_address[1]}"
for path in ("/headers", "/slowbody"):
    t0 = REAL_TIME()
    ok(f"_get {path}: обрыв по общему дедлайну", raises(lambda: real_get(base + path, timeout=1)) and REAL_TIME() - t0 < 1.8)
ok("_get: быстрый ответ читается", real_get(base + "/fast", timeout=5)["data"] == "ok")
for _ in range(10):  # more never-ending close-delimited responses than pool workers
    raises(lambda: real_get(base + "/endless", timeout=1))
t0 = REAL_TIME()
ok("после 10 зависших запросов пул свободен: быстрый ответ сразу", real_get(base + "/fast", timeout=3)["data"] == "ok"
   and REAL_TIME() - t0 < 1.0)
import threading as _th
REAL_SLEEP(0.3)
ok("зависшие рабочие потоки освобождены", sum(1 for th in _th.enumerate() if th.name.startswith("chip")) <= 8)
srv.shutdown()

# --- feed: a failing read keeps the already-read prefix ---
fcalls.clear()
for i in range(70, 73):
    fstore[i] = raw_msg(i, 1, f"m{i}")
w.write_feed_cursor(69)
w.fetch_top = lambda timeout=30: 72
def flaky(mid, timeout=30):
    if mid == 72:
        raise RuntimeError("chip request over 10s")
    return w.parse(mid, fstore[mid])
w.fetch_one = flaky
w.feed_tick()
ok("сбой чтения посреди прохода: префикс записан, курсор до него", w.FEED_STATE.read_text() == "71"
   and fcalls[-1][1].count("\n") == 2)
w.write_feed_cursor(71)
ok("сбой на первом же id = ошибка, курсор стоит", raises(w.feed_tick) and w.FEED_STATE.read_text() == "71")

# --- integrity trailer: a cut batch is rejected, the full retry lands exactly once ---
before = (fd / "feed.md").read_text()
full = w.feed_payload(["[6] шесть целиком", "[7] семь целиком"])
cut = full[: full.index(b"\xd1\x86\xd0\xb5\xd0\xbb") ]  # cut inside line 6, as a dropped ssh would
ok("оборванная пачка отвергнута, лента не тронута", subprocess.run([sys.executable, "-c", feed_py, str(fd), "append"], input=cut, capture_output=True).returncode != 0
   and (fd / "feed.md").read_text() == before)
bad = full.replace(b"#END 2", b"#END 3")
ok("неверное число строк отвергнуто", subprocess.run([sys.executable, "-c", feed_py, str(fd), "append"], input=bad, capture_output=True).returncode != 0)
ok("без хвоста отвергнуто", run("append", "[6] x\n", trailer=False).returncode != 0)
r = subprocess.run([sys.executable, "-c", feed_py, str(fd), "append"], input=full, capture_output=True)
ok("полный повтор записан ровно один раз", r.returncode == 0 and (fd / "feed.md").read_text() == before + "[6] шесть целиком\n[7] семь целиком\n")

# --- (b) bot wake cap and (c) safety net: repeat wake after 3 min without his answer ---
tmp3 = Path(tempfile.mkdtemp())
w.BASE = tmp3; w.STATE = tmp3 / "last_id"; w.WAKES = tmp3 / "wakes"
w.deliver_media = lambda m, deadline=None: None
st = {}
w.fetch_top = lambda timeout=30: max(st)
w.fetch_one = lambda mid, timeout=30: w.parse(mid, st[mid]) if mid in st else None
nc = []
w.remote = lambda args, data=b"", timeout=120: nc.append((args, data)) or "woken"
st[100] = raw_msg(100, 1, "старт"); w.tick()
st[101] = raw_msg(101, J, "@team_agent_bot Тимофей, проверка")
w.tick()
ok("(b) тег бота-помощника будит, учтён в потолке ботов", len(nc) == 1 and "message_id 101" in nc[0][1]
   and len(w.recent_wakes(time.time(), w.bot_wakes_path())) == 1)
ok("(c) после побудки ждём ответа", [p["id"] for p in w.load_pending()] == [101])
w.tick()
ok("(c) до 3 минут повтора нет", len(nc) == 1)
pend = w.load_pending(); pend[0]["woke_at"] -= w.NUDGE_AFTER_SEC + 1; w.save_pending(pend)
st[102] = raw_msg(102, 700001, "просто текст")
w.tick()
ok("(c) нет ответа 3 мин: одна повторная побудка «срочно»", len(nc) == 2 and "СРОЧНО, ответь строкой" in nc[1][1]
   and "message_id 101" in nc[1][1] and not w.load_pending())
w.tick()
ok("(c) повтор ровно один", len(nc) == 2)
# answered by a reply: no repeat
st[103] = raw_msg(103, 700001, "@team_agent_bot вопрос")
w.tick(); n0 = len(nc)
pend = w.load_pending(); pend[0]["woke_at"] -= w.NUDGE_AFTER_SEC + 1; w.save_pending(pend)
st[104] = raw_msg(104, w.BOT_ID, "ответ", reply_to=103)
w.tick()
ok("(c) ответил реплаем: повтора нет, ожидание снято", len(nc) == n0 and not w.load_pending())
# answered without a reply: covers earlier triggers
st[105] = raw_msg(105, 700001, "@team_agent_bot ещё")
w.tick(); n0 = len(nc)
st[106] = raw_msg(106, w.BOT_ID, "отвечаю всем")
pend = w.load_pending(); pend[0]["woke_at"] -= w.NUDGE_AFTER_SEC + 1; w.save_pending(pend)
w.tick()
ok("(c) ответ без реплая закрывает более ранние", len(nc) == n0 and not w.load_pending())
# the walk has not reached the top yet: no repeat (his answer may be further on)
st[107] = raw_msg(107, 700001, "@team_agent_bot раз")
w.tick(); n0 = len(nc)
pend = w.load_pending(); pend[0]["woke_at"] -= w.NUDGE_AFTER_SEC + 1; w.save_pending(pend)
for i in range(108, 108 + w.MAX_MSGS_PER_TICK + 1):
    st[i] = raw_msg(i, 1, "шум")
st[108 + w.MAX_MSGS_PER_TICK + 1] = raw_msg(108 + w.MAX_MSGS_PER_TICK + 1, w.BOT_ID, "ответ", reply_to=107)
w.tick()
ok("(c) обход не дошёл до верха: повтор не шлём", len(nc) == n0 and w.load_pending())
w.tick()
ok("(c) дошёл и увидел ответ: повтора нет", len(nc) == n0 and not w.load_pending())
# repeat failing: retried, bounded
top = max(st)
st[top + 1] = raw_msg(top + 1, 700001, "@team_agent_bot два")
w.tick(); n0 = len(nc)
pend = w.load_pending(); pend[0]["woke_at"] -= w.NUDGE_AFTER_SEC + 1; w.save_pending(pend)
fails_n = []
w.remote = lambda args, data=b"", timeout=120: fails_n.append(1) or (_ for _ in ()).throw(RuntimeError("helper down"))
for _ in range(w.NUDGE_TRIES + 3):
    w.tick()
ok("(c) упавший повтор: не больше NUDGE_TRIES попыток, тик не падает", len(fails_n) == w.NUDGE_TRIES)
w.remote = lambda args, data=b"", timeout=120: nc.append((args, data)) or "woken"
# bot cap: over the cap Daria's tag is dropped, a human in the same batch still wakes
w.save_pending([])
w.WAKES.write_text("")
w.bot_wakes_path().write_text(" ".join(str(int(time.time())) for _ in range(w.MAX_BOT_WAKES_PER_HOUR)))
top = max(st)
st[top + 1] = raw_msg(top + 1, J, "@team_agent_bot бот")
st[top + 2] = raw_msg(top + 2, 700001, "@team_agent_bot человек")
n0 = len(nc); w.tick()
ok("(b) потолок ботов: тег бота-помощника пропущен, человек разбужен", len(nc) == n0 + 1 and f"message_id {top + 2}" in nc[-1][1]
   and f"message_id {top + 1}" not in nc[-1][1] and w.STATE.read_text() == str(top + 2))
st[top + 3] = raw_msg(top + 3, J, "@team_agent_bot только бот")
n0 = len(nc); w.tick()
ok("(b) потолок ботов: только бот = без побудки, state идёт дальше", len(nc) == n0 and w.STATE.read_text() == str(top + 3))
# trigger and his answer in the same walk: nothing to wait for (Codex r1)
w.bot_wakes_path().write_text(""); w.WAKES.write_text(""); w.save_pending([])
top = max(st)
st[top + 1] = raw_msg(top + 1, 700001, "@team_agent_bot быстро")
st[top + 2] = raw_msg(top + 2, w.BOT_ID, "уже", reply_to=top + 1)
n0 = len(nc); w.tick()
ok("(c) обращение и ответ в одном проходе: побудка есть, ожидания нет", len(nc) == n0 + 1 and not w.load_pending())
w._usernames[PEER] = "peer_helper_bot"; w._usernames_at = REAL_TIME()
# bots cannot reply_to each other: his tag of Daria (or the message number) after her call is an answer
for ans_text, label in (("@peer_helper_bot бот-помощник, готово", "тег бота-помощника"), ("отвечаю на {id}: готово", "номер сообщения")):
    w.save_pending([]); w.bot_wakes_path().write_text("")
    top = max(st)
    st[top + 1] = raw_msg(top + 1, J, "@team_agent_bot проверь")
    st[top + 2] = raw_msg(top + 2, 700001, "@anna_member реплика человека", reply_to=top - 1)
    w.tick()
    pend = w.load_pending(); pend[0]["woke_at"] -= w.NUDGE_AFTER_SEC + 1; w.save_pending(pend)
    st[top + 3] = raw_msg(top + 3, w.BOT_ID, ans_text.format(id=top + 1), reply_to=top + 2)
    n0 = len(nc); w.tick()
    ok(f"(c) ответ боту-помощнику без reply_to ({label}) = ответ, повтора нет", len(nc) == n0 and not w.load_pending())
w.save_pending([])
top = max(st)
st[top + 1] = raw_msg(top + 1, 700001, "@team_agent_bot вопрос 1")
w.tick()
pend = w.load_pending(); pend[0]["woke_at"] -= w.NUDGE_AFTER_SEC + 1; w.save_pending(pend)
st[top + 2] = raw_msg(top + 2, w.BOT_ID, "@peer_helper_bot это другой ответ", reply_to=top - 3)
n0 = len(nc); w.tick()
ok("(c) его реплай с тегом бота-помощника не закрывает обращение человека", len(nc) == n0 + 1 and "СРОЧНО" in nc[-1][1])
# Daria's lines tell him to answer by tag, not reply_to (Codex r3)
dm = w.parse(990, raw_msg(990, J, "@team_agent_bot проверь"))
hm = w.parse(991, raw_msg(991, 700001, "@team_agent_bot вопрос"))
rt = w.render([(dm, None), (hm, None)])
w._usernames[PEER] = "peer_helper_bot"
ok("побудка: у строки бота-помощника «без reply_to, с @peer_helper_bot и номером», у человека нет",
   "без reply_to, с @peer_helper_bot и номером 990" in rt and rt.count("@peer_helper_bot") == 1)
rn = w.render_nudge([{"id": 990, "name": "бот-помощник", "uid": J, "text": "x"}, {"id": 991, "name": "С", "uid": 700001, "text": "y"}])
ok("повтор: та же подсказка для бота-помощника", "без reply_to, с @peer_helper_bot и номером 990" in rn and "номером 991" not in rn)
# the bot quota is spent only by a delivered wake: a failed send is retried, not lost (Codex r2)
w.save_pending([]); w.WAKES.write_text("")
w.bot_wakes_path().write_text(" ".join(str(int(time.time())) for _ in range(w.MAX_BOT_WAKES_PER_HOUR - 1)))
top = max(st)
st[top + 1] = raw_msg(top + 1, J, "@team_agent_bot шестая")
w.remote = lambda args, data=b"", timeout=120: (_ for _ in ()).throw(RuntimeError("helper down"))
ok("(b) шестая побудка от бота упала: ошибка, state стоит", raises(w.tick) and w.STATE.read_text() == str(top))
w.remote = lambda args, data=b"", timeout=120: nc.append((args, data)) or "woken"
n0 = len(nc); w.tick()
ok("(b) #1743r3: упавшая отправка уже потратила квоту, вызов удержан (не выброшен), state стоит", len(nc) == n0
   and w.STATE.read_text() == str(top) and top + 1 in w.load_bot_inflight())
w.bot_wakes_path().write_text(" ".join(str(int(time.time())) for _ in range(w.MAX_BOT_WAKES_PER_HOUR - 1)))
w.tick()
ok("(b) квота освободилась: доставлено", len(nc) == n0 + 1 and w.STATE.read_text() == str(top + 1)
   and len(w.recent_wakes(time.time(), w.bot_wakes_path())) == w.MAX_BOT_WAKES_PER_HOUR)
w.bot_wakes_path().write_text(""); w.save_pending([])
# repeats of Daria's calls obey the bot cap (Codex r1)
top = max(st)
st[top + 1] = raw_msg(top + 1, J, "@team_agent_bot бот-вопрос")
w.tick()
pend = w.load_pending(); pend[0]["woke_at"] -= w.NUDGE_AFTER_SEC + 1; w.save_pending(pend)
w.bot_wakes_path().write_text(" ".join(str(int(time.time())) for _ in range(w.MAX_BOT_WAKES_PER_HOUR)))
n0 = len(nc); w.tick()
ok("(b)(c) повтор по тегу бота при исчерпанном потолке ботов не шлём", len(nc) == n0 and not w.load_pending())
w.bot_wakes_path().write_text("")
# wake loop does not wait forever for the feed thread busy with the same file (Codex r1)
w.deliver_media = real_deliver
held = w._lock_for(901); held.acquire()
w.WAKE_MEDIA_WAIT_SEC = 0.2
t0 = REAL_TIME(); vm = w.parse(901, raw_msg(901, 1, media="voice")); w.deliver_media(vm)
ok("побудка ждёт занятое лентой медиа ограниченно и уходит на повтор", REAL_TIME() - t0 < 1 and vm.media_failed)
held.release()
# feed thread and wake loop never fetch the same file twice at once
w.deliver_media = real_deliver
w.STAGING = tmp3 / "media"
gets = []
def slow_media(url, timeout=30):
    gets.append(url); REAL_SLEEP(0.3)
    f = w.STAGING / "tg_media_x_900.oga"; f.write_bytes(b"OGG")
    return {"data": json.dumps({"success": True, "path": str(f)})}
w._get = slow_media
w.remote = lambda args, data=b"", timeout=120: "/home/neurootdel/x/m900_voice.oga" if args[0] == "put" else "текст"
a = w.parse(900, raw_msg(900, 1, media="voice")); b_ = w.parse(900, raw_msg(900, 1, media="voice"))
th = _thr.Thread(target=w.deliver_media, args=(a,)); th.start(); REAL_SLEEP(0.05)
w.deliver_media(b_, REAL_TIME() + 60); th.join()
ok("одно и то же медиа из двух потоков скачано один раз", len(gets) == 1 and any("текст" in x for x in b_.attachments))
w._get = real_get


# --- second group via GW_* env: its own config, chip token, local helper call ---
import os as _os, subprocess as _sp, threading as _th2
ok("конфиг: группа, заголовок, чип и бот из env", w.CHAT_ID == -5550001 and w.wake_args() == ["wake"]
   and w.FEED_ENABLED and w.GROUP_TITLE == "Тестовая группа" and w.CHIP == "http://127.0.0.1:9"
   and w.BOT_ID == 900001 and w.BOT_TAG == "@team_agent_bot" and w.PEER_BOT_IDS == {900002}
   and w.IGNORE_IDS == {900001, 900003, 900004} and w.config_errors() == [])
ok("конфиг: без токена чипа = без заголовка", w.chip_headers() == {})
ok("конфиг: агент по умолчанию = главный из guard.conf, помощник рядом", w.AGENT == "jarvis"
   and w.HELPER == str(REPO / "lib" / "group-wake.sh"))
g2 = Path(tempfile.mkdtemp())
(g2 / "chip.env").write_text('TELEGRAM_API_ID=1\nCHIP_API_TOKEN="tok123"\n')
w2 = load("w2", {"GW_CHAT_ID": "-5550002", "GW_TITLE": "Вторая группа", "GW_CHIP": "http://127.0.0.1:8",
                 "GW_CHIP_ENV_FILE": str(g2 / "chip.env"), "GW_BASE": str(g2 / "base"), "GW_STAGING": str(g2 / "stg"),
                 "GW_FEED": "0", "GW_MEDIA_PREFIX": "g2_", "GW_AGENT": "coder"},
          drop=("GW_NAME_REGEX", "GW_WHISPER_URL"))
ok("вторая группа читает свой конфиг", w2.CHAT_ID == -5550002 and w2.CHIP.endswith(":8")
   and w2.BASE == g2 / "base" and w2.STATE == g2 / "base" / "last_id" and not w2.FEED_ENABLED and w2.AGENT == "coder"
   and not w2.NAME_TRIGGER and not w2.ALL_HUMAN and w2.WHISPER_URL == "")
ok("по умолчанию префикс медиа по группе, лента выкл", load("w2d", drop=("GW_FEED",)).MEDIA_PREFIX == "g5550001_"
   and not load("w2e", drop=("GW_FEED",)).FEED_ENABLED)
_bad = load("w2b", {"GW_CHAT_ID": "", "GW_BOT_ID": "x", "GW_CHIP": "https://e", "GW_AGENT": "Bad Name"})
ok("плохой конфиг: названы все ошибки", len(_bad.config_errors()) == 4)
ok("токен чипа в заголовке", w2.chip_headers() == {"x-chip-token": "tok123"})
(g2 / "chip2.env").write_text("TELEGRAM_API_ID=1\n"); w2._chip_token = None; w2.CHIP_ENV_FILE = str(g2 / "chip2.env")
ok("нет токена = ошибка, а не запрос без него", raises(w2.chip_headers))
w2.CHIP_ENV_FILE = str(g2 / "chip.env"); w2._chip_token = None
m2 = w2.parse(24, raw_msg(24, 111, "@team_agent_bot какие скиллы?"))
txt = w2.render([(m2, None)])
ok("текст побудки с названием и chat_id второй группы", "«Вторая группа» (chat_id -5550002)" in txt
   and "Тестовая группа" not in txt)
ok("повтор СРОЧНО с названием второй группы", "«Вторая группа»" in w2.render_nudge(
   [{"id": 24, "name": "В", "uid": 111, "text": "x", "user": None}]))
ok("имя медиа с префиксом группы", w2.media_name(w2.parse(25, raw_msg(25, 1, media="voice")), Path("a.oga")) == "g2_m25_voice.oga")
calls = []
class _R: returncode = 0; stdout = b"woken"; stderr = b""
_real_run = w2.subprocess.run
w2.subprocess.run = lambda cmd, **k: calls.append(cmd) or _R()
w2.remote(["wake"], "x"); w2.remote(["put", "a.oga"], b"x")
w2.subprocess.run = _real_run
ok("помощник локальный: команда, агент, группа, аргументы", calls == [[w2.HELPER, "wake", "coder", "-5550002"],
   [w2.HELPER, "put", "coder", "-5550002", "a.oga"]])
started = []
w2.BASE.mkdir(parents=True); (w2.BASE / "STOP").touch()
_real_thread = w2.threading.Thread
w2.threading.Thread = lambda *a, **k: started.append(k) or _real_thread(target=lambda: None)
(w2.BASE / "pending.json").write_text("[]"); (w2.BASE / "pending.json").chmod(0o644); w2.BASE.chmod(0o755)
_um = os.umask(0o022)
w2.main()
os.umask(_um)
ok("состояние приватно: каталог 0700, старые файлы 0600", (w2.BASE.stat().st_mode & 0o777) == 0o700
   and ((w2.BASE / "pending.json").stat().st_mode & 0o777) == 0o600 and ((w2.BASE / "lock").stat().st_mode & 0o077) == 0)
w2.threading.Thread = _real_thread
ok("лента выключена = поток ленты не стартует", started == [])
_badrun = _sp.run([sys.executable, WATCH], env={**_os.environ, "NEUROOTDEL_GUARD_CONF": str(_T0 / "x"), "GW_CHAT_ID": ""},
                  capture_output=True, timeout=30)
ok("без GW_CHAT_ID сторож не стартует (код 2)", _badrun.returncode == 2 and b"GW_CHAT_ID" in _badrun.stderr)
# staged file: pinned staging fd, no links, no FIFO hang (root on the server, Codex #1734)
w.STAGING = g2 / "rs"
dfd = w.open_staging()
sd = w.STAGING
ok("1734: staging создан 0700 своим владельцем", (sd.stat().st_mode & 0o777) == 0o700 and sd.stat().st_uid == w.STAGING_UID)
(sd / "a.oga").write_bytes(b"OGG")
ok("1734: обычный файл читается через закреплённый каталог", w.read_staged(dfd, "a.oga") == b"OGG")
(g2 / "secret").write_bytes(b"S"); (sd / "l.oga").symlink_to(g2 / "secret")
try:
    w.read_staged(dfd, "l.oga"); ok("1734: симлинк отвергнут", False)
except OSError:
    ok("1734: симлинк отвергнут", True)
_os.link(g2 / "secret", sd / "h.oga")
ok("1734: жёсткая ссылка отвергнута", raises(lambda: w.read_staged(dfd, "h.oga")))
_os.mkfifo(sd / "f.oga")
t0 = REAL_TIME()
ok("1734: FIFO отвергнут без зависания", raises(lambda: w.read_staged(dfd, "f.oga")) and REAL_TIME() - t0 < 2)
w.STAGING_UID, _uid = w.STAGING_UID + 1, w.STAGING_UID
ok("1734: файл чужого владельца отвергнут", raises(lambda: w.read_staged(dfd, "a.oga")))
w.STAGING_UID = _uid
# the dir is swapped for a symlink after pinning: reads still go to the pinned dir only
(g2 / "evil").mkdir(); (g2 / "evil" / "x.oga").write_bytes(b"EVIL")
_os.rename(sd, g2 / "rs-old"); (g2 / "rs").symlink_to(g2 / "evil")
try:
    w.read_staged(dfd, "x.oga"); ok("1734: подмена каталога после закрепления не читается", False)
except OSError:
    ok("1734: подмена каталога после закрепления не читается", True)
_os.close(dfd)
ok("1734: симлинк вместо staging отвергнут", raises_any(w.open_staging))
(g2 / "rs").unlink(); (g2 / "rs").mkdir(mode=0o755)
ok("1734: staging с чужими правами отвергнут", raises(w.open_staging))
ok("1734: путь вне staging отвергнут", raises(lambda: w.staged_name(Path("/etc/passwd")))
   and raises(lambda: w.staged_name(g2 / "rs" / "sub" / "a")) and raises(lambda: w.staged_name(g2 / "rs" / "..")))
ok("1734: прямой ребёнок staging принят", w.staged_name(g2 / "rs" / "a.oga") == "a.oga")
# --- helper group-wake.sh end to end (as the current user, fake webhook) ---
import http.server as _hs, socketserver as _ss, threading as _hth
_hk = Path(tempfile.mkdtemp())
_got = []
class _Hook(_hs.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        _got.append((self.path, self.headers.get("Authorization"), json.loads(body)))
        code = 500 if b"FAIL500" in body else 200
        out = b"echo tokSECRET42" if code == 500 else b"{}"
        self.send_response(code); self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)
    def log_message(self, *a): pass
_hsrv = _ss.TCPServer(("127.0.0.1", 0), _Hook); _hth.Thread(target=_hsrv.serve_forever, daemon=True).start()
(_hk / "etc" / "jarvis").mkdir(parents=True)
(_hk / "etc" / "jarvis" / "channel.env").write_text(
    f"TELEGRAM_WEBHOOK_PORT={_hsrv.server_address[1]}\nTELEGRAM_WEBHOOK_TOKEN=tokSECRET42\n"
    f"TELEGRAM_ALLOWED_CHAT_IDS=700001,-5550001\nTELEGRAM_STATE_DIR={_hk}/state\n")
(_hk / "guard.conf").write_text(f'AGENT_USER="nobodyx"\nAGENT_HOME="{_hk}/home"\nCONFIG_ROOT="{_hk}/etc"\n')
_henv = {**_os.environ, "NEUROOTDEL_GUARD_CONF": str(_hk / "guard.conf"), "GW_RUN_AS_SELF": "1"}
def helper(*args, data=b""):
    return _sp.run(["bash", HELPER, *args], input=data, capture_output=True, env=_henv, timeout=60)
for bad in ("-100999", "abc", "-5550001 x", "*", "-5550002"):
    r = helper("wake", "jarvis", bad, data=b"x")
    ok(f"помощник отверг чат {bad!r}", r.returncode == 64 and b"chat not allowed" in r.stderr and not _got)
r = helper("wake", "../etc", "-5550001", data=b"x")
ok("помощник отверг имя агента", r.returncode == 64 and b"bad agent" in r.stderr)
r = helper("wake", "coder", "-5550001", data=b"x")
ok("нет channel.env агента = отказ", r.returncode == 3)
r = helper("wake", "jarvis", "-5550001", data="привет группе".encode())
ok("wake: POST /hooks/agent с Bearer и chatId группы", r.returncode == 0 and _got == [("/hooks/agent", "Bearer tokSECRET42",
   {"message": "привет группе", "chatId": "-5550001"})])
ok("wake: токен не напечатан", b"tokSECRET42" not in r.stdout + r.stderr)
r = helper("wake", "jarvis", "-5550001", data=b"FAIL500")
ok("wake: ошибка вебхука, токен в ответе скрыт", r.returncode == 5 and b"<redacted>" in r.stderr and b"tokSECRET42" not in r.stderr)
r = helper("put", "jarvis", "-5550001", "g1_m5_voice.oga", data=b"OGG")
_mp = _hk / "state" / "group-media" / "g1_m5_voice.oga"
ok("put: файл в group-media агента, путь напечатан", r.returncode == 0 and r.stdout.decode().strip() == str(_mp)
   and _mp.read_bytes() == b"OGG")
ok("put: плохое имя отвергнуто", helper("put", "jarvis", "-5550001", "../x", data=b"x").returncode == 64)
_henv.pop("GW_WHISPER_URL", None)
ok("transcribe: без адреса распознавания = отказ", helper("transcribe", "jarvis", "-5550001", "g1_m5_voice.oga").returncode == 3)
r = helper("feed-last", "jarvis", "-5550001")
ok("feed-last до старта = none", r.returncode == 0 and r.stdout.decode().strip() == "none")
r = helper("feed-init", "jarvis", "-5550001", data=w.feed_payload(["[10] старт"]))
r2_ = helper("feed-append", "jarvis", "-5550001", data=w.feed_payload(["[10] старт", "[11] новое"]))
_fp = _hk / "home" / ".claude-lab" / "jarvis" / ".claude" / "state" / "group-5550001" / "feed.md"
ok("feed: лента в state/group-<id> агента, без дублей", r.returncode == 0 and r2_.returncode == 0
   and _fp.read_text() == "[10] старт\n[11] новое\n" and helper("feed-last", "jarvis", "-5550001").stdout.strip() == b"11")
_hsrv.shutdown()

long_txt = "а" * 4000 + "КОНЕЦ"
_lm = w.Msg(id=9, sender_name="Ира", sender_id=1, text=long_txt, reply_to=None, media=None, media_size=None,
            file_name=None, service=False, date="")
ok("2310: длинный текст в побудке целиком", long_txt in w._line(_lm, "") and long_txt in w.render([(_lm, None)])
   and w.render_chunks([(_lm, None)]) == [w.render([(_lm, None)])])
ok("нет обрезки 1500 в побудке", not hasattr(w, "WAKE_CUTS") and "[обрезано" not in w.render([(_lm, None)]))
_big = [(w.Msg(id=i, sender_name="В", sender_id=1, text="я" * 4096 + f" КОНЕЦ-{i}.", reply_to=None, media=None,
               media_size=None, file_name=None, service=False, date=""), _lm) for i in range(20)]
_parts = w.split_items(_big)
_txts = [t for pt in _parts for t in w.render_chunks(pt)]
ok("2310: 20 длинных с родителями: несколько побудок, каждая в лимите, все целиком и по порядку",
   len(_parts) >= 2 and all(w._u16(t) <= w.WAKE_MAX_CHARS for t in _txts) and "[обрезано" not in "".join(_txts)
   and [i for t in _txts for i in range(20) if f"КОНЕЦ-{i}." in t] == list(range(20)))

def _pieces_ok(chunks, needles):
    joined = "".join(c.split("\n", 1)[1] for c in chunks)
    return (len(chunks) >= 2 and all(w._u16(c) <= w.WAKE_MAX_CHARS for c in chunks)
            and all(f"кусок {k} из {len(chunks)}" in c for k, c in enumerate(chunks, 1)) and all(n in joined for n in needles))
_att = w.Msg(id=5, sender_name="В", sender_id=1, text="x", reply_to=None, media=None, media_size=None,
             file_name=None, service=False, date="")
_att.attachments = ["расшифровка: " + "ю" * 3000 + f" ХВ{k}." for k in range(40)]
_ca = w.render_chunks([(_att, None)])
ok("одно огромное сообщение: кусками по порядку, ничего не отрезано", _pieces_ok(_ca, [f" ХВ{k}." for k in range(40)])
   and "".join(c.split("\n", 1)[1] for c in _ca) == w.render([(_att, None)]) and "message_id 5 " in _ca[0])

_emo = w.Msg(id=6, sender_name="В", sender_id=1, text="😀" * 40000 + "КОНЕЦ", reply_to=None, media=None, media_size=None,
             file_name=None, service=False, date="")
_ce = w.render_chunks([(_emo, None)])
ok("2310: эмодзи считаются как в вебхуке (UTF-16): куски в лимите, текст целиком",
   _pieces_ok(_ce, ["КОНЕЦ"]) and "".join(c.split("\n", 1)[1] for c in _ce).count("😀") == 40000)
_calls_c = []
_tmpc = Path(tempfile.mkdtemp()); _bk = (w.BASE, w.STATE, w.WAKES, w.fetch_recent, w.fetch_one, w.remote, w.deliver_media)
w.BASE = _tmpc; w.STATE = _tmpc / "last_id"; w.WAKES = _tmpc / "wakes"
_cst = {1: raw_msg(1, 700001, "старт"), 2: raw_msg(2, 700001, "@team_agent_bot " + "щ" * 70000 + " ХВОСТ")}
w.fetch_recent = lambda timeout=30: (max(_cst), {}); w.fetch_one = lambda mid, timeout=30: w.parse(mid, _cst[mid]) if mid in _cst else None
w.remote = lambda args, data=b"", timeout=120: _calls_c.append(data) or "woken"; w.deliver_media = lambda m, deadline=None: None
w.save_state(1); w.tick()
ok("тик: сообщение больше лимита уходит кусками, хвост дошёл, state сдвинут", len(_calls_c) >= 2 and "ХВОСТ" in _calls_c[-1]
   and all(w._u16(c) <= w.WAKE_MAX_CHARS for c in _calls_c) and w.STATE.read_text() == "2")
# a bot's oversized message: every piece is one webhook call and counts against the bot cap
_calls_c.clear(); w._usernames.clear(); w._members.clear()
w.bot_wakes_path().write_text(" ".join(str(int(time.time())) for _ in range(w.MAX_BOT_WAKES_PER_HOUR - 1)))
_cst[3] = raw_msg(3, PEER, "@team_agent_bot " + "щ" * 130000 + " БОТХВОСТ")
w.tick()
ok("бот-кусками: места в квоте меньше, чем кусков = не шлём (бот пропущен с пометкой)", not _calls_c
   and w.STATE.read_text() == "3" and 3 in w._load_deferred().get("bot_dropped", []))
w.clear_deferred(); w.bot_wakes_path().write_text("")
_cst[4] = raw_msg(4, PEER, "@team_agent_bot " + "щ" * 130000 + " БОТХВОСТ")
w.tick()
ok("бот-кусками: пустая квота пропускает, каждый кусок записан в квоту", len(_calls_c) >= 3 and "БОТХВОСТ" in _calls_c[-1]
   and len(w.recent_wakes(time.time(), w.bot_wakes_path())) == len(_calls_c))
ok("bot_cap_full: один вызов при свободном месте, сразу много только с пустой квотой",
   not w.bot_cap_full(time.time() + 7200, 99) and not w.bot_cap_full(time.time(), w.MAX_BOT_WAKES_PER_HOUR - len(_calls_c))
   and w.bot_cap_full(time.time(), w.MAX_BOT_WAKES_PER_HOUR - len(_calls_c) + 1))
w.bot_wakes_path().write_text("")
w.BASE, w.STATE, w.WAKES, w.fetch_recent, w.fetch_one, w.remote, w.deliver_media = _bk

# ===================== #1740: no silent loss or distortion anywhere in the delivery chain =====================
def rawx(mid, sender=111, text="t", kind=None, **raw_extra):
    raw = {"_": "Message", "from_id": {"_": "PeerUser", "user_id": sender}}
    top = {k[4:]: raw_extra.pop(k) for k in list(raw_extra) if k.startswith("top_")}
    raw.update(raw_extra)
    return json.dumps({"id": mid, "sender": f"S{sender}", "text": text, "media_kind": kind, "raw": raw, **top})
M0 = lambda **k: w.Msg(**{"id": 1, "sender_name": "В", "sender_id": 1, "text": "", "reply_to": None, "media": None,
                          "media_size": None, "file_name": None, "service": False, "date": "", **k})

# 1740-1 transcript longer than 3000: marked, never silently cut
w._get = chip_ok; w.STAGING.chmod(0o700)
w.remote = lambda args, data=b"", timeout=120: "/x/m40_voice.oga" if args[0] == "put" else "с" * 5000 + "ХВОСТ"
_v = w.parse(40, raw_msg(40, 1, media="voice")); w._media_done.pop((40, ""), None)
w.deliver_media(_v)
ok("1740-1: длинная расшифровка помечена, сколько всего", any("[расшифровка обрезана, всего 5005 знаков" in a for a in _v.attachments))

# 1740-2 pending/nudge text over 300: marked
_items_saved = w.load_pending()
w.save_pending([])
w.add_pending([M0(id=41, text="ж" * 400 + "КОНЕЦ")], 0.0, [])
_p = [p for p in w.load_pending() if p["id"] == 41][0]
ok("1740-2/#1743: ожидание хранит текст целиком, повтор несёт его целиком", len(_p["text"]) == 405 and "КОНЕЦ" in w.render_nudge([_p]))
w.save_pending(_items_saved)

# 1740-3 forwarded: who and from where is visible (false alarm #1736)
_f = w.parse(42, rawx(42, 700006, "пост про клинику", fwd_from={"_": "MessageFwdHeader", "date": "2026-10-28T20:00:00+00:00",
                                                                   "from_id": {"_": "PeerUser", "user_id": 900002}}))
_fl = w._line(_f, "")
ok("1740-3: пересылка видна в побудке и от кого", "переслано" in _fl and "900002" in _fl and "бот " in _fl)
_f2 = w.parse(43, rawx(43, 1, "x", fwd_from={"_": "MessageFwdHeader", "date": "2026-10-28T20:00:00+00:00", "from_name": "Иван | Reels"}))
ok("1740-3: скрытый автор пересылки по имени", "Иван | Reels" in w._line(_f2, ""))
_f3 = w.parse(44, rawx(44, 1, "x", fwd_from={"_": "MessageFwdHeader", "date": "2026-10-28T20:00:00+00:00",
                                             "from_id": {"_": "PeerChannel", "channel_id": 12345}, "post_author": "Ира"}))
ok("1740-3: пересылка из канала", "канал" in w._line(_f3, "") and "12345" in w._line(_f3, ""))
ok("1740-3: пересылка видна в ленте", "переслано" in w.feed_entry(_f, time.time() + 60, {}))

# 1740-4 media that is never downloaded still shows up (poll/geo/contact) + document keeps its real name
_poll = w.parse(45, rawx(45, 1, "", kind="poll", top_poll={"question": "Куда идём?", "answers": [{"text": "Кино"}, {"text": "Парк"}]}))
ok("1740-4: опрос в побудке с вопросом и вариантами", all(s in w._line(_poll, "") for s in ("Куда идём?", "Кино", "Парк")))
_geo = w.parse(46, rawx(46, 1, "", kind="geo", media={"_": "MessageMediaGeo", "geo": {"_": "GeoPoint", "lat": 55.75, "long": 37.61}}))
ok("1740-4: геолокация с координатами", "55.75" in w._line(_geo, "") and "37.61" in w._line(_geo, ""))
_ph = M0(id=47, text="", media="photo")
ok("1740-4: нескачанное фото (контекст) видно меткой, а не [без текста]", "[фото]" in w._line(_ph, "") and "без текста" not in w._line(_ph, ""))
w._get = chip_ok
w.remote = lambda args, data=b"", timeout=120: "/x/m48_document.pdf"
_doc = w.parse(48, raw_msg(48, 1, "", media="document", size=10, fname="Договор Ивановой.pdf")); w._media_done.pop((48, ""), None)
w.deliver_media(_doc)
ok("1740-4: у файла в побудке настоящее имя", "Договор Ивановой.pdf" in w._line(_doc, ""))

# 1740-5 hidden links (MessageEntityTextUrl) and quotes: the url is not lost; offsets are UTF-16 like Telegram's
_hl = w.parse(49, rawx(49, 1, "😀 жми сюда", entities=[{"_": "MessageEntityTextUrl", "offset": 3, "length": 3, "url": "https://ex.am/p"}]))
ok("1740-5: скрытая ссылка видна с текстом (смещение UTF-16)", "«жми»" in w._line(_hl, "") and "https://ex.am/p" in w._line(_hl, ""))
ok("1740-5: скрытая ссылка видна в ленте", "https://ex.am/p" in w.feed_entry(_hl, time.time() + 60, {}))
_q = w.parse(50, rawx(50, 1, "да", reply_to={"_": "MessageReplyHeader", "reply_to_msg_id": 3, "quote_text": "кусок, который цитируют"}))
ok("1740-5: цитата ответа видна", "кусок, который цитируют" in w._line(_q, ""))

# 1740-6 replies: reply into another chat is not fetched from this one; deleted parent is said; one level up shown
_x = w.parse(51, rawx(51, 1, "@team_agent_bot", reply_to={"_": "MessageReplyHeader", "reply_to_msg_id": 3,
                                                             "reply_to_peer_id": {"_": "PeerChannel", "channel_id": 999}}))
ok("1740-6: ответ на сообщение другого чата помечен", _x.reply_elsewhere and "другого чата" in w._line(_x, ""))
_gp = M0(id=60, text="самый первый вопрос")
_par = M0(id=61, text="ответ на него", reply_to=60, sender_id=w.BOT_ID); _par.up = _gp
_ch = M0(id=62, text="а подробнее?", reply_to=61)
_rr = w.render([(_ch, _par)])
ok("1740-6: реплай на реплай: виден контекст уровнем выше", "самый первый вопрос" in _rr)
ok("1740-6: удалённый родитель назван", "удалено" in w.render([(M0(id=63, text="@team_agent_bot", reply_to=5), None)]))

# 1740-7 service messages say what happened
_svc = w.parse(64, json.dumps({"id": 64, "sender": "x", "text": "", "media_kind": None, "raw": {"_": "MessageService",
        "from_id": {"_": "PeerUser", "user_id": 5}, "action": {"_": "MessageActionChatAddUser", "users": [777]}}}))
ok("1740-7: служебное в ленте с действием", "ChatAddUser" in w.feed_entry(_svc, time.time() + 60, {}) and "777" in w.feed_entry(_svc, time.time() + 60, {}))

# 1740-8 chip misflags a message as an error when "Error" is in the first 50 chars (sender name): not a stuck walk
_body = json.dumps({"id": 70, "sender": "ErrorMan", "text": "@team_agent_bot", "media_kind": None,
                    "raw": {"_": "Message", "from_id": {"_": "PeerUser", "user_id": 5}}})
class _Conn:
    pass
w._get = real_get
_real_fetch = w._fetch
w._fetch = lambda conn, path: json.dumps({"success": False, "error": _body}).encode()
_orig_conn = w.http.client.HTTPConnection
class _FakeConn:
    def __init__(self, *a, **k): self.sock = None
    def connect(self): pass
    def close(self): pass
w.http.client.HTTPConnection = _FakeConn
try:
    _got = REAL_FETCH_ONE(70)
    ok("1740-8: чип пометил сообщение «Error» ошибкой: сообщение всё равно прочитано", _got is not None and _got.id == 70)
except Exception as e:
    ok(f"1740-8: чип пометил сообщение «Error» ошибкой: сообщение всё равно прочитано ({e})", False)
w._fetch = lambda conn, path: json.dumps({"success": False, "error": "ID: 71 | ErrorMan | Date: x | Message: hi"}).encode()
try:
    ok("1740-8: то же для списка (верх ленты)", REAL_FETCH_TOP() == 71)
except Exception:
    ok("1740-8: то же для списка (верх ленты)", False)
w._fetch = lambda conn, path: json.dumps({"success": False, "error": "An error occurred (code: X)"}).encode()
ok("1740-8: настоящая ошибка чипа остаётся ошибкой", raises(lambda: REAL_FETCH_ONE(72)))
w._fetch = _real_fetch; w.http.client.HTTPConnection = _orig_conn

# 1740-9 a lone surrogate in a text must not jam the walk forever (encode error before the helper)
_sent = []
class _R2: returncode = 0; stdout = b"ok"; stderr = b""
_real_run = w.subprocess.run
w.subprocess.run = lambda cmd, **k: _sent.append(k.get("input")) or _R2()
try:
    REAL_REMOTE(["wake"], "битый \ud83d символ")
    ok("1740-9: одиночный суррогат не роняет отправку", bool(_sent) and "битый".encode() in _sent[0])
except UnicodeEncodeError:
    ok("1740-9: одиночный суррогат не роняет отправку", False)
w.subprocess.run = _real_run
try:
    w.feed_payload(["[1] битый \ud83d"]); ok("1740-9: и в ленте", True)
except UnicodeEncodeError:
    ok("1740-9: и в ленте", False)

# 1740-10 album: tag in the caption of one part -> every part of the album reaches him
tmpA = Path(tempfile.mkdtemp())
w.BASE = tmpA; w.STATE = tmpA / "last_id"; w.WAKES = tmpA / "wakes"
astore = {}
def rec(listing_ids=None):
    ids = sorted(astore, reverse=True)[:20]
    return max(astore), {i: w.text_hash(json.loads(astore[i])["text"]) for i in ids}
w.fetch_recent = lambda timeout=30: rec()
w.fetch_one = lambda mid, timeout=30: w.parse(mid, astore[mid]) if mid in astore else None
calls = []
w.remote = fake_remote
_delivered = []
w.deliver_media = lambda m, deadline=None: _delivered.append(m.id) or m.attachments.append(f"{m.media}: /x/m{m.id}")
astore[100] = rawx(100, 222, "до альбома")
w.save_state(100)
astore[101] = rawx(101, 222, "", kind="photo", grouped_id=555)
astore[102] = rawx(102, 222, "@team_agent_bot смотри все три", kind="photo", grouped_id=555)
astore[103] = rawx(103, 222, "", kind="photo", grouped_id=555)
astore[104] = rawx(104, 222, "после альбома")
w.tick()
ok("1740-10: альбом: все 3 части скачаны и в побудке", sorted(_delivered) == [101, 102, 103] and len(calls) == 1
   and "/x/m101" in calls[0][1] and "/x/m103" in calls[0][1] and "альбом" in calls[0][1])

# 1740-11 edits: tag added by an edit wakes him; a woken message corrected later wakes him with the new text
calls.clear(); w.WAKES.write_text("")
astore[105] = rawx(105, 222, "вопрос без тега")
w.tick()
ok("1740-11: без тега не будим", not calls and w.STATE.read_text() == "105")
astore[105] = rawx(105, 222, "вопрос без тега @team_agent_bot", edit_date="2026-10-28T21:00:00+00:00")
w.tick()
ok("1740-11: тег добавлен правкой = побудка с пометкой", len(calls) == 1 and "правк" in calls[0][1] and "вопрос без тега @team_agent_bot" in calls[0][1])
w.tick()
ok("1740-11: та же правка второй раз не будит", len(calls) == 1)
astore[106] = rawx(106, 222, "@team_agent_bot сделай отчёт за вторник")
w.tick()
ok("1740-11: обычная побудка", len(calls) == 2)
astore[106] = rawx(106, 222, "@team_agent_bot сделай отчёт за СРЕДУ", edit_date="2026-10-28T21:01:00+00:00")
w.tick()
ok("1740-11: исправленный текст после побудки доходит", len(calls) == 3 and "за СРЕДУ" in calls[2][1] and "ИСПРАВЛЕНО" in calls[2][1])
calls.clear()
astore[107] = rawx(107, 222, "просто болтовня")
w.tick()
astore[107] = rawx(107, 222, "просто болтовня, исправил опечатку", edit_date="2026-10-28T21:02:00+00:00")
w.tick()
ok("1740-11: правка обычного сообщения не будит", not calls)

# ---- Codex #1740 r1 ----
# r1-1 lone surrogate: parse cleans it, render and pending survive
_s = w.parse(120, json.dumps({"id": 120, "sender": "Имя \ud83d", "text": "@team_agent_bot битый \ud83d", "media_kind": None,
                             "raw": {"_": "Message", "from_id": {"_": "PeerUser", "user_id": 5}}}))
try:
    w.render([(_s, None)]); w.save_pending([]); w.add_pending([_s], 0.0, []); ok("r1-1: суррогат не роняет render и pending", True)
except UnicodeError:
    ok("r1-1: суррогат не роняет render и pending", False)
w.save_pending([])
# r1-2 a woken message corrected WITHOUT the tag still reaches him
calls.clear(); w.WAKES.write_text("")
astore[108] = rawx(108, 222, "@team_agent_bot переведи 100")
w.tick()
astore[108] = rawx(108, 222, "ОТМЕНА, ничего не переводи", edit_date="x")
w.tick()
ok("r1-2: исправление без тега после побудки доходит", len(calls) == 2 and "ОТМЕНА" in calls[1][1] and "ИСПРАВЛЕНО" in calls[1][1])
# r1-3 detected edit survives a failed wake and the message leaving the listing window
calls.clear(); w.WAKES.write_text("")
astore[109] = rawx(109, 222, "@team_agent_bot сделай А")
w.tick()
astore[109] = rawx(109, 222, "@team_agent_bot сделай Б", edit_date="x")
w.remote = failing
ok("r1-3: побудка по правке упала", raises(w.tick))
w.remote = fake_remote
for i in range(110, 135):
    astore[i] = rawx(i, 222, f"болтовня {i}")
w.tick(); w.tick()
ok("r1-3: правка доставлена после сбоя, хотя ушла из окна 20", any("сделай Б" in c[1] for c in calls))
# r1-5 forged listing line: no wake on an unchanged trigger
calls.clear(); w.WAKES.write_text("")
w.fetch_recent = lambda timeout=30: (lambda t, r: (t, {**r, 109: "forged"}))(*rec())
w.tick()
ok("r1-5: подделанная строка списка не будит на неизменённое", not calls)
w.fetch_recent = lambda timeout=30: rec()
w.tick()
ok("r1-5: и при возврате настоящей строки тоже", not calls)
# real fetch_recent: boundaries and multi-line texts
_lst = "ID: 12 | A | Date: d | Message: строка1\nстрока2\nID: 11 | B | Date: d | reply to 3 | Message: x\nID: 10 | C | Date: d | Message: "
w._get = lambda url, timeout=30: {"success": True, "data": _lst}
_t, _r = REAL_FETCH_RECENT()
ok("r1-5: настоящий fetch_recent режет по строкам ID", _t == 12 and _r[12] == w.text_hash("строка1\nстрока2") and _r[11] == w.text_hash("x") and _r[10] == w.text_hash(""))
w._get = real_get
# r1-4 overflow: every trigger keeps its own line
_many = [(M0(id=200 + i, text="я" * 4000, links=[f"«x» → https://e/{j}" for j in range(40)]), None) for i in range(20)]
for m_, _ in _many:
    m_.attachments = ["расшифровка: " + "ю" * 3000, "фото: /x"]
_rm = [t for pt in w.split_items(_many) for t in w.render_chunks(pt)]
ok("r1-4: переполнение: каждое обращение целиком, каждая побудка в лимите", all(w._u16(t) <= w.WAKE_MAX_CHARS for t in _rm)
   and all(any(f"message_id {200 + i} " in t for t in _rm) for i in range(20)) and "[обрезано" not in "".join(_rm))
# r1-6 replaced file is fetched again after an edit
_c = max(astore) + 1
astore[_c] = rawx(_c, 222, "@team_agent_bot вот фото", kind="photo", media={"_": "MessageMediaPhoto", "photo": {"id": 1}})
w.tick()
w._media_done[(_c, "MessageMediaPhoto:1")] = ["photo: /old"]
astore[_c] = rawx(_c, 222, "@team_agent_bot вот другое фото", kind="photo", media={"_": "MessageMediaPhoto", "photo": {"id": 2}}, edit_date="y")
w.tick()
_new = w.parse(_c, astore[_c])
ok("r1-6/r2-5: кэш по версии файла: новое фото не берёт старый результат", _new.media_key == "MessageMediaPhoto:2"
   and w._media_done.get((_c, _new.media_key)) is None)
# r1-7 album with a deleted middle part
calls.clear(); w.WAKES.write_text(""); _delivered.clear()
w.save_state(max(astore))
b = max(astore)
astore[b + 1] = rawx(b + 1, 222, "@team_agent_bot альбом", kind="photo", grouped_id=777)
astore[b + 3] = rawx(b + 3, 222, "", kind="photo", grouped_id=777)  # b+2 deleted
w.tick()
ok("r1-7: удалённая часть альбома не обрывает поиск", sorted(_delivered) == [b + 1, b + 3])
# r1-8 unexpected raw shapes: the message still parses, with a note
_bad = w.parse(300, rawx(300, 1, "текст", fwd_from={"from_id": "unexpected"}, kind="contact",
                         media={"_": "MessageMediaContact", "first_name": 5, "phone_number": "1"}, entities=[{"_": "MessageEntityTextUrl", "offset": "x"}]))
ok("r1-8: кривые поля raw не роняют разбор", _bad is not None and _bad.text == "текст" and "переслано" in _bad.fwd and "контакт: 5" in _bad.media_note)
ok("r1-8: кривой опрос = пометка", "не прочитано" in w._safe(w._media_note, {"poll": {"answers": 1}}, None, fallback="[содержимое вложения не прочитано]"))
# r1-9 poll only in raw
_rp = w.parse(301, rawx(301, 1, "", kind="poll", media={"_": "MessageMediaPoll", "poll": {"question": {"text": "Вопрос?"}, "answers": [{"text": {"text": "Да"}}]}}))
ok("r1-9: опрос из raw", "Вопрос?" in _rp.media_note and "Да" in _rp.media_note)

# ---- Codex #1740 r2 ----
for _raw in ({"media": "unexpected"}, {"media": {"document": {"attributes": [None]}}}, {"reply_to": "unexpected"}):
    try:
        _pm = w.parse(400, rawx(400, 1, "текст", **_raw)); ok(f"r2-1: кривое {list(_raw)[0]} не роняет разбор", _pm.text == "текст")
    except Exception as e:
        ok(f"r2-1: кривое {list(_raw)[0]} не роняет разбор ({e})", False)
_huge = [(M0(id=500 + i, sender_name="😀" * 300, text="😀" * 4000, fwd="переслано от " + "😀" * 500,
             links=["«😀» → https://e/" + "😀" * 400] * 5), None) for i in range(40)]
for m_, _ in _huge:
    m_.attachments = ["😀" * 3000] * 3
_rh = [t for pt in w.split_items(_huge) for t in w.render_chunks(pt)]
ok("r2-2: 40 огромных обращений: каждое целиком, каждая побудка в лимите", all(w._u16(t) <= w.WAKE_MAX_CHARS for t in _rh)
   and all(any(f"message_id {500 + i} " in t for t in _rh) for i in range(40)))
# r2-3 delivered fix replaces the pending text
calls.clear(); w.WAKES.write_text(""); w.save_pending([])
_d = max(astore) + 1
astore[_d] = rawx(_d, 222, "@team_agent_bot переведи 100")
w.tick()
astore[_d] = rawx(_d, 222, "ОТМЕНА", edit_date="z")
w.tick()
_pp = [p for p in w.load_pending() if p["id"] == _d]
ok("r2-3: повтор СРОЧНО несёт исправленный текст", _pp and _pp[0]["text"] == "ОТМЕНА")
# r2-4 an edit seen in the listing is saved even if reading the new messages fails
calls.clear(); w.WAKES.write_text("")
_e = max(astore) + 1
astore[_e] = rawx(_e, 222, "@team_agent_bot сделай Х")
w.tick()
astore[_e] = rawx(_e, 222, "@team_agent_bot сделай Y", edit_date="z")
astore[_e + 1] = rawx(_e + 1, 222, "новое")
_ok_fetch = w.fetch_one
w.fetch_one = lambda mid, timeout=30: (_ for _ in ()).throw(RuntimeError("chip down")) if mid == _e + 1 else _ok_fetch(mid)
ok("r2-4: чтение нового упало", raises(w.tick))
ok("r2-4: правка уже записана в очередь", w.load_seen()[_e][2] is True)
w.fetch_one = _ok_fetch
w.tick()
ok("r2-4: и доставлена после восстановления", any("сделай Y" in c[1] for c in calls))
# r2-6 seen is written before the state
_order = []
_ss, _sv = w.save_state, w.save_seen
w.save_state = lambda v: _order.append("state") or _ss(v)
w.save_seen = lambda seen, top: _order.append("seen") or _sv(seen, top)
astore[_e + 2] = rawx(_e + 2, 222, "@team_agent_bot ещё")
w.tick()
w.save_state, w.save_seen = _ss, _sv
ok("r2-6: seen пишется раньше state", _order[-2:] == ["seen", "state"])

# ---- Codex #1740 r3 ----
# r3-1 crash between save_seen and save_state, then the trigger is corrected to «ОТМЕНА»
calls.clear(); w.WAKES.write_text("")
_f = max(astore) + 1
astore[_f] = rawx(_f, 222, "@team_agent_bot переведи 200")
_ss = w.save_state
w.save_state = lambda v: (_ for _ in ()).throw(OSError("crash"))
ok("r3-1: падение после seen, до state", raises_any(w.tick))
w.save_state = _ss
astore[_f] = rawx(_f, 222, "ОТМЕНА 200", edit_date="q")
w.tick()
ok("r3-1: отмена после частичного commit доходит", any("ОТМЕНА 200" in c[1] and "ИСПРАВЛЕНО" in c[1] for c in calls))
# r3-2 a delivered album part without its own tag: its correction reaches him
calls.clear(); w.WAKES.write_text(""); _delivered.clear()
_g = max(astore) + 1
astore[_g] = rawx(_g, 222, "@team_agent_bot глянь", kind="photo", grouped_id=888)
astore[_g + 1] = rawx(_g + 1, 222, "подпись А", kind="photo", grouped_id=888)
w.tick()
astore[_g + 1] = rawx(_g + 1, 222, "подпись Б", kind="photo", grouped_id=888, edit_date="q")
w.tick()
ok("r3-2: правка части альбома без тега доходит", len(calls) == 2 and "подпись Б" in calls[1][1])
# r3-3 the context one level up gets its media delivered
calls.clear(); w.WAKES.write_text(""); _delivered.clear()
_h = max(astore) + 1
astore[_h] = rawx(_h, 222, "", kind="voice")
astore[_h + 1] = rawx(_h + 1, w.BOT_ID, "уточни?", reply_to={"_": "MessageReplyHeader", "reply_to_msg_id": _h})
astore[_h + 2] = rawx(_h + 2, 222, "вот так", reply_to={"_": "MessageReplyHeader", "reply_to_msg_id": _h + 1})
w.tick()
ok("r3-3: голос уровнем выше скачан и в побудке", _h in _delivered and f"/x/m{_h}" in calls[-1][1])

# ---- Codex #1740 r4: webhook delivered, crash before seen/state commit, then the tag is removed ----
calls.clear(); w.WAKES.write_text(""); w.save_pending([])
_k = max(astore) + 1
astore[_k] = rawx(_k, 222, "@team_agent_bot переведи 300")
_sv, _ss = w.save_seen, w.save_state
_n = [0]
def _seen_once(seen, top):
    _n[0] += 1
    if _n[0] > 1:
        raise OSError("crash at commit")
    _sv(seen, top)
w.save_seen = _seen_once
ok("r4: побудка ушла, commit упал", raises_any(w.tick) and len(calls) == 1)
w.save_seen, w.save_state = _sv, _ss
astore[_k] = rawx(_k, 222, "ОТМЕНА 300", edit_date="q")
w.tick()
ok("r4: отмена после сбоя commit доходит", any("ОТМЕНА 300" in c[1] for c in calls[1:]))
# a FAILED send of a pending edit keeps it pending (no «nothing changed» after the pre-send mark)
calls.clear(); w.WAKES.write_text("")
_l = max(astore) + 1
astore[_l] = rawx(_l, 222, "просто так")
w.tick()
astore[_l] = rawx(_l, 222, "просто так @team_agent_bot", edit_date="q")
w.remote = failing
ok("r4: отправка правки упала", raises(w.tick))
w.remote = fake_remote
w.tick()
ok("r4: правка доставлена после упавшей отправки", any("просто так @team_agent_bot" in c[1] for c in calls))

# ---- Codex #1740 r5: in-flight send is repeated until committed ----
calls.clear(); w.WAKES.write_text("")
_r = max(astore) + 1
astore[_r] = rawx(_r, 222, "@team_agent_bot переведи 400")
_sv = w.save_seen; _n = [0]
_lim = [1]
def _seen_first_only(seen, top):  # lets the first _lim[0] saves through (detect / mark_inflight), fails the commit
    _n[0] += 1
    if _n[0] > _lim[0]:
        raise OSError("crash at commit")
    _sv(seen, top)
w.save_seen = _seen_first_only
ok("r5-1: доставлено, commit упал", raises_any(w.tick) and len(calls) == 1)
w.save_seen = _sv
astore[_r] = rawx(_r, 222, "ОТМЕНА 400", edit_date="q")
w.remote = failing
ok("r5-1: повторная отправка отмены упала", raises(w.tick))
w.remote = fake_remote
w.tick()
ok("r5-1: отмена всё равно доходит", any("ОТМЕНА 400" in c[1] for c in calls[1:]))
# r5-2: committed A, edit B sent then crash, revert to A -> A is delivered again
calls.clear(); w.WAKES.write_text("")
_q = max(astore) + 1
astore[_q] = rawx(_q, 222, "@team_agent_bot НЕ переводи")
w.tick()
astore[_q] = rawx(_q, 222, "@team_agent_bot переведи 500", edit_date="q")
_n[0] = 0; _lim[0] = 2; w.save_seen = _seen_first_only
_r5 = raises_any(w.tick)
w.save_seen = _sv
astore[_q] = rawx(_q, 222, "@team_agent_bot НЕ переводи", edit_date="r")
w.tick()
ok("r5-2: возврат к старому тексту после неподтверждённой правки доходит", _r5 and len(calls) == 3 and "НЕ переводи" in calls[2][1])
# #1742: bot cap drop is named in the next wake
calls.clear(); w.WAKES.write_text("")
w.bot_wakes_path().write_text(" ".join(str(int(time.time())) for _ in range(w.MAX_BOT_WAKES_PER_HOUR)))
_j = max(astore) + 1
astore[_j] = rawx(_j, PEER, "@team_agent_bot Тимофей, глянь")
w.tick()
ok("#1742: бот-потолок: бота-помощника не будим", not calls)
astore[_j + 1] = rawx(_j + 1, 222, "@team_agent_bot привет")
w.tick()
ok("#1742: в следующей побудке названы пропущенные сообщения бота-помощника", len(calls) == 1 and f"{_j}" in calls[0][1] and "потолком побудок от ботов" in calls[0][1])
w.bot_wakes_path().write_text("")

# ===================== #1743: every human message, whole, in order =====================
ok("ALL_HUMAN по умолчанию выключен", not w.ALL_HUMAN)
_g3 = Path(tempfile.mkdtemp())
w3 = load("w3", {"GW_CHAT_ID": "-5550003", "GW_TITLE": "Третья группа", "GW_ALL_HUMAN": "1", "GW_BASE": str(_g3),
                 "GW_FEED": "0"}, drop=("GW_NAME_REGEX",))
ok("GW_ALL_HUMAN=1 включает режим", w3.ALL_HUMAN)
_w0 = load("w0", {"GW_ALL_HUMAN": "0"})
ok("GW_ALL_HUMAN=0 = выключен", not _w0.ALL_HUMAN)
w3._usernames.update({700005: "member_one", 555: "some_helper_bot"}); w3._usernames_at = REAL_TIME()
w3._members.update({700005, 555, 900001, 900002, 700003, 1}); w3._members_forced_at = REAL_TIME()
P3 = lambda mid, sender, **k: w3.parse(mid, raw_msg(mid, sender, **k))
ok("1743: человек без тега будит", w3.is_trigger(P3(5, 700005, text="просто пост"), None))
w._members.add(700005)
ok("без флага ALL_HUMAN голое сообщение участника-человека не будит", not w.is_trigger(P(5, 700005, text="просто пост"), None))
w._members.discard(700005)
ok("1743: бот-помощник без тега не будит", not w3.is_trigger(P3(5, PEER, text="просто"), None))
ok("1743: бот-помощник с тегом будит", w3.is_trigger(P3(5, PEER, text="@team_agent_bot глянь"), None))
ok("1743: чужой бот (username на bot) без тега не будит", not w3.is_trigger(P3(5, 555, text="x"), None))
ok("1743: Тимофей сам себя не будит", not w3.is_trigger(P3(5, w3.BOT_ID, text="x"), None))
ok("1743: служебное не будит", not w3.is_trigger(P3(5, 700005, text="", service=True), None))
ok("1743: тестовый аккаунт в игноре не будит", not w3.is_trigger(P3(5, 900004, text="x"), None))
# 15 long posts without a tag: all whole, in order, split into parts, state at the end
s3 = {}
w3.fetch_top = lambda timeout=30: max(s3)
w3.fetch_recent = lambda timeout=30: (w3.fetch_top(), {})  # #1740 tick reads top via the listing
w3.fetch_one = lambda mid, timeout=30: w3.parse(mid, s3[mid]) if mid in s3 else None
w3.usernames = lambda: w3._usernames
c3 = []
w3.remote = lambda args, data=b"", timeout=120: c3.append((args, data)) or "woken"
w3.deliver_media = lambda m, deadline=None: None
s3[10] = raw_msg(10, 700005, "старое")
w3.tick()
for n in range(1, 16):
    s3[10 + n] = raw_msg(10 + n, 700005, f"Пост {n} " + "ж" * 4000 + f" КОНЕЦ-{n}")
w3.tick()
_all = "".join(d for _, d in c3)
_pos = [_all.find(f"КОНЕЦ-{n}") for n in range(1, 16)]
ok("1743: все 15 длинных целиком", all(p >= 0 for p in _pos) and "[обрезано" not in _all)
ok("1743: строго по порядку", _pos == sorted(_pos))
ok("1743: несколько частей, каждая в лимите", len(c3) >= 2 and all(w3._u16(d) <= w3.WAKE_MAX_CHARS for _, d in c3)
   and "часть 1 из" in c3[0][1])
ok("1743: state в конце пачки", w3.STATE.read_text() == "25")
ok("1743: посты без обращения не ставят СРОЧНО", w3.load_pending() == [])
# part 2 fails: state stays after part 1, the rest comes next tick, in order
c3.clear()
for n in range(16, 31):
    s3[10 + n] = raw_msg(10 + n, 700005, f"Пост {n} " + "ж" * 4000 + f" КОНЕЦ-{n}")
_cnt = [0]
def _rem3(args, data=b"", timeout=120):
    _cnt[0] += 1
    if _cnt[0] == 2:
        raise RuntimeError("helper down")
    c3.append((args, data)); return "woken"
w3.remote = _rem3
ok("1743: вторая часть упала", raises(w3.tick))
_after1 = int(w3.STATE.read_text())
ok("1743: state сдвинут только за первую часть", 25 < _after1 < 40)
w3.remote = lambda args, data=b"", timeout=120: c3.append((args, data)) or "woken"
w3.tick(); w3.tick()
_all = "".join(d for _, d in c3)
ok("1743: после сбоя дошли все 16-30 по порядку", all(f"КОНЕЦ-{n}" in _all for n in range(16, 31)) and w3.STATE.read_text() == "40")
# the «СРОЧНО» repeat no longer cuts silently (member saw posts 1-8 cut)
_pl = [{"id": i, "name": "С", "uid": 1, "user": None, "text": "ш" * 3000 + f" КОНЕЦ-{i}"} for i in range(12)]
_rn = w3.render_nudge(_pl)
ok("1743: повтор СРОЧНО: 12 длинных целиком", all(f"КОНЕЦ-{i}" in _rn for i in range(12)) and "[обрезано" not in _rn)
_pl = [{"id": i, "name": "С", "uid": 1, "user": None, "text": "ш" * 4000} for i in range(40)]
_rn = w3.render_nudge(_pl)
ok("1743: повтор СРОЧНО: не влезло = пометка, в лимите", w3._u16(_rn) <= w3.WAKE_MAX_CHARS and "[обрезано, всего 4000 знаков" in _rn)
w3.save_pending([]); w3.add_pending([w3.parse(99, raw_msg(99, 1, "я" * 2000))], 0.0, [])
ok("1743: ожидание хранит текст целиком", len(w3.load_pending()[0]["text"]) == 2000)

# ---- Codex #1743 r1 + false «СРОЧНО» on a batch ----
ok("1743r1: не участник (список не знает) будит, но считается под бот-потолком", w3.is_trigger(P3(5, 4242, text="x"), None)
   and w3.bot_like(P3(5, 4242, text="x")))
w3.bot_wakes_path().write_text(" ".join(str(int(REAL_TIME())) for _ in range(w3.MAX_BOT_WAKES_PER_HOUR)))
c3.clear(); _st = int(w3.STATE.read_text())
s3[_st + 1] = raw_msg(_st + 1, 700005, "человек до")
s3[_st + 2] = raw_msg(_st + 2, 4242, "неизвестный")
s3[_st + 3] = raw_msg(_st + 3, 700005, "человек после")
w3.tick()
ok("1743r1: неизвестный при бот-потолке отложен (не выброшен), человек до него доставлен, state перед ним",
   len(c3) == 1 and "человек до" in c3[0][1] and "неизвестный" not in c3[0][1] and w3.STATE.read_text() == str(_st + 1))
w3.bot_wakes_path().write_text("")
w3.tick()
ok("1743r1: после освобождения бот-потолка неизвестный и следующий дошли по порядку",
   len(c3) == 2 and c3[1][1].find("неизвестный") < c3[1][1].find("человек после") and w3.STATE.read_text() == str(_st + 3))
# per-part bot cap: two parts each with Daria's tag, 5 of 6 bot wakes used
w3.bot_wakes_path().write_text(" ".join(str(int(REAL_TIME())) for _ in range(w3.MAX_BOT_WAKES_PER_HOUR - 1)))
c3.clear(); _st = int(w3.STATE.read_text())
for n in range(1, 31):
    sender = PEER if n in (2, 29) else 700005
    s3[_st + n] = raw_msg(_st + n, sender, ("@team_agent_bot " if sender == PEER else "") + f"П{n} " + "ж" * 4000 + f" КОНЕЦ-{n}")
w3.tick(); w3.tick()
_all = "".join(d for _, d in c3)
ok("1743r1: бот-потолок держится на каждой части", len(w3.recent_wakes(REAL_TIME(), w3.bot_wakes_path())) == w3.MAX_BOT_WAKES_PER_HOUR
   and "КОНЕЦ-2" in _all and "КОНЕЦ-29" not in _all and all(f"КОНЕЦ-{n}" in _all for n in range(1, 31) if n != 29))
w3.bot_wakes_path().write_text("")
# false СРОЧНО: wake with 8 tagged posts, he replies to the 8th -> no repeat for any
w3.save_pending([]); c3.clear(); _st = int(w3.STATE.read_text())
for n in range(1, 9):
    s3[_st + n] = raw_msg(_st + n, 700005, f"@team_agent_bot пост {n}")
w3.tick()
s3[_st + 9] = raw_msg(_st + 9, w3.BOT_ID, "ответ на всё", reply_to=_st + 8)
w3.tick()
ok("1743: один реплай Тимофея на 8-й пост снимает ожидание по всей пачке", w3.load_pending() == [])
_real_t = w3.time.time
w3.time.time = lambda: _real_t() + 400
w3.tick()
w3.time.time = _real_t
ok("1743: СРОЧНО по пачке не шлётся", not any("СРОЧНО" in d for _, d in c3))
# nudge never drops whole entries unseen
_pl = [{"id": i, "name": "😀" * 50, "uid": 1, "user": None, "text": "😀" * 3000, "woke_at": 0.0, "tries": 0} for i in range(100)]
w3.save_pending(_pl); c3.clear()
w3.nudge_overdue(1000.0)
_sent_ids = [i for i in range(100) if f"message_id {i} " in c3[0][1]]
_left = [p["id"] for p in w3.load_pending()]
ok("1743r1: повтор: что не влезло, осталось в ожидании, без tries", c3 and w3._u16(c3[0][1]) <= w3.WAKE_MAX_CHARS
   and sorted(_sent_ids + _left) == list(range(100)) and all(p["tries"] == 0 for p in w3.load_pending()))

# ---- Codex #1743 r2 ----
ok("1743r2: бот-участник с тегом считается под бот-потолком", w3.bot_like(P3(5, 555, text="@team_agent_bot x")))
w3.bot_wakes_path().write_text(" ".join(str(int(REAL_TIME())) for _ in range(w3.MAX_BOT_WAKES_PER_HOUR)))
c3.clear(); _st = int(w3.STATE.read_text())
s3[_st + 1] = raw_msg(_st + 1, 555, "@team_agent_bot петля?")
w3.tick()
ok("1743r2: бот-участник при упоре не будит", not c3 and w3.STATE.read_text() == str(_st + 1))
w3.save_pending([{"id": 1, "name": "?", "uid": 4242, "user": None, "text": "x", "woke_at": 0.0, "tries": 0, "q": "unv"},
                 {"id": 2, "name": "Д", "uid": PEER, "user": None, "text": "y", "woke_at": 0.0, "tries": 0, "q": "bot"}])
w3.nudge_overdue(1000.0)
_pp = w3.load_pending()
ok("1743r2: СРОЧНО при бот-упоре: неизвестный держится без tries, бот-помощник выброшена как раньше",
   not c3 and [p["id"] for p in _pp] == [1] and _pp[0]["tries"] == 0)
w3.bot_wakes_path().write_text(""); w3.save_pending([])

# ---- Codex #1743 r3: a failing send of a bot call cannot storm past the bot cap, and is never dropped ----
w3.bot_wakes_path().write_text(""); c3.clear(); _st = int(w3.STATE.read_text())
s3[_st + 1] = raw_msg(_st + 1, PEER, "@team_agent_bot Тимофей?")
_tries = [0]
def _accept_then_fail(args, data=b"", timeout=120):
    _tries[0] += 1
    raise RuntimeError("helper timeout after webhook accepted")
w3.remote = _accept_then_fail
for _ in range(10):
    try:
        w3.tick()
    except RuntimeError:
        pass
ok("1743r3: упавшие отправки бот-вызова не больше бот-потолка", _tries[0] == w3.MAX_BOT_WAKES_PER_HOUR)
ok("1743r3: и вызов не выброшен (state перед ним)", w3.STATE.read_text() == str(_st) and _st + 1 in w3.load_bot_inflight())
w3.remote = lambda args, data=b"", timeout=120: c3.append((args, data)) or "woken"
w3.bot_wakes_path().write_text("")
w3.tick()
ok("1743r3: после освобождения дошёл", len(c3) == 1 and "Тимофей?" in c3[0][1] and not w3.load_bot_inflight())

# ---- #1743 add-on 3: name trigger (GW_NAME_REGEX) ----
ok("имя: включено GW_NAME_REGEX, без него нет", w.NAME_TRIGGER and not w3.NAME_TRIGGER)
for txt in ("Тима, глянь", "у Тимы спроси", "Тиме передай", "спроси Тиму", "с Тимой", "Тимочка, привет", "Тимофей!",
            "у Тимофея", "Тимофею скажи", "с Тимофеем", "о Тимофее", "ТИМОФЕЙ", "(Тима)"):
    ok(f"имя будит: {txt!r}", w.is_trigger(P(5, 700001, text=txt), None))
for txt in ("Иван Тимофеевич", "Тимон", "тимбилдинг", "тимлид", "Тимофеевна", "Тимошенко", "Тимофейчук", "интим",
            "Тимати", "тимофеевский"):
    ok(f"имя НЕ будит: {txt!r}", not w.is_trigger(P(5, 700001, text=txt), None))
ok("имя от бота-помощника не будит (только тег)", not w.is_trigger(P(5, PEER, text="Тимофей, глянь"), None))
w._usernames[556] = "other_helper_bot"
ok("имя от чужого бота не будит", not w.is_trigger(P(5, 556, text="Тима, привет"), None))
ok("имя от игнорируемого не будит", not w.is_trigger(P(5, 900004, text="Тима"), None))
ok("имя = обращение (ставит СРОЧНО)", w.is_call(P(5, 700001, text="Тима, ответь"), None))

# ---- Codex #1743 r4 ----
_mem_saved = set(w._members); w._members.clear(); w._members.add(700001)
_un = P(5, 999001, text="Тима, привет")
ok("1743r4: имя от не-участника (кэш пуст/новый бот) = под бот-потолком", w.is_trigger(_un, None) and w.bot_like(_un))
ok("1743r4: имя от участника-человека будит как человек", w.is_trigger(P(5, 700001, text="Тима"), None)
   and not w.bot_like(P(5, 700001, text="Тима")))
w._members.clear(); w._members.update(_mem_saved)
# nudge: bot quota reserved before the send
w3.bot_wakes_path().write_text(" ".join(str(int(REAL_TIME())) for _ in range(w3.MAX_BOT_WAKES_PER_HOUR - 1)))
w3.save_pending([{"id": 3, "name": "Д", "uid": PEER, "user": None, "text": "y", "woke_at": REAL_TIME() - 200, "tries": 0, "q": "bot"}])
w3.remote = lambda args, data=b"", timeout=120: (_ for _ in ()).throw(RuntimeError("accepted, then helper timeout"))
ok("1743r4: повтор СРОЧНО упал", raises(lambda: w3.nudge_overdue(REAL_TIME())))
ok("1743r4: квота бота за него уже списана", len(w3.recent_wakes(REAL_TIME(), w3.bot_wakes_path())) == w3.MAX_BOT_WAKES_PER_HOUR)
w3.remote = lambda args, data=b"", timeout=120: c3.append((args, data)) or "woken"
w3.bot_wakes_path().write_text(""); w3.save_pending([])
# crash between the inflight write and the quota reservation: the call is held, not dropped
w3.bot_wakes_path().write_text(" ".join(str(int(REAL_TIME())) for _ in range(w3.MAX_BOT_WAKES_PER_HOUR - 1)))
c3.clear(); _st = int(w3.STATE.read_text())
s3[_st + 1] = raw_msg(_st + 1, PEER, "@team_agent_bot седьмой")
_nw = w3.note_wake
w3.note_wake = lambda now, path=None: (_ for _ in ()).throw(OSError("crash")) if path is not None else _nw(now, path)
ok("1743r4: падение на резерве бот-квоты", raises_any(w3.tick))
w3.note_wake = _nw
w3.bot_wakes_path().write_text(" ".join(str(int(REAL_TIME())) for _ in range(w3.MAX_BOT_WAKES_PER_HOUR)))
w3.tick()
ok("1743r4: при упоре вызов удержан, а не выброшен", w3.STATE.read_text() == str(_st) and not c3)
w3.bot_wakes_path().write_text(""); w3.tick()
ok("1743r4: потом доставлен", len(c3) == 1 and "седьмой" in c3[0][1])

# ===================== #1740 merged onto #1743 =====================
_ms = set(w._members); w._members.clear()
_tg = P(5, 999002, text="@team_agent_bot вопрос")
ok("merge: при пустом списке участников тег человека не попадает под бот-потолок", w.is_trigger(_tg, None) and not w.bot_like(_tg))
_nm = P(5, 999002, text="Тима, вопрос")
ok("merge: имя от неизвестного отправителя под бот-потолком", w.is_trigger(_nm, None) and w.bot_like(_nm))
w._members.update(_ms)
# name added by an edit wakes him
calls.clear(); w.WAKES.write_text(""); w.bot_wakes_path().write_text("")
w._members.add(222)
_n1 = max(astore) + 1
astore[_n1] = rawx(_n1, 222, "вопрос всем")
w.tick()
astore[_n1] = rawx(_n1, 222, "вопрос всем, Тима?", edit_date="e")
w.tick()
ok("merge: имя добавлено правкой будит", len(calls) == 1 and "Тима?" in calls[0][1] and "правк" in calls[0][1])
# a held edit never moves the state backwards
calls.clear(); w.bot_wakes_path().write_text(" ".join(str(int(REAL_TIME())) for _ in range(w.MAX_BOT_WAKES_PER_HOUR)))
_n2 = max(astore) + 1
astore[_n2] = rawx(_n2, 4243, "болтовня")
w.tick()
_s_before = int(w.STATE.read_text())
astore[_n2] = rawx(_n2, 4243, "болтовня, Тима", edit_date="e")
astore[_n2 + 1] = rawx(_n2 + 1, 222, "новое")
w.tick()
ok("merge: удержанная правка не двигает state назад, новое проходит", int(w.STATE.read_text()) == _n2 + 1 >= _s_before
   and w.load_seen()[_n2][2] is True)
w.bot_wakes_path().write_text(""); w.tick()
ok("merge: удержанная правка дошла после освобождения", any("болтовня, Тима" in c[1] for c in calls))
# multi-part: a crash after part 1 does not re-send part 1
c3.clear(); _st = int(w3.STATE.read_text())
for n in range(1, 16):
    s3[_st + n] = raw_msg(_st + n, 700005, f"М{n} " + "ж" * 4000 + f" КОНЕЦ-M{n}.")
_cnt3 = [0]
def _r3(args, data=b"", timeout=120):
    _cnt3[0] += 1
    if _cnt3[0] == 2:
        raise RuntimeError("down")
    c3.append((args, data)); return "woken"
w3.remote = _r3
raises(w3.tick)
w3.remote = lambda args, data=b"", timeout=120: c3.append((args, data)) or "woken"
w3.tick()
_all3 = [d for _, d in c3]
ok("merge: после сбоя второй части первая не повторяется, все дошли по разу",
   all(sum(f"КОНЕЦ-M{n}." in d for d in _all3) == 1 for n in range(1, 16)))

# ---- review r2: a failing re-send of a bot-class edit stays under the bot cap ----
_g4 = Path(tempfile.mkdtemp())
w4 = load("w4", {"GW_BASE": str(_g4), "GW_FEED": "0", "GW_BOT_WAKES_PER_HOUR": "1"})
w4._members.update({1}); w4._members_forced_at = REAL_TIME(); w4._usernames_at = REAL_TIME()
w4.usernames = lambda: w4._usernames
s4 = {1: raw_msg(1, 1, "старт")}
w4.fetch_recent = lambda timeout=30: (max(s4), {i: w4.text_hash(json.loads(s4[i])["text"]) for i in s4})
w4.fetch_one = lambda mid, timeout=30: w4.parse(mid, s4[mid]) if mid in s4 else None
w4.deliver_media = lambda m, deadline=None: None
_att4 = []
w4.remote = lambda args, data=b"", timeout=120: _att4.append(data) or (_ for _ in ()).throw(RuntimeError("accepted, then timeout"))
w4.tick()
s4[2] = raw_msg(2, 4244, "болтовня"); w4.tick()
s4[2] = raw_msg(2, 4244, "болтовня, Тима?")
for _ in range(4):
    raises(w4.tick)
ok("r2: правка-имя от неизвестного, отправка падает: попыток не больше бот-потолка", len(_att4) == 1
   and len(w4.recent_wakes(REAL_TIME(), w4.bot_wakes_path())) == 1 and 2 in w4.load_bot_inflight())
w4.remote = lambda args, data=b"", timeout=120: _att4.append(data) or "woken"
w4.bot_wakes_path().write_text(""); w4.tick()
ok("r2: после освобождения квоты доставлено и снято из ожидания отправки", len(_att4) == 2 and "Тима?" in _att4[-1]
   and not w4.load_bot_inflight())

# ---- review r3: a crash between «in flight» and the quota stamp keeps the repeat bot-class ----
w4.bot_wakes_path().write_text(""); _att4.clear()
s4[3] = raw_msg(3, 4245, "просто так"); w4.tick()
s4[3] = raw_msg(3, 4245, "просто так, Тима?")
_nw4 = w4.note_wake
_crash = [True]
def _nw_crash(now, path=None):
    if path is None and _crash[0]:
        _crash[0] = False; raise OSError("crash after mark_inflight")
    return _nw4(now, path)
w4.note_wake = _nw_crash
w4.remote = lambda args, data=b"", timeout=120: _att4.append(data) or (_ for _ in ()).throw(RuntimeError("accepted, then timeout"))
for _ in range(5):
    raises_any(w4.tick)
w4.note_wake = _nw4
ok("r3: сбой между записями: повторы под бот-потолком (1 попытка при лимите 1)", len(_att4) == 1
   and len(w4.recent_wakes(REAL_TIME(), w4.bot_wakes_path())) == 1 and 3 in w4.load_bot_inflight())

# ---- review r4: a crash after the send but before seen commits keeps the bot class ----
w4.remote = lambda args, data=b"", timeout=120: _att4.append(data) or "woken"
w4.bot_wakes_path().write_text(""); w4.tick()  # the r3 call is delivered first
ok("r3: после освобождения квоты удержанный вызов доставлен", any("Тима?" in x for x in _att4) and not w4.load_bot_inflight())
w4.bot_wakes_path().write_text(""); _att4.clear()
_top4 = max(s4); s4[_top4 + 1] = raw_msg(_top4 + 1, 4246, "болтовня"); w4.tick()
s4[_top4 + 1] = raw_msg(_top4 + 1, 4246, "болтовня, Тимофей?")
_ap4 = w4.add_pending
w4.add_pending = lambda *a, **k: (_ for _ in ()).throw(OSError("crash after the send"))
raises_any(w4.tick)
w4.add_pending = _ap4
ok("r4: сбой после отправки до commit: бот-класс сохранён", len(_att4) == 1 and _top4 + 1 in w4.load_bot_inflight())
for _ in range(3):
    w4.tick()
ok("r4: повтор неподтверждённой отправки под бот-потолком (лимит 1 исчерпан)", len(_att4) == 1)
w4.bot_wakes_path().write_text(""); w4.tick()
ok("r4: после освобождения повтор доставлен, бот-класс снят после commit", len(_att4) == 2 and not w4.load_bot_inflight()
   and not w4.load_seen()[_top4 + 1][4])

# ---- review r5: album parts of a bot-class call keep the bot class on a failed send ----
w4.bot_wakes_path().write_text(""); _att4.clear()
_t5 = max(s4)
s4[_t5 + 1] = json.dumps({"id": _t5 + 1, "sender": "S4247", "text": "Тима, глянь", "media_kind": "photo",
                         "raw": {"_": "Message", "from_id": {"_": "PeerUser", "user_id": 4247}, "grouped_id": 515}})
s4[_t5 + 2] = json.dumps({"id": _t5 + 2, "sender": "S4247", "text": "", "media_kind": "photo",
                         "raw": {"_": "Message", "from_id": {"_": "PeerUser", "user_id": 4247}, "grouped_id": 515}})
w4.remote = lambda args, data=b"", timeout=120: _att4.append(data) or (_ for _ in ()).throw(RuntimeError("accepted, then timeout"))
for _ in range(4):
    raises_any(w4.tick)
ok("r5: альбом неизвестного по имени, отправка падает: попыток не больше бот-потолка, части с бот-классом", len(_att4) == 1
   and {_t5 + 1, _t5 + 2} <= w4.load_bot_inflight())
w4.remote = lambda args, data=b"", timeout=120: _att4.append(data) or "woken"
w4.bot_wakes_path().write_text(""); w4.tick()
ok("r5: после освобождения альбом доставлен, бот-класс снят", len(_att4) == 2 and not w4.load_bot_inflight())

# ===================== Codex #1740 merge r1 =====================
_urls = []
w._get = lambda url, timeout=30: _urls.append(url) or {"success": True, "data": _lst}
if hasattr(w, "_deep_at"): w._deep_at[0] = 0.0
REAL_FETCH_RECENT(); REAL_FETCH_RECENT()
w._get = real_get
ok("mr1-2: раз в 5 минут листинг смотрит 100 сообщений, иначе 20", "page_size=100" in _urls[0] and "page_size=20" in _urls[1])
w.clear_deferred(); w.note_bot_dropped([1, 2]); w.note_bot_dropped([2, 3])
ok("mr1-5: id называется один раз", "1, 2, 3." in w.deferred_header())
w.note_bot_dropped(list(range(1000, 1250)))
_h = w.deferred_header()
ok("mr1-5: при переполнении старые не пропадают молча", "ещё 53 более ранних" in _h and "1249" in _h)
w.clear_deferred()
# album with two tagged captions: the untagged part once
calls.clear(); w.WAKES.write_text(""); w.bot_wakes_path().write_text("")
_a = max(astore) + 1
w.save_state(_a - 1)
astore[_a] = rawx(_a, 222, "@team_agent_bot первое", kind="photo", grouped_id=8881)
astore[_a + 1] = rawx(_a + 1, 222, "@team_agent_bot второе", kind="photo", grouped_id=8881)
astore[_a + 2] = rawx(_a + 2, 222, "", kind="photo", grouped_id=8881)
w.tick()
ok("mr1-6: часть альбома при двух тегах один раз", len(calls) == 1 and calls[0][1].count(f"/x/m{_a + 2}") == 1)
# pending follows the delivered version (revert after an uncommitted correction)
calls.clear()
_v = max(astore) + 1
astore[_v] = rawx(_v, 222, "@team_agent_bot переведи 100")
w.tick()
_pp = w.load_pending()
for p_ in _pp:
    if p_["id"] == _v:
        p_["text"] = "ОТМЕНА"
w.save_pending(_pp)
_sn = w.load_seen(); _sn[_v][4] = True; w.save_seen(_sn, max(astore))
w.tick()
ok("mr1-3: повторная доставка возвращает в ожидание доставленный текст",
   len(calls) == 2 and [p_["text"] for p_ in w.load_pending() if p_["id"] == _v] == ["@team_agent_bot переведи 100"])
# the state never moves back when a later part holds only old corrections
calls.clear()
_o = max(astore) + 1
for k_ in range(3):
    astore[_o + k_] = rawx(_o + k_, 222, f"@team_agent_bot старое {k_}")
w.tick()
_L = int(w.STATE.read_text())
for k_ in range(3):
    astore[_o + k_] = rawx(_o + k_, 222, f"@team_agent_bot старое {k_} " + "щ" * 40000 + f" FIX{k_}.", edit_date="e")
astore[_L + 1] = rawx(_L + 1, 222, "@team_agent_bot новое NEW1.")
_cnt = [0]
def _rf(args, data=b"", timeout=120):
    _cnt[0] += 1
    if _cnt[0] == 3:
        raise RuntimeError("down")
    calls.append((args, data)); return "woken"
w.remote = _rf
raises(w.tick)
_after = int(w.STATE.read_text())
w.remote = fake_remote
w.tick()
ok("mr1-4: state не откатывается частью старых правок, новое не повторяется",
   _after == _L + 1 and sum("NEW1." in c[1] for c in calls) == 1 and all(sum(f"FIX{k_}." in c[1] for c in calls) >= 1 for k_ in range(3)))

# ===================== Codex #1740 merge r2 =====================
_ma = w.parse(77, rawx(77, 222, "x", kind="photo", media={"_": "MessageMediaPhoto", "photo": {"id": 1}}))
_mb = w.parse(77, rawx(77, 222, "x", kind="photo", media={"_": "MessageMediaPhoto", "photo": {"id": 2}}))
ok("mr2-2: у каждой версии файла своё имя", w.media_name(_ma, Path("a.jpg")) != w.media_name(_mb, Path("a.jpg")))
calls.clear(); w.WAKES.write_text(""); w.bot_wakes_path().write_text("")
_L2 = int(w.STATE.read_text())
astore[_L2 + 1] = rawx(_L2 + 1, 222, "просто так")
astore[_L2 + 2] = rawx(_L2 + 2, 222, "@team_agent_bot раз " + "ы" * 40000)
astore[_L2 + 3] = rawx(_L2 + 3, 222, "@team_agent_bot два " + "ы" * 40000)
_cnt2 = [0]
def _rf2(args, data=b"", timeout=120):
    _cnt2[0] += 1
    if _cnt2[0] == 2:
        raise RuntimeError("down")
    calls.append((args, data)); return "woken"
w.remote = _rf2
raises(w.tick)
w.remote = fake_remote
astore[_L2 + 1] = rawx(_L2 + 1, 222, "просто так @team_agent_bot ТЕГПРАВКОЙ", edit_date="e")
w.tick(); w.tick()
ok("mr2-1: тег правкой в сообщении, через которое прошёл частичный commit, будит", any("ТЕГПРАВКОЙ" in c[1] for c in calls))

# ===================== Codex #1740 merge r3 =====================
_g0, _r0, _f0 = w._get, w.remote, w.fetch_one
w._get = chip_ok; w.STAGING.chmod(0o700)
w.remote = lambda args, data=b"", timeout=120: "/x/m61.jpg"
_pa = rawx(61, 222, "фото", kind="photo", media={"_": "MessageMediaPhoto", "photo": {"id": 1}})
_pb = rawx(61, 222, "фото", kind="photo", media={"_": "MessageMediaPhoto", "photo": {"id": 2}})
w.fetch_one = lambda mid, timeout=30: w.parse(mid, _pb)  # swapped to B while A was being downloaded
_ma3 = w.parse(61, _pa)
real_deliver(_ma3)
ok("mr3-1: файл, заменённый во время скачивания, не кэшируется под старой версией", (61, _ma3.media_key) not in w._media_done)
w.fetch_one = lambda mid, timeout=30: w.parse(mid, _pa)
_ma4 = w.parse(61, _pa)
real_deliver(_ma4)
ok("mr3-1: неизменённый кэшируется как прежде", (61, _ma4.media_key) in w._media_done)
w._get, w.remote, w.fetch_one = _g0, _r0, _f0
# an album part with its own tag, delivered past the tick's end, does not wake him twice
calls.clear(); w.WAKES.write_text(""); w.bot_wakes_path().write_text("")
_b3 = int(w.STATE.read_text())
_mx = w.MAX_MSGS_PER_TICK; w.MAX_MSGS_PER_TICK = 1
astore[_b3 + 1] = rawx(_b3 + 1, 222, "@team_agent_bot первое", kind="photo", grouped_id=9991)
astore[_b3 + 2] = rawx(_b3 + 2, 222, "@team_agent_bot второе", kind="photo", grouped_id=9991)
w.tick(); w.tick()
w.MAX_MSGS_PER_TICK = _mx
ok("mr3-2: часть альбома с тегом за границей тика не будит второй раз", len(calls) == 1)

# ===================== Codex #1740 merge r4 =====================
_g0, _r0 = w._get, w.remote
w._get = chip_ok; w.STAGING.chmod(0o700)
w.remote = lambda args, data=b"", timeout=120: "/x/m62.pdf"
_ds = w.parse(62, raw_msg(62, 1, media="document", size=999, fname="a.pdf"))
real_deliver(_ds)
ok("mr4-2: скачан файл другого размера, чем прочитан: в кэш не идёт", (62, _ds.media_key) not in w._media_done and any("/x/m62.pdf" in a for a in _ds.attachments))
w._get, w.remote = _g0, _r0
calls.clear(); w.WAKES.write_text(""); w.bot_wakes_path().write_text("")
_b4 = int(w.STATE.read_text())
astore[_b4 + 1] = rawx(_b4 + 1, 222, "@team_agent_bot смотри альбом", kind="photo", grouped_id=7771)
w.tick()
astore[_b4 + 2] = rawx(_b4 + 2, 222, "", kind="photo", grouped_id=7771)
astore[_b4 + 3] = rawx(_b4 + 3, 222, "", kind="photo", grouped_id=7771)
astore[_b4 + 4] = rawx(_b4 + 4, 222, "не альбом")
w.tick()
ok("mr4-1: части альбома, пришедшие после снимка, доходят следующим тиком",
   len(calls) == 2 and f"/x/m{_b4 + 2}" in calls[1][1] and f"/x/m{_b4 + 3}" in calls[1][1] and "не альбом" not in calls[1][1])
w.tick()
ok("mr4-1: и не повторяются", len(calls) == 2)
astore[_b4 + 2] = rawx(_b4 + 2, 222, "подпись ПОЗЖЕ", kind="photo", grouped_id=7771, edit_date="e")
w.tick()
ok("mr5-1: правка подписи доставленного продолжения альбома доходит", len(calls) == 3 and "подпись ПОЗЖЕ" in calls[2][1])

print("FAILS:", fails)
raise SystemExit(1 if fails else 0)
