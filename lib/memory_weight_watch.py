#!/usr/bin/env python3
"""Nightly guard: the always-loaded memory of every channel agent stays light (rule 5b).

handoff.md and decisions.md (journals, cap 15 KB), core/rules.md and CLAUDE.md (hand-written,
caps WEIGHT_RULES_KB / WEIGHT_CLAUDE_KB in guard.conf, default 30 and 40 KB) are re-read on
EVERY turn. The agent cleans them itself; this script only weighs and signals:

  - weighs each agent of guard.conf CHANNEL_AGENTS with include_weight.py;
  - an agent over a cap gets ONE webhook message per day (/hooks/agent, like agents-guard.py
    nudge), repeated next night while the file is still heavy; journals: closed items to
    core/archive, promises stay word for word; rules/CLAUDE.md: fold in the same turn,
    no owner rule is dropped;
  - the WHOLE turn (global CLAUDE.md and rules, CLAUDE.md of the ancestors, nested @-includes,
    the auto-memory MEMORY.md index; include_weight.turn_weight) over WEIGHT_TURN_KB (default
    100) is signalled like an over-cap rules file;
  - rules/CLAUDE.md/whole turn over the cap, or a failed delivery: one line per day into the
    guard outbox (outbox-put.py, ALERT_MODE in guard.conf) the same night;
  - morning (MORNING_HOUR of the owner's clock): agents found heavy tonight are weighed again;
    still heavy = one line per agent per day into the outbox, from the FIRST night on. The
    owner gets nothing from this script directly.

Cron: /etc/cron.d/<user>-memory-weight, root, hourly; --auto acts at AUTO_HOUR and MORNING_HOUR.
Stop: touch /var/lib/<user>-memory-weight/STOP
State: /var/lib/<user>-memory-weight/state.json   Exit 0 when the pass completed, 2 on usage.
"""
from __future__ import annotations

import fcntl
import importlib.util
import json
import logging
import os
import shutil
import subprocess
import sys
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Callable
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

LIB = Path(__file__).resolve().parent
sys.path.insert(0, str(LIB))
import guard_conf  # noqa: E402  (lives next to this script)

CONF = guard_conf.load()
LAB = CONF.lab
STATE_DIR = Path(os.environ.get("NEUROOTDEL_WEIGHT_STATE") or f"/var/lib/{CONF.agent_user}-memory-weight")
STATE_FILE = STATE_DIR / "state.json"
STOP_FILE = STATE_DIR / "STOP"
LOCK_FILE = STATE_DIR / ".lock"
OUTBOX_PUT = LIB / "outbox-put.py"
# agent -> its channel.env (webhook port/token) and the owner chat the wake is addressed to.
AGENTS: dict[str, dict[str, str]] = {
    a: {"env": str(CONF.channel_env(a)), "chat": CONF.owner_tg_id} for a in CONF.channel_agents
}
AUTO_HOUR = 4  # --auto (hourly cron): weigh only in this hour of the owner's clock, after the 04:00 reset
MORNING_HOUR = 10  # --auto from this hour on: re-weigh tonight's heavy agents until the line is delivered


def _kb(raw: dict[str, str], key: str, default: int) -> int:
    try:
        val = int(raw.get(key, "") or default)
    except ValueError:
        return default * 1024
    return (val if val > 0 else default) * 1024


# Rules and CLAUDE.md are not journals: they are written by hand and only fold, never get archived.
_RAW = guard_conf.read_raw()
STATIC_LIMITS: dict[str, int] = {
    "core/rules.md": _kb(_RAW, "WEIGHT_RULES_KB", 30),
    "CLAUDE.md": _kb(_RAW, "WEIGHT_CLAUDE_KB", 40),
}
# The whole turn as Claude Code loads it, not one file: signalled and reported like a static file.
TURN_KEY = "весь ход"
TURN_LIMIT = _kb(_RAW, "WEIGHT_TURN_KB", 100)
try:
    MSK = ZoneInfo(CONF.owner_timezone)  # the "day" of the once-a-day signal is the owner's day
