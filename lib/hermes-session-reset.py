#!/usr/bin/env python3
"""Сброс раздутой сессии агента на движке hermes (Аудитор) по порогу контекста.

Ставится установщиком neurootdel-install в <lib dir> вместе с Аудитором (этап intensive), зовётся
из hermes-auditor-reset.sh (cron /etc/cron.d/<user>-hermes-reset) под пользователем агентов.

ЗАЧЕМ ОТДЕЛЬНЫЙ ИНСТРУМЕНТ. agents-reset.sh умеет ровно один способ сброса — рестарт юнита
агента, потому что сессия Claude Code рестарта не переживает. У hermes всё иначе: сессия лежит
в SQLite (~/.hermes/state.db) и рестарт её НЕ обнуляет. Без этого инструмента сессия Аудитора
растёт без предела, и каждый ход перечитывает всю историю.

КАК СБРАСЫВАЕТСЯ. Штатный путь самого движка: пометить запись маршрутизации
`suspended: true` (`docs/session-lifecycle.md`, «Forces auto-reset on next access»).
Движок читает эти записи ОДИН РАЗ при старте и держит в памяти, поэтому одной пометки мало:
после неё нужен рестарт сервиса. Пометку ставит этот скрипт, рестарт — root-носитель заявок
agents-root-requests.sh (заявка «restart auditor»: он перезапускает hermes-auditor вместе с мостом).

ЧЕГО НЕ ДЕЛАЕТ: не трогает сообщения и сами сессии (история остаётся, теряется только
преемственность контекста), не сбрасывает агента с ЖИВЫМ ходом, заявку носителю под root не кладёт.

Запуск:
    hermes-session-reset.py --home ~/.hermes --service hermes-auditor \
        [--threshold 250000] [--apply] [--live-window 900]

Без --apply это сухой прогон: печатает замер и решение, ничего не меняет.

Коды выхода: 0 сброс сделан либо не нужен; 2 негодные аргументы; 3 база не читается;
4 пометка не записалась; 5 заявка на рестарт не положена.
"""
import argparse
import hashlib
import subprocess
import json
import os
import sqlite3
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import guard_conf  # noqa: E402

_CONF = guard_conf.load()
# Root request carrier of this server (agents-root-requests.sh, root cron once a minute): it takes
# 'restart auditor' from files owned by the agent user and restarts the auditor units.
# NEUROOTDEL_RR_BASE: tests only (a temp dir instead of /var/lib/<user>-requests).
_RR_BASE = Path(os.environ.get('NEUROOTDEL_RR_BASE') or f'/var/lib/{_CONF.agent_user}-requests')
WATCHDOG_REQ_DIR = _RR_BASE / 'requests'
WATCHDOG_RES_DIR = _RR_BASE / 'results'
WATCHDOG_PENDING = Path(os.environ.get('HERMES_RESET_STATE')
                        or _CONF.lab / 'shared/state/hermes-auditor-reset') / 'request-pending'
WATCHDOG_EXPIRE = 1800   # agents-root-requests.sh EXPIRE: an older request is dropped by the carrier
WATCHDOG_AGENT = {'hermes-auditor': 'auditor'}
WATCHDOG_FINAL = ('DONE', 'FAIL', 'REJECT', 'EXPIRED')
_watchdog_name = None   # name of the request this run waits for (set by request_restart_watchdog)


def log(*a):
    print('[hermes-reset]', *a, flush=True)


def die(msg, code):
    log('ОТКАЗ:', msg)
    raise SystemExit(code)


def live_entries(db_path):
    """Записи маршрутизации: ключ сессии, её id и время последней правки."""
    try:
        c = sqlite3.connect(f'file:{db_path}?mode=ro', uri=True, timeout=10)
        rows = list(c.execute('select scope, session_key, entry_json, updated_at from gateway_routing'))
        c.close()
    except sqlite3.Error as e:
        die(f'база {db_path} не читается: {e}', 3)
    out = []
    for scope, key, ej, upd in rows:
        try:
            entry = json.loads(ej)
        except (ValueError, TypeError):
            # Нечитаемая запись это НЕ «сбрасывать нечего»: судить о ней нельзя,
            # поэтому она называется вслух и пропускается.
            log(f'ВНИМАНИЕ: запись {key!r} не разбирается как JSON — пропускаю')
            continue
        out.append((scope, key, entry, upd or 0))
    return out


