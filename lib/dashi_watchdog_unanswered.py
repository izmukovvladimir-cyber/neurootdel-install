#!/usr/bin/env python3
"""Признак «агент реагирует, но не отвечает» для сторожа агентов (agents-guard.py).

03.09.2026. Прежний признак считал `grep -c` по строкам
"dashi-channel__react" / "dashi-channel__reply" во всём JSONL и потому считал
УПОМИНАНИЯ этих строк: правило read-receipt из rules.md агента, системные
сообщения, текст самого nudge. На контрольном транскрипте это
давало 47 против 40 при девяти и восьми настоящих вызовах, то есть тревогу на
исправной работе (reply ушёл через 49 секунд после сообщения владельца).

Но и честный счёт вызовов на вопрос не отвечает: реакция ставится на КАЖДОЕ
входящее по правилу read-receipt, а один reply законно закрывает пачку
сообщений подряд, поэтому у здорового агента react всегда больше reply.
Поэтому судится не счёт, а порядок: была ли отправка ПОСЛЕ последней речи
человека и сколько прошло с тех пор.

Речью человека считается входящее с source="telegram". Межагентные письма и
сам nudge приходят с source="webhook": ответа в Telegram они не требуют, а
считать их входящими значило бы, что каждый посланный nudge сам создаёт повод
для следующего.

ОЖИДАНИЕ ВЕДЁТСЯ ПО ЧАТУ (находка Codex). Агент отвечает и в личку, и в группы;
без разбора chat_id ответ в группу закрывал бы неотвеченное личное сообщение, а
чужой групповой вопрос порождал бы nudge с текстом про личку. Входящее открывает
ожидание своего чата, отправка закрывает ожидание того чата, в который она идёт.

Судится НЕ ОДИН файл, а все переданные транскрипты агента вместе: рестарт заводит
новую сессию, и незакрытое ожидание из прежней иначе не увидел бы никто (находка
Codex). Записи из всех файлов сводятся по времени, последняя речь человека берётся
глобальная.

Вывод — одна строка на stdout:
    RESULT: <answered|unanswered|unknown> silent_sec=<N|-> last_human=<iso|-> reason=<...>
Коды возврата: 0 вердикт вынесен, 2 не прочитан ни один файл.
"""

from __future__ import annotations

import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

REPLY_TOOL = "mcp__dashi-channel__reply"
# Открывающий тег входящего; атрибуты разбираются ТОЛЬКО из него.
_CHANNEL_TAG = re.compile(r"<channel\b[^>]*>")
_CHAT_ID = re.compile(r'chat_id="([^"]*)"')
# Годный адрес чата: целое, у групп со знаком минус. Замер по парку 03.09: 1118 речей
# человека, негодных ноль.
_CHAT_OK = re.compile(r"-?[0-9]+")


def _ts(entry: dict) -> datetime | None:
    """Метка времени записи; None, если её нет или она не разбирается."""
    raw = entry.get("timestamp")
    if not isinstance(raw, str):
        return None
    try:
        stamp = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None
    # Метка без зоны с зонированной не вычитается (TypeError уронил бы разбор),
    # а достраивать ей зону значило бы выдумывать час. Такая запись не судится.
    return stamp if stamp.tzinfo is not None else None


def _text_of(message: object) -> str:
    if not isinstance(message, dict):
        return ""
    content = message.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(
            blk.get("text", "")
            for blk in content
            if isinstance(blk, dict) and blk.get("type") == "text"
        )
    return ""


def _human_chat(entry: dict) -> str | None:
    """Чат речи человека из Telegram; None, если это не она.

    Тег входящего несёт ДВА атрибута source (внешний dashi-channel и внутренний),
    поэтому судим по наличию `source="telegram"` в ОТКРЫВАЮЩЕМ ТЕГЕ, а не по
    первому вхождению и не по всему тексту: письмо, цитирующее эту строку в теле,
    иначе читалось бы как речь человека и порождало ложную тревогу (Codex).
    """
    if entry.get("type") != "user":
        return None
    match = _CHANNEL_TAG.search(_text_of(entry.get("message")))
    if not match or 'source="telegram"' not in match.group(0):
        return None
    chat = _CHAT_ID.search(match.group(0))
    return chat.group(1) if chat else ""


