#!/usr/bin/env python3
"""claude-usage-collector.py — собирает usage per-call из JSONL-логов сессий.

Ставится установщиком. Агенты (CHANNEL_AGENTS + richard) и пути берутся из guard.conf,
база в ~/.claude-lab/shared/state/claude-usage/usage.db. Отчёт: claude-usage-digest.py
(только печать, никуда не отправляет).

Сканирует ~/.claude/projects/<каталог проекта агента>/ РЕКУРСИВНО,
читает assistant-записи с message.usage (input/output/cache tokens, model),
дедуплицирует по msg_id и пишет в SQLite. Дальше digest читает БД.

Запускается из cron каждый час. Идемпотентен — повторный прогон не задвоит.
--recent-minutes N: только файлы, менявшиеся за последние N минут; полный обход
остаётся за часовым прогоном.
"""

from __future__ import annotations

import glob
import json
import logging
import os
import sqlite3
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import guard_conf  # noqa: E402

CONF = guard_conf.load()
USAGE_DIR = Path(os.environ.get("NEUROOTDEL_USAGE_DIR")
                 or CONF.agent_home / ".claude-lab" / "shared" / "state" / "claude-usage")
LOG_FILE = USAGE_DIR / "collector.log"
LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.FileHandler(LOG_FILE), logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger("usage-collector")

DB_PATH = USAGE_DIR / "usage.db"
PROJECTS_ROOT = CONF.projects

# Агенты с ИЗОЛИРОВАННЫМ config-каталогом (CLAUDE_CONFIG_DIR) пишут сессии не в
# ~/.claude/projects; их корни перечисляются шаблоном ниже, иначе доли считались бы по
# неполным данным. Слепой сборщик хуже отсутствующего: его цифру берут в решение.
CLIENT_PROJECTS_GLOB = ""  # the installer sets up no isolated client config dirs
# Project dir of each agent: a channel agent's sessions run in its workspace or below it
# (plugin/), Richard's run with cwd = the home dir (that exact name, nothing below it).
AGENT_PREFIXES = {a: CONF.project_prefix(a) for a in CONF.channel_agents}
RICHARD_DIR = guard_conf.project_dir_name(str(CONF.agent_home))

# Субагенты пишут не рядом с сессией, а уровнем ниже:
# <project>/<session-id>/subagents/agent-<hash>.jsonl. Обход только верхнего уровня
# терял бы расход субагентов целиком, и прибор показывал бы параллель бесплатной.
# Обход рекурсивный намеренно: узкий шаблон "*/subagents/*.jsonl" ослеп бы снова от
# любого нового уровня вложенности.
SUBAGENT_DIR = "subagents"


def project_roots() -> list[Path]:
    """Все корни с сессиями: общий плюс изолированные каталоги клиентских агентов."""
    roots: list[Path] = []
    if PROJECTS_ROOT.is_dir():
        roots.append(PROJECTS_ROOT)
    else:
        log.error("общий projects root отсутствует: %s", PROJECTS_ROOT)
    if not CLIENT_PROJECTS_GLOB:
        return roots
    client_roots = sorted(p for p in map(Path, glob.glob(CLIENT_PROJECTS_GLOB)) if p.is_dir())
    if not client_roots:
        # Ровно та поломка, ради которой написан этот блок: молчаливый ноль здесь
        # означает, что вся статистика по клиентским агентам пропала из отчётов.
        log.error("НЕ НАЙДЕНО ни одного клиентского корня по %s — статистика будет неполной",
                  CLIENT_PROJECTS_GLOB)
    roots.extend(client_roots)
    return roots


def init_db(con: sqlite3.Connection) -> None:
    con.executescript(
        """
        CREATE TABLE IF NOT EXISTS calls (
            msg_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            ts_utc TEXT NOT NULL,
            agent TEXT NOT NULL,
            model TEXT,
            input_tokens INTEGER DEFAULT 0,
            output_tokens INTEGER DEFAULT 0,
            cache_read_tokens INTEGER DEFAULT 0,
            cache_write_5m_tokens INTEGER DEFAULT 0,
            cache_write_1h_tokens INTEGER DEFAULT 0,
            is_subagent INTEGER NOT NULL DEFAULT 0,
            parent_session_id TEXT,
            PRIMARY KEY (msg_id)
        );
        CREATE INDEX IF NOT EXISTS idx_calls_agent_ts ON calls(agent, ts_utc);
        CREATE INDEX IF NOT EXISTS idx_calls_ts ON calls(ts_utc);
        CREATE INDEX IF NOT EXISTS idx_calls_session ON calls(session_id);
        """
    )
    # Миграция базы старого формата: в ней строки только верхнего уровня,
    # поэтому дефолт 0 для них верен по построению.
    have = {r[1] for r in con.execute("PRAGMA table_info(calls)")}
    if "is_subagent" not in have:
        con.execute("ALTER TABLE calls ADD COLUMN is_subagent INTEGER NOT NULL DEFAULT 0")
        log.info("миграция: добавлена колонка is_subagent")
    if "parent_session_id" not in have:
        con.execute("ALTER TABLE calls ADD COLUMN parent_session_id TEXT")
        log.info("миграция: добавлена колонка parent_session_id")
    con.execute("CREATE INDEX IF NOT EXISTS idx_calls_subagent ON calls(is_subagent, ts_utc)")
    con.commit()