except (ZoneInfoNotFoundError, ValueError):
    MSK = timezone(timedelta(hours=3))

log = logging.getLogger("memory_weight_watch")


def _load(name: str, file: str):
    spec = importlib.util.spec_from_file_location(name, LIB / file)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


iw = _load("include_weight", "include_weight.py")


WEIGH_TIMEOUT = 60
# Runs as the agent user: prints the rows of include_weight.weigh() as JSON. Root never opens the
# agent's files itself, so a symlink, FIFO or huge file the agent planted cannot hang or redirect it.
_WEIGH_CHILD = (
    "import importlib.util, json, sys\n"
    "s = importlib.util.spec_from_file_location('iw', sys.argv[1]); m = importlib.util.module_from_spec(s)\n"
    "sys.modules['iw'] = m; s.loader.exec_module(m)\n"
    "print(json.dumps([list(r) for r in m.weigh(__import__('pathlib').Path(sys.argv[2])).rows]))\n"
)


def weigh_rows(agent_dir: Path) -> list:
    """include_weight rows of one agent; as root the weighing runs as the agent user with a timeout."""
    if os.geteuid() != 0:
        return list(iw.weigh(agent_dir).rows)
    try:
        # timeout(1) kills the weigher itself: subprocess.run's own timeout reaches only runuser
        r = subprocess.run(["runuser", "-u", CONF.agent_user, "--", "timeout", "-s", "KILL",
                            str(WEIGH_TIMEOUT - 10), sys.executable, "-I", "-c", _WEIGH_CHILD,
                            str(LIB / "include_weight.py"), str(agent_dir)],
                           capture_output=True, text=True, timeout=WEIGH_TIMEOUT, cwd="/")
    except subprocess.TimeoutExpired as exc:
        raise OSError("weigh timeout") from exc
    if r.returncode != 0:
        raise OSError(f"weigh rc={r.returncode}")
    try:
        return [iw.Row(*row) for row in json.loads(r.stdout)]
    except (ValueError, TypeError) as exc:
        raise ValueError("weigh output") from exc


# Same isolation for the whole-turn weight: prints [total, own] of include_weight.turn_weight().
_TURN_CHILD = (
    "import importlib.util, json, sys\n"
    "from pathlib import Path\n"
    "s = importlib.util.spec_from_file_location('iw', sys.argv[1]); m = importlib.util.module_from_spec(s)\n"
    "sys.modules['iw'] = m; s.loader.exec_module(m)\n"
    "t = m.turn_weight(Path(sys.argv[2]), None, Path(sys.argv[3]), Path(sys.argv[4]))\n"
    "print(json.dumps([t.total, t.own]))\n"
)


def weigh_turn(agent_dir: Path) -> tuple[int, int]:
    """(total, own) bytes of the whole turn. The agents run with the default config dir ~/.claude."""
    home = CONF.agent_home
    if os.geteuid() != 0:
        t = iw.turn_weight(agent_dir, None, home / ".claude", home)
        return t.total, t.own
    try:
        r = subprocess.run(["runuser", "-u", CONF.agent_user, "--", "timeout", "-s", "KILL",
                            str(WEIGH_TIMEOUT - 10), sys.executable, "-I", "-c", _TURN_CHILD,
                            str(LIB / "include_weight.py"), str(agent_dir), str(home / ".claude"), str(home)],
                           capture_output=True, text=True, timeout=WEIGH_TIMEOUT, cwd="/")
    except subprocess.TimeoutExpired as exc:
        raise OSError("turn timeout") from exc
    if r.returncode != 0:
        raise OSError(f"turn rc={r.returncode}")
    try:
        total, own = json.loads(r.stdout)
        return int(total), int(own)
    except (ValueError, TypeError) as exc:
        raise ValueError("turn output") from exc