def session_context(db_path, session_id):
    """Во сколько обходится ОДИН ход этой сессии, в токенах.

    МЕРА НАЗВАНА ЧЕСТНО: это СРЕДНЕЕ по вызовам за сессию, а не размер последнего хода.
    Размера последнего хода движок не хранит нигде: `messages.token_count` пуст у всех
    сообщений до единого (проверено), а `last_prompt_tokens` в записи маршрутизации
    остаётся нулём. Среднее занижает текущий размер, потому что контекст растёт, — то
    есть ошибается в сторону «не трогать», и это выбрано сознательно: лишний сброс
    дороже пропущенного.

    Считать по символам активных сообщений НЕЛЬЗЯ: в запрос уходят ещё системный промпт,
    описания инструментов и скиллы, которых в базе нет вовсе. Замер 29.08 показал разрыв
    втрое (113 тыс. символов активной истории против ~95 тыс. токенов в реальном вызове).
    Поэтому судим по счётчикам биллинга, а объём истории идёт справкой.
    """
    try:
        c = sqlite3.connect(f'file:{db_path}?mode=ro', uri=True, timeout=10)
        row = c.execute(
            'select api_call_count, cache_read_tokens, input_tokens, message_count '
            'from sessions where id=?', (session_id,)).fetchone()
        live = c.execute(
            'select count(*), sum(length(coalesce(api_content,content,""))) '
            'from messages where session_id=? and active=1', (session_id,)).fetchone()
        c.close()
    except sqlite3.Error as e:
        die(f'база {db_path} не читается: {e}', 3)
    if not row:
        return None
    calls, cache_read, inp, msgs = (row[0] or 0), (row[1] or 0), (row[2] or 0), (row[3] or 0)
    per_turn = (cache_read + inp) // calls if calls else 0
    return {'calls': calls, 'cache_read': cache_read, 'input': inp,
            'messages': msgs, 'per_turn': per_turn,
            'live_msgs': (live[0] if live else 0) or 0,
            'live_chars': (live[1] if live else 0) or 0}


def last_message_age(db_path, session_id):
    try:
        c = sqlite3.connect(f'file:{db_path}?mode=ro', uri=True, timeout=10)
        row = c.execute('select max(timestamp) from messages where session_id=?',
                        (session_id,)).fetchone()
        c.close()
    except sqlite3.Error:
        return None
    if not row or not row[0]:
        return None
    return time.time() - row[0]


def newest_message(db_path):
    """Newest message of the whole engine (any session), epoch; None when unreadable."""
    try:
        c = sqlite3.connect(f'file:{db_path}?mode=ro', uri=True, timeout=10)
        row = c.execute('select max(timestamp) from messages').fetchone()
        c.close()
    except sqlite3.Error:
        return None
    return (row[0] or 0) if row else 0


TURN_MAX = 7200   # an unfinished last message older than this is a dead turn, not a running one


def open_turns(db_path):
    """Sessions whose newest message is not a finished answer (assistant, finish_reason other than tool_calls,
    no tool calls) and younger than TURN_MAX: a turn is running there, maybe inside one long tool call or
    model request that writes nothing for minutes. None when unreadable (then the caller holds the restart)."""
    try:
        c = sqlite3.connect(f'file:{db_path}?mode=ro', uri=True, timeout=10)
        rows = c.execute('select m.role, m.finish_reason, m.tool_calls, m.timestamp from messages m where m.rowid = (select m2.rowid from messages m2 where m2.session_id = m.session_id order by m2.timestamp desc, m2.rowid desc limit 1)').fetchall()
        c.close()
    except sqlite3.Error:
        return None
    now = time.time()
    n = 0
    for role, finish, calls, ts in rows:
        done = role == 'assistant' and finish != 'tool_calls' and calls in (None, '', '[]')
        if not done and now - (ts or 0) < TURN_MAX:
            n += 1
    return n


def withdraw_if_untaken(name):
    """Take the request back while it still sits in the carrier's inbox. True = withdrawn."""
    try:
        (WATCHDOG_REQ_DIR / name).unlink()
    except OSError:
        return False
    try:
        WATCHDOG_PENDING.unlink()
    except OSError:
        pass
    return True