def agent_from_path(p: Path) -> str | None:
    """Agent of a .claude/projects/<dir> path (the dir itself is checked, by name)."""
    name = p.name
    for agent, prefix in AGENT_PREFIXES.items():
        if name == prefix or name.startswith(prefix + "-"):
            return agent
    if name == RICHARD_DIR:
        return "richard"
    return None


def iter_assistant_records(jsonl_path: Path, key_prefix: str = ""):
    """Yield (msg_id, session_id, ts, model, usage_dict) from assistant messages.

    Дедуп по msg_id делает БД (PRIMARY KEY). Если msg_id отсутствует — фолбэк-ключ
    строится из АДРЕСА ФАЙЛА (агент плюс путь внутри каталога проекта), сессии и
    времени. Адрес обязателен целиком: субагент наследует sessionId родителя,
    поэтому ключ sid+ts не различал бы ни двух субагентов одной сессии, ни субагента
    с родителем; одного лишь имени файла тоже мало — `agent-a.jsonl` встречается у
    разных агентов и в разных корнях, и записи схлопнулись бы молча через границу
    проекта. Записи без message.id на практике не встречаются.
    """
    try:
        with jsonl_path.open() as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if rec.get("type") != "assistant":
                    continue
                msg = rec.get("message") or {}
                usage = msg.get("usage") or {}
                if not usage:
                    continue
                ts = rec.get("timestamp")
                sid = rec.get("sessionId") or jsonl_path.stem
                msg_id = msg.get("id")
                if not msg_id:
                    msg_id = f"{key_prefix or jsonl_path.name}::{sid}::{ts}"
                if not ts:
                    continue
                yield msg_id, sid, ts, msg.get("model"), usage
    except FileNotFoundError:
        return


def subagent_context(jsonl_path: Path, project_dir: Path) -> tuple[bool, str | None]:
    """(является ли файл транскриптом субагента, id родительской сессии).

    Родитель — каталог НАД `subagents/`, то есть <project>/<parent-session>/subagents/x.jsonl.
    При вложенности глубже одного уровня берётся ближайший сверху, потому что расход
    субагента относится к тому, кто его позвал.
    """
    try:
        rel = jsonl_path.relative_to(project_dir)
    except ValueError:
        return False, None
    parts = rel.parts[:-1]
    if SUBAGENT_DIR not in parts:
        return False, None
    idx = len(parts) - 1 - parts[::-1].index(SUBAGENT_DIR)
    parent = parts[idx - 1] if idx >= 1 else None
    return True, parent


def upsert_call(con: sqlite3.Connection, row: tuple) -> bool:
    """UPSERT по msg_id. Returns True if a row was inserted or updated.

    Одна API-запись лежит в JSONL НЕСКОЛЬКИМИ строками с одним msg_id и одним
    requestId: сначала промежуточная, потом финальная, и output_tokens растёт;
    INSERT OR IGNORE брал бы ПЕРВУЮ строку и терял разницу.
    Побеждает строка с бо́льшим output: она же последняя по времени, а input/cache
    внутри группы не меняются. Сравнение по output,
    а не по порядку чтения, делает результат независимым от порядка обхода файлов.

    Признак субагента и родитель сливаются ОТДЕЛЬНО от токенов:
    один и тот же msg_id, встреченный и на верхнем уровне, и в subagents/, иначе
    получал бы классификацию по тому, какой файл прочитан последним. Пометка
    субагентом не снимается никогда (MAX), родитель, однажды узнанный, не затирается
    (COALESCE): результат не зависит от порядка чтения файлов.
    """
    cur = con.execute(
        """
        INSERT INTO calls(
            msg_id, session_id, ts_utc, agent, model,
            input_tokens, output_tokens,
            cache_read_tokens, cache_write_5m_tokens, cache_write_1h_tokens,
            is_subagent, parent_session_id
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(msg_id) DO UPDATE SET
            ts_utc = CASE WHEN excluded.output_tokens > calls.output_tokens
                          THEN excluded.ts_utc ELSE calls.ts_utc END,
            model = CASE WHEN excluded.output_tokens > calls.output_tokens
                         THEN excluded.model ELSE calls.model END,
            input_tokens = CASE WHEN excluded.output_tokens > calls.output_tokens
                                THEN excluded.input_tokens ELSE calls.input_tokens END,
            output_tokens = MAX(calls.output_tokens, excluded.output_tokens),
            cache_read_tokens = CASE WHEN excluded.output_tokens > calls.output_tokens
                                     THEN excluded.cache_read_tokens ELSE calls.cache_read_tokens END,
            cache_write_5m_tokens = CASE WHEN excluded.output_tokens > calls.output_tokens
                                         THEN excluded.cache_write_5m_tokens
                                         ELSE calls.cache_write_5m_tokens END,
            cache_write_1h_tokens = CASE WHEN excluded.output_tokens > calls.output_tokens
                                         THEN excluded.cache_write_1h_tokens
                                         ELSE calls.cache_write_1h_tokens END,
            is_subagent = MAX(calls.is_subagent, excluded.is_subagent),
            parent_session_id = COALESCE(calls.parent_session_id, excluded.parent_session_id)
        WHERE excluded.output_tokens > calls.output_tokens
           OR excluded.is_subagent > calls.is_subagent
           OR (calls.parent_session_id IS NULL AND excluded.parent_session_id IS NOT NULL)
        """,
        row,
    )
    return cur.rowcount > 0