def heavy_turn(agent_dir: Path) -> list[tuple[int, str]]:
    total, _own = weigh_turn(agent_dir)
    return [(total, TURN_KEY)] if total > TURN_LIMIT else []


def heavy_journals(agent_dir: Path, rows: list | None = None) -> list[tuple[int, str]]:
    """Journal files loaded every turn and over the limit: [(bytes, name)]."""
    rows = weigh_rows(agent_dir) if rows is None else rows
    return [(r.size, r.name) for r in rows if r.journal and r.included and iw.over_limit(r)]


def static_name(name: str) -> str:
    """core/../core/rules.md and core/rules.md are the same file."""
    return os.path.normpath(name)


def heavy_static(agent_dir: Path, rows: list | None = None) -> list[tuple[int, str]]:
    """Rules and CLAUDE.md loaded every turn and over their own cap: [(bytes, name)]."""
    rows = weigh_rows(agent_dir) if rows is None else rows
    out: dict[str, int] = {}
    for r in rows:
        key = static_name(r.name)
        if not r.journal and r.included and key in STATIC_LIMITS and r.size > STATIC_LIMITS[key]:
            out[key] = max(out.get(key, 0), r.size)
    return [(size, key) for key, size in out.items()]


def limit_for(name: str) -> int:
    if name == TURN_KEY:
        return TURN_LIMIT
    return STATIC_LIMITS.get(static_name(name)) or iw.JOURNAL_LIMITS.get(name.split("/")[-1], iw.JOURNAL_LIMIT)


class StateError(Exception):
    """The state file exists but cannot be trusted: dedup is unknown, send nothing."""