def sessions_fp(conn):
    """Fingerprint of every routed session: key, id, message count, newest message. The SAME text as
    `state_q fp` of hermes-auditor-reset.sh (the wrapper stores it after a memory save)."""
    out = []
    for key, ej in conn.execute('select session_key, entry_json from gateway_routing order by session_key'):
        try:
            sid = json.loads(ej).get('session_id') or ''
        except (ValueError, AttributeError):
            sid = ''
        n, newest = conn.execute('select count(*), max(timestamp) from messages where session_id=?',
                                 (sid,)).fetchone()
        out.append(f'{key}|{sid}|{n}|{newest}')
    return hashlib.sha256('\n'.join(out).encode()).hexdigest()


def fp_matches(db_path, expect):
    """True when the sessions are still in the state the memory save covered (read-only)."""
    try:
        c = sqlite3.connect(f'file:{db_path}?mode=ro', uri=True, timeout=10)
        got = sessions_fp(c)
        c.close()
    except sqlite3.Error:
        return False
    return got == expect


def mark_batch(db_path, items, expect):
    """All marks in ONE write transaction, only while the sessions still match the saved state.
    items: [(scope, key)]. Returns 'mismatch', 'ok' (every mark read back) or 'failed'."""
    try:
        c = sqlite3.connect(db_path, timeout=15, isolation_level=None)
        c.execute('begin immediate')
        if sessions_fp(c) != expect:
            c.execute('rollback')
            c.close()
            return 'mismatch'
        for scope, key in items:
            row = c.execute('select entry_json from gateway_routing where scope=? and session_key=?',
                            (scope, key)).fetchone()
            if not row:
                c.execute('rollback')
                c.close()
                return 'failed'
            entry = json.loads(row[0])
            entry['suspended'] = True
            c.execute('update gateway_routing set entry_json=?, updated_at=? where scope=? and session_key=?',
                      (json.dumps(entry), time.time(), scope, key))
        c.execute('commit')
        ok = all(json.loads((c.execute('select entry_json from gateway_routing where scope=? and session_key=?',
                                       (scope, key)).fetchone() or ['{}'])[0]).get('suspended') is True
                 for scope, key in items)
        c.close()
        return 'ok' if ok else 'failed'
    except (sqlite3.Error, ValueError) as e:
        log('ВНИМАНИЕ: пометки не записались —', e)
        return 'failed'


def mark_suspended(db_path, scope, key):
    """Ставит suspended=true. Возвращает True только если ПЕРЕЧИТАННАЯ запись это подтвердила."""
    try:
        c = sqlite3.connect(db_path, timeout=15)
        cur = c.execute('select entry_json from gateway_routing where scope=? and session_key=?',
                        (scope, key))
        row = cur.fetchone()
        if not row:
            c.close()
            return False
        entry = json.loads(row[0])
        entry['suspended'] = True
        c.execute('update gateway_routing set entry_json=?, updated_at=? '
                  'where scope=? and session_key=?',
                  (json.dumps(entry), time.time(), scope, key))
        c.commit()
        # ЧИТАЕМ ОБРАТНО. Запись в чужую живую базу может проиграть гонку с самим движком,
        # и «commit прошёл» это не «флаг стоит».
        back = c.execute('select entry_json from gateway_routing where scope=? and session_key=?',
                         (scope, key)).fetchone()
        c.close()
        return bool(back) and json.loads(back[0]).get('suspended') is True
    except (sqlite3.Error, ValueError) as e:
        log('ВНИМАНИЕ: пометка не записалась —', e)
        return False


def watchdog_verdict(name):
    """Final word of the carrier on request <name> (DONE/FAIL/REJECT/EXPIRED) or None while open."""
    try:
        text = (WATCHDOG_RES_DIR / f'{name}.result').read_text()
    except OSError:
        return None
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[1] in WATCHDOG_FINAL:
            return parts[1]
    return None