def recent_cutoff(argv: list[str], now: float) -> float | None:
    """Порог mtime для --recent-minutes N (None — полный обход)."""
    if "--recent-minutes" not in argv:
        return None
    minutes = float(argv[argv.index("--recent-minutes") + 1])
    return now - minutes * 60


def main() -> int:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    cutoff = recent_cutoff(sys.argv[1:], time.time())
    # timeout: лёгкий шаг и часовой прогон могут писать одновременно, ждём замок, а не падаем
    con = sqlite3.connect(DB_PATH, timeout=60)
    try:
        init_db(con)

        roots = project_roots()
        if not roots:
            log.error("не найдено ни одного корня с сессиями")
            return 1
        log.info("корней с сессиями: %d", len(roots))

        total_new = 0
        total_scanned = 0
        files_scanned = 0
        sub_files = 0
        sub_new = 0

        for project_dir in (d for root in roots for d in root.iterdir()):
            if not project_dir.is_dir():
                continue
            agent = agent_from_path(project_dir)
            if not agent:
                continue
            for jsonl in sorted(project_dir.rglob("*.jsonl")):
                if cutoff is not None:
                    try:
                        if jsonl.stat().st_mtime < cutoff:
                            continue
                    except FileNotFoundError:
                        continue
                files_scanned += 1
                is_sub, parent_sid = subagent_context(jsonl, project_dir)
                if is_sub:
                    sub_files += 1
                file_new = 0
                try:
                    rel = jsonl.relative_to(project_dir).as_posix()
                except ValueError:
                    rel = jsonl.name
                for msg_id, sid, ts, model, usage in iter_assistant_records(
                        jsonl, key_prefix=f"{agent}/{rel}"):
                    total_scanned += 1
                    cache_create = usage.get("cache_creation") or {}
                    row = (
                        msg_id,
                        sid,
                        ts,
                        agent,
                        model,
                        int(usage.get("input_tokens") or 0),
                        int(usage.get("output_tokens") or 0),
                        int(usage.get("cache_read_input_tokens") or 0),
                        int(cache_create.get("ephemeral_5m_input_tokens") or 0),
                        int(cache_create.get("ephemeral_1h_input_tokens") or 0),
                        1 if is_sub else 0,
                        parent_sid,
                    )
                    if upsert_call(con, row):
                        file_new += 1
                if file_new:
                    log.info("agent=%s file=%s subagent=%d changed=%d",
                             agent, jsonl.name, 1 if is_sub else 0, file_new)
                total_new += file_new
                if is_sub:
                    sub_new += file_new
            con.commit()

        if not sub_files and cutoff is None:
            # Не авария: субагентов могло не быть вовсе. Но именно молчаливый ноль
            # здесь означал бы, что слепота вернулась, поэтому он назван вслух.
            log.info("транскриптов субагентов не найдено ни одного")
        log.info(
            # changed, а не new: одна API-запись лежит в JSONL несколькими строками,
            # поэтому на первом прогоне она даёт и вставку, и уточнение. Ноль здесь
            # означает «ничего не изменилось», и только это по нему и читается.
            "done files=%d (субагентских %d) scanned=%d changed=%d (субагентских %d) db=%s",
            files_scanned,
            sub_files,
            total_scanned,
            total_new,
            sub_new,
            DB_PATH,
        )
        return 0
    finally:
        con.close()


if __name__ == "__main__":
    sys.exit(main())