def _reply_calls(entry: dict) -> list[tuple[str, str | None]]:
    """Пары (идентификатор вызова, чат отправки) для вызовов reply в записи.

    Чат None означает, что вызов его не назвал: такая отправка засчитывается
    закрывающей ЛЮБОЕ открытое ожидание. Это выбор в сторону молчания —
    ложная тревога сбивает живого агента с работы и дороже пропуска.
    """
    if entry.get("type") != "assistant":
        return []
    message = entry.get("message")
    content = message.get("content") if isinstance(message, dict) else None
    if not isinstance(content, list):
        return []
    calls: list[tuple[str, str | None]] = []
    for blk in content:
        if not isinstance(blk, dict) or blk.get("type") != "tool_use":
            continue
        if blk.get("name") != REPLY_TOOL:
            continue
        args = blk.get("input")
        chat = args.get("chat_id") if isinstance(args, dict) else None
        calls.append((str(blk.get("id")), str(chat) if chat is not None else None))
    return calls


def _failed_tool_ids(entry: dict) -> list[str]:
    """Идентификаторы вызовов, чей результат пришёл ОШИБКОЙ.

    Отсутствие результата ошибкой НЕ считается: у идущего прямо сейчас хода его
    ещё нет, и требование результата давало бы тревогу по работающему агенту.
    Не доказанный отказ это не отказ.
    """
    message = entry.get("message")
    content = message.get("content") if isinstance(message, dict) else None
    if not isinstance(content, list):
        return []
    return [
        str(blk.get("tool_use_id"))
        for blk in content
        if isinstance(blk, dict)
        and blk.get("type") == "tool_result"
        and blk.get("is_error") is True
    ]