def request_restart_watchdog(service):
    """Restart through the root request carrier: one closed-grammar line, written as *.tmp
    (the carrier skips those) and renamed into place, so it never reads half a file."""
    global _watchdog_name
    agent = WATCHDOG_AGENT.get(service)
    if agent is None:
        return False, f'для {service} у носителя нет имени агента'
    # One open request at a time: a tick that timed out waiting must not pile up a second
    # restart behind the first (Codex r1 medium). Open = no final verdict in the carrier's
    # result file yet and younger than its EXPIRE.
    try:
        prev = WATCHDOG_PENDING.read_text().split()
    except OSError:
        prev = []
    if len(prev) == 2 and prev[1].isdigit() and time.time() - int(prev[1]) < WATCHDOG_EXPIRE:
        if watchdog_verdict(prev[0]) is None:
            _watchdog_name = prev[0]
            return True, f'заявка {prev[0]} ещё у носителя, вторую не кладу'
    name = f'hermes-reset-{agent}-{int(time.time())}-{os.getpid()}'
    tmp = WATCHDOG_REQ_DIR / f'{name}.tmp'
    try:
        tmp.write_text(f'restart {agent} from={agent}\n')
        os.rename(tmp, WATCHDOG_REQ_DIR / name)
    except OSError as e:
        try:
            tmp.unlink()
        except OSError:
            pass
        return False, str(e)
    _watchdog_name = name
    try:
        WATCHDOG_PENDING.parent.mkdir(parents=True, exist_ok=True)
        WATCHDOG_PENDING.write_text(f'{name} {int(time.time())}\n')
    except OSError as e:
        log(f'заявка положена, а пометка «в работе» не записалась ({e}): возможен дубль заявки')
    return True, str(WATCHDOG_REQ_DIR / name)


def marks_survived(db_path, marked_keys):
    """Пережили ли пометки рестарт. Возвращает список ключей, у которых пометка ПРОПАЛА.

    ПОЧЕМУ ЭТО ОБЯЗАТЕЛЬНО. Движок держит весь индекс маршрутизации в памяти (читает его
    ОДИН раз при старте) и на каждой своей записи выкладывает индекс целиком —
    `_save()` в gateway/session.py:1482 пишет `{key: entry.to_dict()}` по всем записям.
    Значит любая наша правка базы снаружи невидима работающему процессу и будет затёрта
    его ближайшей записью. Пометка живёт ровно до неё, и единственное, что делает её
    настоящей, — рестарт сразу после. Поэтому судим не по факту записи, а по тому, что
    пометка ПЕРЕЖИЛА рестарт.

    Пропавший ключ или сменившийся session_id пропажей НЕ считаются: это значит, что сброс
    уже случился.
    """
    lost = []
    try:
        c = sqlite3.connect(f'file:{db_path}?mode=ro', uri=True, timeout=10)
        rows = dict(c.execute('select session_key, entry_json from gateway_routing'))
        c.close()
    except sqlite3.Error as e:
        log('ВНИМАНИЕ: перечитать пометки не удалось —', e)
        return None
    for key, sid in marked_keys:
        raw = rows.get(key)
        if raw is None:
            continue
        try:
            entry = json.loads(raw)
        except (ValueError, TypeError):
            lost.append(key)
            continue
        new_sid = entry.get('session_id')
        if not new_sid:
            # Пустой или отсутствующий session_id сброса НЕ доказывает: это просто запись,
            # по которой судить нечем. Молчаливое «continue» здесь выдало бы её за
            # состоявшийся сброс.
            lost.append(key)
            continue
        if new_sid != sid:
            continue    # сессия сменилась, то есть сброс уже случился
        if entry.get('suspended') is not True:
            lost.append(key)
    return lost


def state_path(home):
    return Path(home) / '.session-reset-state.json'