def load_state(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise StateError(type(exc).__name__) from exc
    if not isinstance(data, dict):
        raise StateError("not a dict")
    for key, val in data.items():
        if key.startswith("_"):
            continue
        if not isinstance(val, dict):
            raise StateError(f"bad entry {key}")
        if any(f in val and not isinstance(val[f], t) for f, t in
               (("days", int), ("last_seen", str), ("notified", (str, type(None))), ("failed", str),
                ("delivered", (str, type(None))), ("static_reported", (str, type(None))),
               ("morning", (str, type(None))))):
            raise StateError(f"bad fields {key}")
    return data


def flush_report(report: list[str], old: dict, new: dict, today: str,
                 alert: Callable[[str, str], bool]) -> None:
    """Send to the outbox only lines not yet taken today; undelivered ones wait in _pending."""
    rep = old.get("_reported")
    if not (isinstance(rep, dict) and rep.get("date") == today and isinstance(rep.get("lines"), list)):
        rep = {"date": today, "lines": []}
    fresh = [l for l in dict.fromkeys(report) if l not in rep["lines"]]
    if fresh:
        sent = False
        try:
            sent = alert("memory-weight", "Вес памяти агентов (5b):\n" + "\n".join(fresh))
        except Exception as exc:  # noqa: BLE001 - the state must still be saved
            log.error("outbox: %s", type(exc).__name__)
        if sent:
            rep = {"date": today, "lines": rep["lines"] + fresh}
        else:
            new["_pending"] = fresh
    if rep["lines"]:
        new["_reported"] = rep


def save_state(path: Path, state: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(tmp, path)


def _file_line(size: int, name: str) -> str:
    if name == TURN_KEY:
        return (f"- весь ход (CLAUDE.md, все @ и вложенные, глобальные файлы, индекс MEMORY.md): "
                f"{size // 1024} КБ при потолке {TURN_LIMIT // 1024} КБ")
    return f"- .claude/{name}: {size // 1024} КБ при потолке {limit_for(name) // 1024} КБ"


def signal_text(heavy: list[tuple[int, str]], days: int) -> str:
    files = "\n".join(_file_line(size, name) for size, name in heavy)
    static = [name for _size, name in heavy if name == TURN_KEY or static_name(name) in STATIC_LIMITS]
    fold = ""
    if static:
        fold = (
            "\nПравила и CLAUDE.md тоже перечитываются каждым ходом. Сверни их В ЭТОМ ЖЕ ХОДЕ:\n"
            "- бэкап рядом, как в п.1 ниже;\n"
            "- повторы одного правила своди в одно место, длинные поводы и истории убирай в core/archive "
            "одной ссылкой;\n"
            "- редко нужное (справочники, разборы, процедуры) выноси в отдельный файл, который читается Read "
            "по нужде, а в правилах оставь строку со ссылкой на него;\n"
            "- смысл каждого правила сохраняется: ни одно правило владельца не удаляется и не ослабляется.\n"
        )
    return (
        f"[сторож памяти, правило 5b] Постоянная память тяжелее порога, ночь подряд: {days}.\n"
        f"{files}\n{fold}\n"
        "Эти файлы перечитываются КАЖДЫМ твоим ходом. Почисти сам, в этом же ходе:\n"
        "1. Бэкап рядом: cp -a <файл> <файл>.bak-<ГГГГММДД>-memory-5b\n"
        "2. Пройди КАЖДЫЙ пункт handoff и сверь с доской, логами и перепиской: задача правда закрыта "
        "или ещё открыта. Закрыта: закрой её и на доске, если висит.\n"
        "3. handoff.md = только ОТКРЫТОЕ: дело, блокер, обещание человеку или агенту. Закрытое переносить "
        "в core/archive, не удалять; в handoff не оставляй раздел «сделано».\n"
        "4. Закрытая задача оставляет в decisions.md одно решение в 2-4 строки: что решили, почему, ссылка.\n"
        "5. decisions.md держит окно 7 дней, старое в архив.\n"
        "6. Дневник, разборы, ход работы в холодный файл core/archive/ (читается Read по нужде).\n"
        "7. Блок «Last 15 actions (auto-generated)» не трогай, его пишет скрипт.\n"
        "8. Обещания и сроки не трогать: всё, что ты обещал людям и агентам (что, кому, к какому времени), "
        "остаётся в handoff дословно, со сроком.\n"
        f"9. Замер: python3 {LIB}/include_weight.py {LAB} "
        "(у тебя не должно быть ПРЕВЫШЕНИЕ).\n\n"
        "Владельцу про это не пиши, отчёт не нужен: сторож перевзвесит следующей ночью."
    )


def run(agents: list[str], lab: Path, state_path: Path, today: str,
        notify: Callable[[str, str], bool], alert: Callable[[str, str], bool]) -> list[str]:
    """One nightly pass. Returns report lines (also sent to the outbox once per day).

    At most one webhook ATTEMPT per agent per MSK day: the marker is saved before sending, so a
    timeout that the agent did receive is never repeated the same day; a failure retries next night.
    """
    try:
        old = load_state(state_path)
    except StateError as exc:
        bad = state_path.with_name(f"{state_path.name}.corrupt-{today}")
        shutil.copy2(state_path, bad)
        line = f"- состояние сторожа испорчено ({exc}), сохранено в {bad.name}; сигналы сегодня не слались"
        # attempt history unknown: block webhooks until tomorrow BEFORE anything else can fail
        save_state(state_path, {"_blocked": today, "_pending": [line]})
        new = {"_blocked": today}
        flush_report([line], {}, new, today, alert)
        save_state(state_path, new)
        return [line]
    blocked = old.get("_blocked") == today
    new: dict = {}
    pending = old.get("_pending") if isinstance(old.get("_pending"), list) else []
    report: list[str] = [l for l in pending if isinstance(l, str)]
    yesterday = (datetime.strptime(today, "%Y-%m-%d") - timedelta(days=1)).strftime("%Y-%m-%d")
    for agent in agents:
        agent_dir = lab / agent
        prev = old.get(agent) if isinstance(old.get(agent), dict) else {}
        if not (agent_dir / ".claude" / "CLAUDE.md").is_file():
            report.append(f"- {agent}: нет .claude/CLAUDE.md, память не взвешена")
            if prev:
                new[agent] = prev
            continue
        try:
            rows = weigh_rows(agent_dir)
            static = heavy_static(agent_dir, rows) + heavy_turn(agent_dir)
            journals = heavy_journals(agent_dir, rows)
            heavy = journals + static
        except (OSError, ValueError) as exc:
            report.append(f"- {agent}: память не взвешена ({type(exc).__name__})")
            if prev:
                new[agent] = prev  # keep the streak and the delivery marker untouched
            continue
        if not heavy:
            kept = {k: today for k in ("notified", "delivered", "static_reported", "morning")
                    if prev.get(k) == today}
            if kept:
                new[agent] = kept  # streak ends, the once-a-day markers still hold
            continue
        last_seen = prev.get("last_seen")
        days = prev.get("days") if isinstance(prev.get("days"), int) and prev.get("days", 0) > 0 else 0
        if not (last_seen == today and days > 0):  # second run the same day keeps the count
            days = days + 1 if last_seen == yesterday else 1
        if not journals:  # the escalation streak counts journal nights only
            days = 0
        entry = {"days": days, "last_seen": today, "notified": prev.get("notified"),
                 "delivered": prev.get("delivered"), "static_reported": prev.get("static_reported"),
                 "morning": prev.get("morning")}
        if prev.get("failed") == today:
            entry["failed"] = today
        sizes = ", ".join(f"{name.split('/')[-1]} {size // 1024} КБ" for size, name in heavy)
        if entry.get("notified") != today and not blocked:
            entry["notified"] = today  # attempt marker, persisted before the webhook
            save_state(state_path, {**old, **new, agent: entry})
            try:
                delivered = notify(agent, signal_text(heavy, days))
            except Exception as exc:  # noqa: BLE001 - one agent must not stop the pass
                log.error("notify %s: %s", agent, type(exc).__name__)
                delivered = False
            if delivered:
                entry["delivered"] = today
                log.info("signal %s delivered (%s)", agent, sizes)
            else:
                entry["failed"] = today
                report.append(f"- {agent}: сигнал о чистке памяти НЕ доставлен ({sizes}), повтор следующей ночью")
        if static and entry.get("static_reported") != today:  # rules: the lead hears it once a day
            entry["static_reported"] = today
            report.append(f"- {agent}: " + ", ".join(
                f"{name} {size // 1024} КБ при пороге {limit_for(name) // 1024} КБ" for size, name in static)
                + (", агенту ушёл сигнал свернуть" if entry.get("delivered") == today
                   else ", сигнал агенту НЕ ушёл"))
        new[agent] = entry
    if blocked:
        new["_blocked"] = today
    report = list(dict.fromkeys(report))
    flush_report(report, old, new, today, alert)
    save_state(state_path, new)
    return report


def morning(agents: list[str], lab: Path, state_path: Path, today: str,
            alert: Callable[[str, str], bool]) -> int:
    """Morning re-check of the agents found heavy tonight. Returns how many are still heavy.

    One line per agent per day into the outbox, from the first night on. The day's mark is saved
    only after the outbox took the message, so a failed send is retried by the next hourly run
    (the re-weigh is live: an agent that cleaned up in between is not reported). Returns -1 when
    the state cannot be trusted; that is said in the outbox once a day.
    """
    try:
        state = load_state(state_path)
    except StateError as exc:
        mark = state_path.with_name(f"morning-state-error-{today}")
        if not mark.exists():
            try:
                if alert("memory-weight-morning", f"- состояние сторожа памяти испорчено ({exc}), "
                                                  "утренний перезамер не выполнен"):
                    mark.touch()
            except Exception as err:  # noqa: BLE001
                log.error("outbox: %s", type(err).__name__)
        return -1
    lines: list[str] = []
    due: list[str] = []
    for agent in dict.fromkeys(agents):
        entry = state.get(agent)
        if not isinstance(entry, dict) or entry.get("last_seen") != today or entry.get("morning") == today:
            continue
        agent_dir = lab / agent
        try:
            rows = weigh_rows(agent_dir)
            heavy = heavy_journals(agent_dir, rows) + heavy_static(agent_dir, rows) + heavy_turn(agent_dir)
            what = ", ".join(f"{name.split('/')[-1]} {size // 1024} КБ" for size, name in heavy)
        except (OSError, ValueError) as exc:
            heavy, what = [(0, "")], f"не взвешена ({type(exc).__name__})"
        due.append(agent)
        if heavy:
            nights = entry.get("days") or 1
            lines.append(f"- {agent}: память не убрана после ночного сигнала, ночь {nights}: {what}")
    if lines:
        sent = False
        try:
            sent = alert("memory-weight-morning", "Вес памяти агентов (5b), утренний перезамер:\n" + "\n".join(lines))
        except Exception as exc:  # noqa: BLE001 - the state must stay consistent
            log.error("outbox: %s", type(exc).__name__)
        if not sent:
            return len(lines)
    for agent in due:
        state[agent]["morning"] = today
    save_state(state_path, state)
    return len(lines)


def env_value(env_file: str, key: str) -> str:
    with open(env_file, encoding="utf-8") as fh:
        for line in fh:
            if line.startswith(key + "="):
                return line.split("=", 1)[1].strip().strip('"')
    return ""


def webhook_notify(agent: str, text: str) -> bool:
    env, chat = AGENTS[agent]["env"], AGENTS[agent]["chat"]
    token, port = env_value(env, "TELEGRAM_WEBHOOK_TOKEN"), env_value(env, "TELEGRAM_WEBHOOK_PORT")
    if not token or not port.isdigit():
        return False
    req = urllib.request.Request(f"http://127.0.0.1:{port}/hooks/agent", method="POST",
                                 data=json.dumps({"message": text, "chatId": chat}).encode(),
                                 headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status == 200
    except OSError:
        return False


def outbox_alert(key: str, text: str) -> bool:
    r = subprocess.run([sys.executable, str(OUTBOX_PUT), key, text], capture_output=True, timeout=30)
    return r.returncode == 0


def _hour() -> int:
    return datetime.now(MSK).hour


def main(argv: list[str]) -> int:
    logging.basicConfig(level=logging.INFO, stream=sys.stderr,
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    if argv not in ([], ["--auto"], ["--morning"]):
        print("usage: memory_weight_watch.py [--auto|--morning]  (agents are in guard.conf; --auto: the night "
              f"pass in the {AUTO_HOUR:02d}:xx hour of the owner's clock, the morning re-check in "
              f"{MORNING_HOUR:02d}:xx)", file=sys.stderr)
        return 2
    is_morning = argv == ["--morning"]
    if argv == ["--auto"]:
        hour = _hour()
        if hour >= MORNING_HOUR:
            is_morning = True
        elif hour != AUTO_HOUR:
            return 0
    if STOP_FILE.exists():
        log.info("STOP file present, skipping")
        return 0
    today = datetime.now(MSK).strftime("%Y-%m-%d")
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    with open(LOCK_FILE, "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            log.info("another pass is running, skipping")
            return 0
        if is_morning:
            left = morning(list(AGENTS), LAB, STATE_FILE, today, outbox_alert)
            if left < 0:
                log.error("morning: state file cannot be trusted, re-check skipped")
                return 1
            log.info("morning: still heavy %d", left)
            return 0
        lines = run(list(AGENTS), LAB, STATE_FILE, today, webhook_notify, outbox_alert)
    for line in lines:
        print(line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