def judge(paths: "Path | list[Path]", now: datetime) -> tuple[str, str]:
    """Вердикт по всем транскриптам агента вместе."""
    if isinstance(paths, Path):
        paths = [paths]
    # (метка, ничья, порядок файла, запись). «Ничья» разводит записи с ОДИНАКОВОЙ меткой из
    # разных сессий: без неё их порядок задавал бы порядок файлов, и reply мог встать
    # ПЕРЕД вопросом той же секунды, дав ложное «не отвечено» (Codex, круг 11). Речь
    # человека идёт первой, значит отправка той же метки ожидание закрывает — выбор в
    # сторону молчания, как и везде в этом приборе.
    events: list[tuple[datetime, int, int, dict]] = []
    read_any = False
    errno = 0
    for order, path in enumerate(paths):
        try:
            with path.open(encoding="utf-8", errors="replace") as fh:
                read_any = True
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        entry = json.loads(line)
                    except (ValueError, TypeError):
                        # Негодная строка это НЕ «пусто». Крон читает файл, который пишут
                        # прямо сейчас, и может застать строку без завершающего перевода;
                        # если это была строка с reply, молчаливый пропуск дал бы ложное
                        # «не отвечено» по агенту, который ответил (Codex). Замер по парку:
                        # 0 негодных строк из 289 447, то есть строгость ничего не стоит.
                        return ("unknown", "RESULT: unknown silent_sec=- last_human=- "
                                           f"reason=негодная строка в {path.name}")
                    if not isinstance(entry, dict):
                        return ("unknown", "RESULT: unknown silent_sec=- last_human=- "
                                           f"reason=запись не объект в {path.name}")
                    if entry.get("type") == "api-request-blob":
                        # Copy of the outgoing API request (Claude Code 2.1.3xx, from 25.10): it
                        # repeats turns already logged with their own stamps and has none itself.
                        continue
                    stamp = _ts(entry)
                    if stamp is None:
                        # Без метки времени запись в порядок не встаёт: она не может ни
                        # открыть ожидание, ни закрыть его. Таких записей четверть парка
                        # (70 454 из 289 457), поэтому объявлять по ним «судить нельзя»
                        # значило бы выключить сторож целиком. НО если такая запись несёт
                        # речь человека или вызов reply, она уже влияет на вердикт, и
                        # тихо потерять её нельзя — тогда судить нельзя. Замер: таких 0.
                        # Отказ инструмента сюда же: размеченный reply, чей результат
                        # пришёл ошибкой, иначе сошёл бы за успешную отправку и дал бы
                        # ложное «отвечено» (Codex, круг 9).
                        if (_human_chat(entry) is not None or _reply_calls(entry)
                                or _failed_tool_ids(entry)):
                            return ("unknown", "RESULT: unknown silent_sec=- last_human=- "
                                               f"reason=значимая запись без метки в {path.name}")
                        continue
                    chat_now = _human_chat(entry)
                    if chat_now is not None and not _CHAT_OK.fullmatch(chat_now):
                        # Речь человека без годного адреса чата: ожидание по ней вести
                        # некуда, а nudge получился бы с указанием «ответь в чат
                        # неизвестен», то есть невыполнимым (Codex, круг 16). Замер по
                        # парку: 1118 речей, негодных 0, значит строгость ничего не стоит.
                        return ("unknown", "RESULT: unknown silent_sec=- last_human=- "
                                           f"reason=речь человека без чата в {path.name}")
                    tie = 0 if chat_now is not None else 1
                    events.append((stamp, tie, order, entry))
        except OSError as exc:
            # Непрочитанный файл мог нести ОТВЕТ, поэтому его отсутствие в разборе это не
            # «в нём ничего нет». Один отказ чтения обесценивает весь вердикт (Codex).
            errno = exc.errno or 0
            return ("unknown", "RESULT: unknown silent_sec=- last_human=- "
                               f"reason=нечитаем:{errno}:{path.name}")
    if not read_any:
        return "unknown", f"RESULT: unknown silent_sec=- last_human=- reason=нечитаем:{errno}"

    events.sort(key=lambda e: (e[0], e[1], e[2]))
    # chat -> (метка последней речи, идентификаторы отправок после неё)
    waiting: dict[str, tuple[datetime, list[str]]] = {}
    failed: set[str] = set()
    for stamp, _tie, _order, entry in events:
        chat = _human_chat(entry)
        if chat is not None:
            waiting[chat] = (stamp, [])
            continue
        for call_id, target in _reply_calls(entry):
            for key in list(waiting):
                if target is None or target == key:
                    waiting[key][1].append(call_id)
        failed.update(_failed_tool_ids(entry))

    if not waiting:
        return "unknown", "RESULT: unknown silent_sec=- last_human=- reason=речи человека в файле нет"

    unanswered = [
        (stamp, chat) for chat, (stamp, calls) in waiting.items()
        if not any(cid not in failed for cid in calls)
    ]
    if not unanswered:
        newest = max(stamp for stamp, _ in waiting.values())
        silent = int((now - newest).total_seconds())
        if silent < 0:
            return ("unknown",
                    f"RESULT: unknown silent_sec=- last_human={newest.isoformat()} "
                    f"reason=метка входящего в будущем")
        return ("answered",
                f"RESULT: answered silent_sec={silent} "
                f"last_human={newest.isoformat()} reason=-")

    # Из незакрытых берётся САМОЕ ДАВНЕЕ: оно и есть худший случай, о нём и речь.
    stamp, chat = min(unanswered)
    silent = int((now - stamp).total_seconds())
    if silent < 0:
        # Метка из будущего: часы разошлись, судить нельзя.
        return ("unknown",
                f"RESULT: unknown silent_sec=- last_human={stamp.isoformat()} "
                f"reason=метка входящего в будущем")
    return ("unanswered",
            f"RESULT: unanswered silent_sec={silent} "
            f"last_human={stamp.isoformat()} reason=чат:{chat or '-'}")


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: dashi_watchdog_unanswered.py <transcript.jsonl> [...]", file=sys.stderr)
        return 2
    # Отсева по is_file() здесь НЕТ намеренно (Codex, круг 9). Файл, отобранный проводкой,
    # может исчезнуть или закрыться правами между отбором и запуском прибора, и молчаливый
    # пропуск такого файла обходил бы главную гарантию judge: любой отказ чтения делает
    # вердикт unknown. Пусть его выносит сам open.
    paths = [Path(a) for a in argv[1:]]
    _, line = judge(paths, datetime.now(timezone.utc))
    print(line)
    # Код 2 сохраняет прежний смысл «прочитать не удалось»; вердикт при этом всё равно
    # напечатан, и проводка одинаково молчит по любому из двух путей.
    return 2 if "reason=нечитаем" in line else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