def read_state(home):
    try:
        return json.loads(state_path(home).read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return {}


def write_state(home, state):
    """Свой журнал пометок и рестартов. Возвращает False, если записать не вышло.

    ПОЧЕМУ НЕ ПО `updated_at` ЧУЖОЙ ЗАПИСИ. Движок держит индекс маршрутизации в памяти и
    на каждой своей записи выкладывает его целиком (gateway/session.py:1482), поля пишет
    СВОИ, а `updated_at` двигает сам — в том числе при старте. Поэтому «дошла ли пометка до
    движка» по чужой записи не читается вовсе: сверка старта юнита с `updated_at` дала
    вечный рестарт движка каждые 10 минут. Судим по СВОИМ отметкам: когда пометка
    поставлена и был ли ПОСЛЕ неё рестарт.
    """
    try:
        state_path(home).write_text(json.dumps(state, ensure_ascii=False, indent=1),
                                    encoding='utf-8')
        return True
    except OSError as e:
        log('ВНИМАНИЕ: свой журнал пометок не записался —', e)
        return False


def unit_started_at(service, runner=None):
    """Когда юнит поднялся, epoch. None значит «прочитать не удалось»."""
    run = runner or (lambda cmd: subprocess.run(cmd, capture_output=True, text=True, timeout=30))
    unit = service if service.endswith('.service') else f'{service}.service'
    r = run(['systemctl', 'show', unit, '-p', 'ActiveEnterTimestamp', '--value'])
    stamp = (r.stdout or '').strip()
    if not stamp:
        return None
    r2 = run(['date', '-d', stamp, '+%s'])
    try:
        return int((r2.stdout or '').strip())
    except ValueError:
        return None


def restart_directly(service, runner=None):
    """Рестарт своими руками. Годится ТОЛЬКО под root.

    Судим не по коду `systemctl restart`, а по тому, что юнит поднялся ПОСЛЕ вызова:
    отметка старта обязана сдвинуться вперёд относительно снятой до рестарта.
    """
    run = runner or (lambda cmd: subprocess.run(cmd, capture_output=True, text=True, timeout=180))
    unit = service if service.endswith('.service') else f'{service}.service'

    def active_enter():
        r = run(['systemctl', 'show', unit, '-p', 'ActiveEnterTimestampMonotonic', '--value'])
        try:
            return int((r.stdout or '0').strip() or 0)
        except ValueError:
            return 0

    before = active_enter()
    r = run(['systemctl', 'restart', unit])
    if r.returncode != 0:
        return False, f'systemctl restart {unit} вернул {r.returncode}: {(r.stderr or "").strip()[:200]}'
    after = active_enter()
    if after <= before:
        return False, (f'{unit} рестартовал без ошибки, но отметка старта не сдвинулась '
                       f'({before} -> {after}) — судить о рестарте нельзя')
    r = run(['systemctl', 'is-active', unit])
    state = (r.stdout or '').strip()
    if state != 'active':
        return False, f'{unit} после рестарта в состоянии "{state}"'
    return True, f'{unit} перезапущен своими руками'


def note_restart(home, state, keys):
    """Отмечает в своём журнале, что рестарт после пометок состоялся."""
    now = time.time()
    for key in keys:
        rec = state.setdefault(key, {'session_id': None, 'marked_at': now})
        rec['restarted_at'] = now
    return write_state(home, state)


def verdict_after_restart(db_path, marked_keys):
    """Ноль только когда КАЖДАЯ пометка либо цела, либо её сброс уже доказан сменой сессии."""
    if not marked_keys:
        return 0
    lost = marks_survived(db_path, marked_keys)
    if lost is None:
        die('рестарт был, но перечитать пометки не удалось — состоялся ли сброс, сказать '
            'нельзя', 13)
    if lost:
        die(f'рестарт был, а подтвердить сброс у {len(lost)} сессий нельзя '
            f'({", ".join(lost)}): пометки на месте нет, а смены сессии не видно. Самая '
            f'вероятная причина — движок выложил свой индекс поверх нашей правки, но '
            f'проверка этого не доказывает', 13)
    log(f'после рестарта подтверждено {len(marked_keys)}: пометка цела либо сброс уже случился')
    return 0


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument('--home', required=True)
    ap.add_argument('--service', required=True)
    ap.add_argument('--threshold', type=int, default=250000)
    ap.add_argument('--live-window', type=int, default=900)
    ap.add_argument('--carrier-wait', type=int, default=120,
                    help='сколько секунд ждать, что носитель действительно перезапустил юнит')
    ap.add_argument('--apply', action='store_true')
    ap.add_argument('--expect-fp', default='',
                    help='отпечаток сессий, покрытый сохранением памяти: другой = ни пометок, ни заявки')
    ap.add_argument('--force', action='store_true',
                    help='сбросить независимо от порога (окно живого хода всё равно уважается)')
    ap.add_argument('--restart-mode', choices=('direct', 'watchdog'), default='watchdog',
                    help='watchdog — заявка root-носителю agents-root-requests.sh (из-под пользователя агентов); '
                         'direct — systemctl своими руками (из-под root)')
    a = ap.parse_args()

    # The carrier rejects a request file whose owner is not the agent user.
    if a.restart_mode == 'watchdog' and os.geteuid() == 0:
        die('под root заявка носителю запрещена: он принимает только файлы пользователя агентов', 6)
    if a.restart_mode == 'direct' and os.geteuid() != 0:
        die('--restart-mode direct требует root: systemctl restart иначе не пройдёт', 7)

    db = Path(a.home) / 'state.db'
    if not db.is_file():
        die(f'нет базы {db}', 2)
    if not os.access(db, os.R_OK):
        die(f'база {db} нечитаема этим пользователем — под root не хожу', 3)

    fat = []
    live_skipped = []
    need_restart = []   # пометка стоит, а рестарта после неё не было
    need_sid = {}       # key -> session_id of a pending mark: its survival is checked after the restart
    unclear = []        # запись есть, а судить по ней не по чему
    examined = 0
    state = read_state(a.home)
    for scope, key, entry, upd in live_entries(db):
        # Ветка пометки идёт ПЕРВОЙ и session_id ей не нужна: решение принимается по
        # поколению (старт юнита против времени правки записи). Ниже по коду запись без
        # session_id уходит в «неопределимые», и помеченная-без-session_id запись потеряла
        # бы НУЖНЫЙ рестарт, а cron отчитался бы нолём.
        if entry.get('suspended') is True:
            # Пометка уже стоит. Движок берёт её при старте, а САМ сброс случается при
            # следующем обращении человека. Без этой ветки следующий тик пометил бы ту же
            # запись снова и снова рестартовал бы юнит — каждые 10 минут, бесконечно.
            # Судим по СВОЕМУ журналу: чужая запись про это не говорит (см. write_state).
            rec = state.get(key)
            if rec and rec.get('session_id') == entry.get('session_id'):
                if rec.get('restarted_at', 0) >= rec.get('marked_at', 0):
                    log(f'{key}: пометка стоит и рестарт после неё был — жду обращения человека')
                else:
                    need_restart.append(key)
                    log(f'{key}: пометка стоит, рестарта после неё НЕ было — нужен рестарт')
            else:
                # Своей записи нет: пометку ставили не мы либо журнал потерян. Рестарт
                # делаем ОДИН раз и сразу заводим запись, иначе это станет петлёй.
                need_restart.append(key)
                log(f'{key}: пометка стоит, своей записи о ней нет — рестартую один раз')
                state[key] = {'session_id': entry.get('session_id'),
                              'marked_at': time.time(), 'restarted_at': 0}
            # Занятого не рвём и здесь: рестарт посреди хода дороже отложенного сброса.
            sid_live = entry.get('session_id')
            if key in need_restart:
                need_sid[key] = sid_live
            age_live = last_message_age(db, sid_live) if sid_live else None
            if key in need_restart and age_live is not None and age_live < a.live_window:
                need_restart.remove(key)
                live_skipped.append(key)
                log(f'{key}: ЖИВОЙ ход {int(age_live)} с назад — рестарт откладываю')
            continue
        sid = entry.get('session_id')
        if not sid:
            unclear.append(key)
            continue
        ctx = session_context(db, sid)
        if not ctx:
            unclear.append(key)
            log(f'{key}: сессии {sid} нет в таблице sessions — судить не по чему')
            continue
        examined += 1
        age = last_message_age(db, sid)
        mark = ''
        if ctx['per_turn'] < a.threshold and not a.force:
            mark = 'ниже порога'
        elif age is not None and age < a.live_window:
            # Рвать занятого дороже сэкономленного: то же правило, что у остальных агентов.
            mark = f'ЖИВОЙ ход {int(age)} с назад — не трогаю'
            live_skipped.append(key)
        else:
            mark = 'НАДО СБРОСИТЬ' + (' (--force, порог не при чём)'
                                     if ctx['per_turn'] < a.threshold else '')
            fat.append((scope, key, sid, ctx))
        log(f'{key}: ход ~{ctx["per_turn"]:,} токенов в среднем '
            f'({ctx["calls"]} вызовов, {ctx["messages"]} сообщений; живой истории '
            f'{ctx["live_msgs"]} сообщений, {ctx["live_chars"]:,} символов) — {mark}')

    # --force это РАЗОВЫЙ сброс по заявке, и он атомарен: сбросить половину, а наружу отдать
    # ноль значит соврать, а сбросить половину и вернуть «повтори» значит рестартовать движок
    # каждую минуту, пока один чат занят. Поэтому при живом ходе не трогаем НИЧЕГО.
    # У cron (без --force) поведение другое и верное: сбрасывает что может, живое ждёт
    # следующего тика через 10 минут, и никто снаружи «готово» по этому нолю не заявляет.
    if a.force and unclear:
        die(f'разовый сброс не берусь делать: {len(unclear)} записей неопределимы '
            f'({", ".join(unclear)}). Сбросить часть и отчитаться нолём значит соврать', 10)
    if a.force and examined == 0 and not need_restart:
        die('разовый сброс не берусь делать: ни одной пригодной к суду сессии не нашлось', 10)

    if a.force and live_skipped:
        log(f'сброс ОТЛОЖЕН ЦЕЛИКОМ: живой ход у {len(live_skipped)} сессий '
            f'({", ".join(live_skipped)}), кандидатов на сброс {len(fat)} — не трогаю ни одной')
        return 8

    if not fat and not need_restart:
        if unclear:
            # «Судить не по чему» это НЕ «сбрасывать нечего». Ноль здесь означал бы, что
            # сброс не нужен, а на деле не прочитана ни одна запись.
            die(f'ни одной пригодной к суду записи: {len(unclear)} неопределимых '
                f'({", ".join(unclear)}). Сказать, нужен сброс или нет, нельзя', 11)
        if live_skipped:
            # НЕ «нечего»: сброс попросили и он НЕ состоялся. Ноль здесь означал бы для
            # вызывающего «политика применена», а движок при этом не рестартовал.
            log(f'сброс ОТЛОЖЕН: живой ход у {len(live_skipped)} сессий — {", ".join(live_skipped)}')
            return 8
        log('сбрасывать нечего')
        return 0

    if not a.apply:
        log(f'сухой прогон: пометил бы {len(fat)} сессий, рестартовал бы ради '
            f'{len(need_restart)} недоехавших пометок. Для дела нужен --apply')
        return 0

    marked = 0
    marked_keys = []
    if a.expect_fp and fat:
        # The memory save covered exactly this state; any change since then (a message, a route moved
        # to another session) must not be marked unsaved (Codex r10). Checked and marked in one transaction.
        res = mark_batch(str(db), [(scope, key) for scope, key, _sid, _ctx in fat], a.expect_fp)
        if res == 'mismatch':
            log('состояние сессий изменилось после сохранения памяти: не помечаю, решит следующий тик')
            return 8
        if res != 'ok':
            die('пометки не встали (пакетная запись): сброса не будет', 4)
    for scope, key, sid, _ctx in fat:
        if a.expect_fp:
            marked += 1
            marked_keys.append((key, sid))
            state[key] = {'session_id': sid, 'marked_at': time.time(), 'restarted_at': 0}
            log(f'помечена на сброс: {key} (сессия {sid})')
        elif mark_suspended(str(db), scope, key):
            marked += 1
            marked_keys.append((key, sid))
            state[key] = {'session_id': sid, 'marked_at': time.time(), 'restarted_at': 0}
            log(f'помечена на сброс: {key} (сессия {sid})')
        else:
            log(f'ПОМЕТКА НЕ ВСТАЛА: {key} — сброса не будет')
    if marked != len(fat) and fat:
        die(f'пометки встали не у всех: {marked} из {len(fat)}. Рестарт бы сбросил только '
            f'часть, а наружу ушло бы «готово»', 4)

    # Журнал пишется ДО рестарта: если рестарт не удастся, отметка «пометка поставлена,
    # рестарта не было» обязана пережить прогон, иначе следующий тик увидит чужую пометку
    # без своей записи и начнёт всё заново.
    write_state(a.home, state)

    if a.restart_mode == 'direct':
        ok, where = restart_directly(a.service)
        if not ok:
            die(f'рестарт не удался: {where}. Пометки стоят, но без рестарта движок их '
                f'не увидит — он читает записи только при старте', 5)
        log(where)
        if not note_restart(a.home, state, [k for k, _ in marked_keys] + need_restart):
            die('рестарт был, а свой журнал пометок не записался — следующий тик рестартует '
                'ещё раз и так по кругу. Нужны права на запись в ' + str(state_path(a.home)), 14)
        return verdict_after_restart(str(db), marked_keys + [(k, need_sid.get(k)) for k in need_restart])

    before = unit_started_at(a.service)
    # Baseline BEFORE the request is filed (Codex r2): a message between the quiet check and the
    # request must count as new. A message inside the live window holds the request altogether.
    newest_at_request = newest_message(str(db))
    if a.expect_fp and not fp_matches(str(db), a.expect_fp):
        log('состояние сессий изменилось после сохранения памяти: заявку не кладу, пометки стоят — '
            'решит следующий тик (сохранит заново)')
        return 8
    turns = open_turns(str(db))
    if turns is None or turns > 0:
        log(f'у движка незаконченный ход ({"не читается" if turns is None else turns}): заявку не кладу, '
            f'пометки стоят — решит следующий тик')
        return 8
    if newest_at_request is None or time.time() - newest_at_request < a.live_window:
        log('движок не тих перед заявкой (или база не читается): заявку не кладу, пометки стоят — '
            'решит следующий тик')
        return 8
    ok, where = request_restart_watchdog(a.service)
    if not ok:
        die(f'заявка на рестарт не положена: {where}. Пометки стоят, но без рестарта '
            f'движок их не увидит — он читает записи только при старте', 5)
    log(f'заявка на рестарт положена: {where}')

    # Ноль отдаётся только за СОСТОЯВШИЙСЯ рестарт. «Заявка положена» это не «рестарт был»:
    # носитель ходит раз в минуту и может не отработать вовсе, а вызывающий
    # (hermes-auditor-reset.sh) переводит наш ноль в слово «сброшено».
    deadline = time.time() + a.carrier_wait
    while time.time() < deadline:
        time.sleep(1)
        if a.restart_mode == 'watchdog':
            # Bound to THIS request's verdict, not to any start of the unit (Codex r3): an
            # unrelated restart must not end the wait while the request can still fire.
            v = watchdog_verdict(_watchdog_name)
            if v is None:
                # A person wrote after the request was filed: the restart would cut that turn.
                # While the carrier has not taken the request it is withdrawn; the marks stay,
                # the next tick judges again (live window, memory save).
                now_newest = newest_message(str(db))
                if (now_newest is None or newest_at_request is None
                        or now_newest > newest_at_request):
                    if withdraw_if_untaken(_watchdog_name):
                        log(f'новое сообщение после заявки {_watchdog_name}: заявка отозвана, '
                            f'рестарта не будет, пометки стоят — решит следующий тик')
                        return 8
                continue
            if v != 'DONE':
                die(f'носитель ответил {v} на заявку {_watchdog_name}. Пометки стоят', 12)
            log(f'носитель отработал заявку {_watchdog_name}, {a.service} перезапущен')
            if not note_restart(a.home, state, [k for k, _ in marked_keys] + need_restart):
                die('рестарт был, а свой журнал пометок не записался — следующий тик '
                    'рестартует ещё раз и так по кругу. Нужны права на запись в '
                    + str(state_path(a.home)), 14)
            return verdict_after_restart(str(db), marked_keys + [(k, need_sid.get(k)) for k in need_restart])
        after = unit_started_at(a.service)
        if before is not None and after is not None and after > before:
            log(f'носитель отработал, {a.service} перезапущен')
            if not note_restart(a.home, state, [k for k, _ in marked_keys] + need_restart):
                die('рестарт был, а свой журнал пометок не записался — следующий тик '
                    'рестартует ещё раз и так по кругу. Нужны права на запись в '
                    + str(state_path(a.home)), 14)
            return verdict_after_restart(str(db), marked_keys + [(k, need_sid.get(k)) for k in need_restart])
    if a.restart_mode == 'watchdog':
        # Not taken yet: withdraw it, so it never fires later in the middle of a new turn.
        try:
            (WATCHDOG_REQ_DIR / _watchdog_name).unlink()
            WATCHDOG_PENDING.unlink(missing_ok=True)   # withdrawn: the next tick may file anew
            log(f'заявка {_watchdog_name} не взята носителем за {a.carrier_wait} с — отозвана')
        except OSError:
            log(f'заявка {_watchdog_name} уже у носителя, отозвать нельзя (он снимет её по EXPIRE)')
    if before is None:
        die(f'время старта {a.service} не читается — судить о том, состоялся ли рестарт, '
            f'нельзя. Пометки стоят', 12)
    die(f'носитель не перезапустил {a.service} за {a.carrier_wait} с. Пометки стоят, но '
        f'движок их ещё не взял — он читает записи только при старте', 12)


if __name__ == '__main__':
    sys.exit(main())
