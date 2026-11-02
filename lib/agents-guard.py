#!/usr/bin/env python3
"""Agents guard (installed by neurootdel-install). Settings: guard.conf next to this script.

Runs as root from /etc/cron.d/<user>-agents-guard once a minute. One tick:
  1. restart queue   /tmp/channel-restart-request (agents write "<agent>|richard|all"):
                     one restart per tick, richard last, waits for the end of a turn up to
                     QUEUE_MAX_WAIT, always with the quiet marker (no resume-nudge, so the
                     agent never re-sends an answered message).
  2. stall           permission question held >= 3 ticks (alert, never pressed);
                     long turn frozen (>= 20 min, token counter still for 10 ticks) -> restart.
  3. login           "Not logged in / Please run /login" in a failed tool line -> restart
                     (session re-reads ~/.claude/.credentials.json), max 2 per 6 h, then alert
                     "needs /login by a human".
  4. limit + usage   bottom banner "Usage limit reached / Continuing automatically at T" and
                     "used N% of your ... limit" (80/95). One alert per limit period.
  5. owner unanswered  the owner (guard.conf OWNER_TG_ID) in DM to a channel agent, no reply
                     > 15 min: agent nudged through its webhook (max 2 per message) + alert.
                     While the agent is on the limit: ONE Bot-API answer per limit period
                     instead ("Я на перерыве до ..., продолжу с места.").
  4a. limit notice   the moment the screen shows the usage-limit pause, ONE Bot-API line to the
                     owner «На лимите до HH:MM» from THIS agent's bot, without the model. One line
                     per bot per window (limit_notice_periods[agent]); a part-5 answer from the same
                     bot in that window counts as its line. The main agent speaks for all of them;
                     any other agent's bot writes only while the owner's DM to it waits for an answer.
  5a. restart check  after a start of the unit (any cause), once the session is up and idle,
                     private chats whose last human messages came after the agent's last reply get
                     ONE webhook nudge carrying those texts (restart_unanswered.py). Start identity =
                     systemd InvocationID. Once per start and once per message (A, then A+B hands
                     over only B); the owner nudge of part 5 waits until this check is done.
  6. auditor         only when a hermes-auditor unit exists on this server.
Alerts never go to the owner's chat by default: ALERT_MODE in guard.conf decides.
  outbox   (default) JSON items in STATE/outbox (--drain prints them, --ack ID deletes) + the log;
  telegram           the same, and each alert is also sent by the Richard bot to ALERT_TG_CHAT_ID
                     (default: the owner);
  log                only the log file.

Stops: touch STATE/STOP (all), STATE/AUTOREPLY_OFF (only the limit answer),
       STATE/LIMIT_NOTICE_OFF (only the limit notice of part 4a),
       STATE/RESTART_CHECK_OFF (only the restart check of part 5a),
       STATE/QUEUE_OFF (only the restart queue).
Modes: --dry-run (nothing sent, restarted, nudged or written; prints decisions),
       --drain (prints outbox as JSON), --ack ID... (deletes delivered items),
       --test-alert (writes ONE "[ТЕСТ]" alert through the configured route).
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import importlib.util
import json
import logging
import os
import re
import resource
import shutil
import signal
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

sys.path.insert(0, str(Path(__file__).resolve().parent))
import guard_conf  # noqa: E402  (lives next to this script)

log = logging.getLogger("agents-guard")

UTC = timezone.utc
MSK = timezone(timedelta(hours=3))
CONF = guard_conf.load()
USER = CONF.agent_user
HOME = CONF.agent_home
LIB = Path(__file__).resolve().parent
STATE_DIR = Path(os.environ.get("NEUROOTDEL_GUARD_STATE") or f"/var/lib/{USER}-guard")  # env: tests
OUTBOX = STATE_DIR / "outbox"
STATE_FILE = STATE_DIR / "state.json"
LOG_FILE = Path(f"/var/log/{USER}-guard.log")
QUEUE_FILE = Path("/tmp/channel-restart-request")
QUIET_DIR = HOME / ".claude-lab/shared/state/quiet-restart"
CRED_FILE = HOME / ".claude/.credentials.json"
PROJECTS = HOME / ".claude/projects"
JUDGE = LIB / "dashi_watchdog_unanswered.py"
RESTART_MOD = LIB / "restart_unanswered.py"
OWNER_CHAT = CONF.owner_tg_id
OWNER = CONF.owner_name or "владелец"

AGENTS: dict[str, dict] = {
    a: {"unit": f"channel-{a}", "tmux": f"channel-{a}", "name": CONF.label(a),
        "env": str(CONF.channel_env(a)), "owner_dm": bool(OWNER_CHAT),
        "restart_check": True, "limit_notice": bool(OWNER_CHAT),
        # the main agent speaks for the whole account; the others only while a DM to them waits
        "limit_notice_needs_dm": a != CONF.main_agent}
    for a in CONF.channel_agents
}
RICHARD_UNIT = CONF.richard_unit
if RICHARD_UNIT and Path(f"/etc/systemd/system/{RICHARD_UNIT}.service").exists():
    AGENTS["richard"] = {"unit": RICHARD_UNIT, "tmux": None, "name": "Richard", "env": None, "owner_dm": False}
QUEUE_ORDER = [a for a in AGENTS if a != "richard"] + (["richard"] if "richard" in AGENTS else [])  # richard last
AUDITOR_UNITS = tuple(u for u in ("hermes-auditor", "hermes-auditor-swarm-bridge")
                      if Path(f"/etc/systemd/system/{u}.service").exists())
AUDITOR_STATE = HOME / ".hermes/gateway_state.json"
AUDITOR_DB = HOME / ".hermes/state.db"

QUEUE_MAX_WAIT = 600
QUESTION_TICKS = 3
LONG_TURN_MIN = 1200
LONG_TURN_STALE_TICKS = 10
UNANSWERED_SEC = 900
NUDGE_GAP_SEC = 900
NUDGE_MAX = 2
AUTO_RESTART_COOLDOWN = 1800
LOGIN_RESTARTS_PER_6H = 2
AUDITOR_HEARTBEAT_MAX = 600
AUDITOR_ANSWER_SEC = 1200
USAGE_THRESHOLDS = (80, 95)
JSONL_CAP = 300 << 20
RC_MIN_UPTIME = 60       # let the plugin deliver updates queued during the downtime first
RC_MAX_AGE = 6 * 3600   # keeps waiting for an idle session this long, then gives up with an alert
RC_WINDOW = 86400        # messages older than a day are left to the humans
RC_LABELS = {OWNER_CHAT: "личка владельца"} if OWNER_CHAT else {}
# ready TUI: the start screen shows "? for shortcuts", after a turn the footer is the mode line
# ("bypass permissions on (shift+tab to cycle)") under an empty "❯" prompt
_READY = re.compile(r"for shortcuts|for agents|shift\+tab to cycle|^\s*❯", re.M)

_TURN = re.compile(r"\((?:(\d+)h\s+)?(?:(\d+)m\s+)?(\d+)s\s*·([^)]*)\)")
_TOKENS = re.compile(r"([0-9]+(?:\.[0-9]+)?)\s*([kmKM]?)\s*tokens")
_LOGIN = re.compile(r"⎿.*(Not logged in|Please run /login|OAuth token has expired|"
                    r"authentication_error|Invalid API key)")
_BANNER = re.compile(r"Usage limit reached|Continuing automatically at|hit your (?:session|weekly) limit")
_CLOCK = re.compile(r"(?:(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s+(\d{1,2}),?\s+)?"
                    r"(\d{1,2})(?::(\d{2}))?\s*(am|pm)", re.I)
_USAGE = re.compile(r"used (\d{1,3})% of your (weekly|session) limit", re.I)
_MONTHS = "jan feb mar apr may jun jul aug sep oct nov dec".split()


# ---------- helpers ----------

def safe_read(path: Path, cap: int = 2 << 20) -> str:
    """Read a file the agent user controls: no symlink, no FIFO/device (root must not hang), size cap."""
    fd = open_regular(path)
    try:
        return os.read(fd, cap).decode("utf-8", "replace")
    finally:
        os.close(fd)


def open_regular(path: Path) -> int:
    """fd of a regular file reached without any symlink on the way (final or parent).

    Walks the path component by component through directory fds with O_NOFOLLOW, so a parent
    swapped for a symlink between checks cannot redirect root (Codex r3).
    """
    parts = Path(path).parts
    if not parts or parts[0] != "/" or ".." in parts:
        raise OSError("absolute path without '..' required")
    dfd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for comp in parts[1:-1]:
            nfd = os.open(comp, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=dfd)
            os.close(dfd)
            dfd = nfd
        fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dfd)
    finally:
        os.close(dfd)
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        raise OSError(f"not a regular file: {path.name}")
    return fd


def name_of(agent: str) -> str:
    return AGENTS.get(agent, {}).get("name", agent)


def run(cmd: list[str], timeout: int = 30) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, check=False)


def unit_active(unit: str) -> bool:
    return run(["systemctl", "is-active", "--quiet", unit]).returncode == 0


def unit_since(unit: str) -> float:
    r = run(["systemctl", "show", unit, "-p", "ActiveEnterTimestampMonotonic", "--value"])
    try:
        mono = int(r.stdout.strip()) / 1e6
    except ValueError:
        return 0.0
    return time.time() - (time.monotonic() - mono) if mono else 0.0


def capture(agent: str, overrides: dict[str, str]) -> str | None:
    if agent in overrides:
        return Path(overrides[agent]).read_text(encoding="utf-8")
    sess = AGENTS[agent]["tmux"]
    if not sess:
        return None
    r = run(["runuser", "-u", USER, "--", "tmux", "-L", sess, "capture-pane", "-t", sess, "-p"], 15)
    return r.stdout if r.returncode == 0 and r.stdout.strip() else None


def tail_lines(pane: str, n: int) -> list[str]:
    return [ln for ln in pane.splitlines() if ln.strip()][-n:]


def is_busy(pane: str | None) -> bool:
    return pane is None or bool(re.search(r"esc to interrupt|Continuing automatically", pane, re.I))


def turn_state(pane: str) -> tuple[int, int, bool] | None:
    tail = "\n".join(tail_lines(pane, 12))
    ms = list(_TURN.finditer(tail))
    if not ms or "esc to interrupt" not in tail:
        return None
    m = ms[-1]
    secs = int(m.group(1) or 0) * 3600 + int(m.group(2) or 0) * 60 + int(m.group(3))
    t = _TOKENS.search(m.group(4))
    if not t:
        return secs, 0, False
    val = float(t.group(1)) * {"k": 1e3, "m": 1e6}.get(t.group(2).lower(), 1)
    return secs, int(val), True


def question(pane: str) -> str | None:
    tail = "\n".join(tail_lines(pane, 25))
    if "Do you want to proceed?" in tail or ("Enter to select" in tail and "Esc to cancel" in tail):
        return hashlib.sha256(tail.encode()).hexdigest()[:16]
    return None


def parse_clock(text: str, now: datetime) -> tuple[datetime, bool] | None:
    m = _CLOCK.search(text)
    if not m:
        return None
    hour = int(m.group(3)) % 12 + (12 if m.group(5).lower() == "pm" else 0)
    minute = int(m.group(4) or 0)
    if hour > 23 or minute > 59:
        return None
    if m.group(1):
        month = _MONTHS.index(m.group(1)[:3].lower()) + 1
        try:
            dt = datetime(now.year, month, int(m.group(2)), hour, minute, tzinfo=UTC)
        except ValueError:
            return None
        if dt < now - timedelta(days=2):
            dt = dt.replace(year=now.year + 1)
        return dt, True
    dt = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
    if dt < now - timedelta(minutes=10):
        dt += timedelta(days=1)
    return dt, False


def limit_state(pane: str | None, now: datetime) -> tuple[datetime | None, bool] | None:
    """(reset UTC or None, reliable) when the CURRENT screen is in a usage-limit pause, else None.

    reliable=False forbids the answer to the owner: time unreadable, or a date-less time
    more than 6 h ahead (a session window is 5 h; such a value means a stale banner).

    Only the bottom status area counts: a "resets 12:10pm" line left in the scrollback
    after the pause ended would otherwise roll to tomorrow and fake a limit.
    The server clock is UTC and Claude Code prints the pane times in it ("(UTC)").
    """
    if not pane:
        return None
    bottom = "\n".join(tail_lines(pane, 8))
    if not re.search(r"Usage limit reached|Continuing automatically at", bottom):
        return None
    got = None
    for pat in (r"Continuing automatically at ([^·\n]+)", r"limit resets ([^·\n]+)"):
        m = re.search(pat, bottom)
        if m and (got := parse_clock(m.group(1), now)):
            break
    if not got:
        return None, False
    dt, dated = got
    return dt, dated or dt <= now + timedelta(hours=6)


def usage_pct(pane: str | None) -> tuple[int, str] | None:
    if not pane:
        return None
    found = _USAGE.findall("\n".join(tail_lines(pane, 10)))
    return (int(found[-1][0]), found[-1][1].lower()) if found else None


def login_broken(pane: str | None) -> bool:
    return bool(pane) and any(_LOGIN.search(ln) for ln in tail_lines(pane, 30))


def cred_has_refresh() -> bool:
    try:
        d = json.loads(safe_read(CRED_FILE)).get("claudeAiOauth") or {}
    except (OSError, ValueError):
        return False
    return bool(d.get("refreshToken"))


def env_value(env_file: str, key: str) -> str:
    with open(env_file, encoding="utf-8") as fh:
        for line in fh:
            if line.startswith(key + "="):
                return line.split("=", 1)[1].strip().strip('"')
    return ""


def fmt_msk(dt: datetime) -> str:
    return dt.astimezone(MSK).strftime("%H:%M")


def owner_zone() -> tuple[ZoneInfo | None, str]:
    """The owner's zone from guard.conf OWNER_TIMEZONE; None when it is Moscow time already."""
    try:
        tz = ZoneInfo(CONF.owner_timezone)
    except (ZoneInfoNotFoundError, ValueError):
        return None, ""
    if datetime.now(tz).utcoffset() == timedelta(hours=3):
        return None, ""
    return tz, "по вашему времени"


def limit_text(reset: datetime) -> str:
    tz, label = owner_zone()
    if tz is None:
        return f"Я на перерыве до {fmt_msk(reset)} мск, продолжу с места."
    return f"Я на перерыве до {reset.astimezone(tz):%H:%M} {label} ({fmt_msk(reset)} мск), продолжу с места."


def limit_notice_text(reset: datetime, agent: str) -> str:
    """Part 4a line: the main agent speaks for every agent of the account."""
    tz, label = owner_zone()
    t = f"{fmt_msk(reset)} мск" if tz is None else f"{reset.astimezone(tz):%H:%M} {label}"
    if agent == CONF.main_agent and len([a for a in AGENTS if a != "richard"]) > 1:
        return f"Мы на лимите до {t}, ответим после."
    return f"На лимите до {t}, отвечу после."


# ---------- owner unanswered (our judge, filtered for this CC version) ----------

def _load_judge():
    spec = importlib.util.spec_from_file_location("dwu", JUDGE)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    orig_human, orig_failed = mod._human_chat, mod._failed_tool_ids

    def human(entry: dict) -> str | None:  # only the owner's DM opens a wait
        chat = orig_human(entry)
        return chat if chat == OWNER_CHAT else None

    def failed(entry: dict) -> list[str]:  # api-request-blob = copy of the request, no timestamp
        return [] if entry.get("type") == "api-request-blob" else orig_failed(entry)

    mod._human_chat, mod._failed_tool_ids = human, failed
    return mod


def owner_wait(agent: str, now: datetime, override: str | None = None) -> tuple[str, int, str]:
    """(verdict, silent_sec, last_human_iso) for the owner's DM to this agent."""
    if override:
        verdict, line = _load_judge().judge([Path(override)], now)
        m = re.search(r"silent_sec=(\d+) last_human=(\S+)", line)
        return verdict, int(m.group(1)) if m else 0, m.group(2) if m else ""
    fds: list[int] = []
    try:
        total = 0
        for p in PROJECTS.glob(f"{CONF.project_prefix(agent)}-dashi-plugin-claude-code*/*.jsonl"):
            fd = open_regular(p)  # symlink/FIFO anywhere: OSError -> unknown, do not judge at all
            fds.append(fd)
            st = os.fstat(fd)
            if now.timestamp() - st.st_mtime >= 3 * 86400:
                os.close(fds.pop())
                continue
            total += st.st_size
        if not fds or total > JSONL_CAP:
            return "unknown", 0, ""
        # the judge reopens through /proc/self/fd: the very inode checked above, no swap window
        verdict, line = _load_judge().judge([Path(f"/proc/self/fd/{fd}") for fd in fds], now)
    except OSError:
        return "unknown", 0, ""
    finally:
        for fd in fds:
            os.close(fd)
    m = re.search(r"silent_sec=(\d+) last_human=(\S+)", line)
    return verdict, int(m.group(1)) if m else 0, m.group(2) if m else ""


def agent_fds(agent: str, now: datetime) -> list[int] | None:
    """Open fds of the agent's transcripts touched in the last 3 days; None = do not judge."""
    fds: list[int] = []
    try:
        total = 0
        for p in PROJECTS.glob(f"{CONF.project_prefix(agent)}-dashi-plugin-claude-code*/*.jsonl"):
            fd = open_regular(p)
            fds.append(fd)
            st = os.fstat(fd)
            if now.timestamp() - st.st_mtime >= 3 * 86400:
                os.close(fds.pop())
                continue
            total += st.st_size
    except OSError:
        for fd in fds:
            os.close(fd)
        return None
    if not fds or total > JSONL_CAP:
        for fd in fds:
            os.close(fd)
        return None
    return fds


def unit_start(unit: str) -> tuple[str, float, float]:
    """(InvocationID, wall-clock ActiveEnter, wall-clock ExecMainStart), ONE systemctl call.

    ActiveEnter (after ExecStartPost, i.e. the channel is up) drives the uptime wait;
    ExecMainStart (the new process started, the old one already killed) is the boundary
    between the old and the new session in the transcripts."""
    out = run(["systemctl", "show", unit, "-p", "InvocationID", "-p", "ActiveEnterTimestampMonotonic",
               "-p", "ExecMainStartTimestampMonotonic"]).stdout
    kv = dict(ln.split("=", 1) for ln in out.splitlines() if "=" in ln)

    def wall(key: str) -> float:
        try:
            mono = int(kv.get(key, "0")) / 1e6
        except ValueError:
            return 0.0
        return time.time() - (time.monotonic() - mono) if mono else 0.0
    return (kv.get("InvocationID", "").strip(), wall("ActiveEnterTimestampMonotonic"),
            wall("ExecMainStartTimestampMonotonic"))


def transcript_sig(agent: str, override: str | None = None) -> tuple:
    """Size and mtime of every transcript: any append between two calls changes it."""
    paths = [Path(override)] if override else sorted(
        PROJECTS.glob(f"{CONF.project_prefix(agent)}-dashi-plugin-claude-code*/*.jsonl"))
    sig = []
    for p in paths:
        try:
            st = p.lstat()
        except OSError:
            continue
        sig.append((str(p), st.st_size, st.st_mtime_ns))
    return tuple(sig)


def restart_pending(agent: str, started: datetime, now: datetime, override: str | None = None,
                    handed: set[str] | None = None):
    """Pending private chats after a restart (restart_unanswered.Pending list) or None."""
    spec = importlib.util.spec_from_file_location("restart_unanswered", RESTART_MOD)
    ru = importlib.util.module_from_spec(spec)
    sys.modules["restart_unanswered"] = ru  # dataclasses resolve their module through sys.modules
    spec.loader.exec_module(ru)
    judge = ru.load_judge(JUDGE)
    chats = ru.private_chats(env_value(AGENTS[agent]["env"], "TELEGRAM_ALLOWED_CHAT_IDS")
                             if AGENTS[agent]["env"] else "")
    if override:
        return ru, ru.pending_after_restart(judge, [Path(override)], started, now, chats, RC_WINDOW,
                                            handed or set())
    fds = agent_fds(agent, now)
    if fds is None:
        return ru, None
    try:
        return ru, ru.pending_after_restart(judge, [Path(f"/proc/self/fd/{fd}") for fd in fds],
                                            started, now, chats, RC_WINDOW, handed or set())
    finally:
        for fd in fds:
            os.close(fd)


# ---------- actions ----------

class Guard:
    def __init__(self, dry: bool, overrides: dict[str, str], jsonl: dict[str, str] | None = None) -> None:
        self.dry, self.ov, self.jsonl = dry, overrides, jsonl or {}
        self.now = datetime.now(UTC)
        self.state: dict = {}
        self.restarted: set[str] = set()
        self.failed = False          # a check raised: do not re-arm keys this tick
        self.no_autoreply = False    # state was unreadable: dedup unknown, no answer to the owner
        self.sfile = STATE_FILE
        self.persist = not dry

    def save(self) -> None:
        if not self.persist:
            return
        fd, tmp = tempfile.mkstemp(dir=self.sfile.parent)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(self.state, fh, ensure_ascii=False)
        os.replace(tmp, self.sfile)

    def say(self, msg: str) -> None:
        log.info(msg)

    def alert(self, key: str, text: str, test: bool = False) -> None:
        """One outbox item per open condition key; the key re-arms when the condition clears."""
        self.state.setdefault("open", {})
        self.seen.add(key)
        if key in self.state["open"] and not test:
            return
        item = {"id": f"{int(time.time() * 1000)}-{hashlib.sha256(key.encode()).hexdigest()[:8]}",
                "at_msk": f"{datetime.now(MSK):%d.%m %H:%M} МСК", "key": key,
                "text": ("[ТЕСТ] " if test else "") + text}
        if self.dry:
            self.say(f"[dry] ALERT {key}: {item['text']}")
            self.state["open"][key] = int(time.time())
            return
        self.say(f"ALERT {key}: {item['text']}")
        if CONF.alert_mode != "log":
            OUTBOX.mkdir(parents=True, exist_ok=True, mode=0o700)
            tmp = OUTBOX / f".{item['id']}.tmp"
            tmp.write_text(json.dumps(item, ensure_ascii=False), encoding="utf-8")
            tmp.rename(OUTBOX / f"{item['id']}.json")
        self.state["open"][key] = int(time.time())  # only once the item is really published
        self.save()  # dedup key durable right after the item (a crash later must not repeat it)
        if CONF.alert_mode == "telegram":
            ok = self.alert_telegram(f"[сторож {item['at_msk']}] {item['text']}")
            self.say(f"ALERT telegram ok={ok}")

    def alert_telegram(self, text: str) -> bool:
        """Alert through the Richard bot (token from guard.conf RICHARD_ENV) to ALERT_TG_CHAT_ID / owner."""
        chat = CONF.alert_tg_chat_id or OWNER_CHAT
        if not chat or not CONF.richard_env:
            return False
        try:
            token = env_value(CONF.richard_env, "TELEGRAM_BOT_TOKEN")
        except OSError:
            return False
        if not token:
            return False
        data = urllib.parse.urlencode({"chat_id": chat, "text": text[:4000]}).encode()
        try:
            with urllib.request.urlopen(f"https://api.telegram.org/bot{token}/sendMessage", data=data,
                                        timeout=20) as resp:
                return json.loads(resp.read()).get("ok") is True
        except (OSError, ValueError):
            return False

    def restart(self, agent: str, why: str) -> bool | None:
        """True = up, False = restart failed, None = deferred (nothing was restarted)."""
        a = AGENTS[agent]
        if self.dry:
            self.say(f"[dry] RESTART {a['unit']} (quiet) — {why}")
            self.restarted.add(agent)
            return True
        if a["tmux"]:
            # The marker is written BY the agent user (channel-confirm.sh runs as the agent and
            # deletes it); without it the restart would nudge the agent into a repeat answer.
            mk = run(["runuser", "-u", USER, "--", "sh", "-c", 'mkdir -p "$1" && date +%s > "$1/$2"', "_",
                      str(QUIET_DIR), a["unit"]])
            if mk.returncode != 0:
                self.say(f"RESTART {a['unit']} skipped: quiet marker not written — {why}")
                self.alert(f"quietfail:{agent}", f"{name_of(agent)}: перезапуск отложен, тихий маркер не записан ({QUIET_DIR}).")
                return None
        r = run(["systemctl", "restart", a["unit"]], 120)
        ok = r.returncode == 0
        for _ in range(18):
            if ok and unit_active(a["unit"]):
                break
            time.sleep(5)
        ok = ok and unit_active(a["unit"])
        if not ok and a["tmux"]:
            (QUIET_DIR / a["unit"]).unlink(missing_ok=True)
        self.say(f"RESTART {a['unit']} ok={ok} — {why}")
        self.restarted.add(agent)
        self.state.setdefault("restarts", {}).setdefault(agent, []).append(int(time.time()))
        return ok

    def recent_restarts(self, agent: str, window: int) -> list[int]:
        lst = [t for t in self.state.get("restarts", {}).get(agent, []) if time.time() - t < 6 * 3600]
        self.state.setdefault("restarts", {})[agent] = lst
        return [t for t in lst if time.time() - t < window]

    def nudge(self, agent: str, text: str, chat: str = OWNER_CHAT) -> bool:
        env = AGENTS[agent]["env"]
        if self.dry:
            self.say(f"[dry] NUDGE {agent} webhook chatId={chat}: {text[:120]}…")
            return True
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

    def bot_send(self, agent: str, text: str) -> bool:
        if self.dry:
            self.say(f"[dry] BOT {agent} sendMessage chat_id={OWNER_CHAT} text=«{text}»")
            return True
        token = env_value(AGENTS[agent]["env"], "TELEGRAM_BOT_TOKEN")
        if not token:
            return False
        data = urllib.parse.urlencode({"chat_id": OWNER_CHAT, "text": text}).encode()
        try:
            with urllib.request.urlopen(f"https://api.telegram.org/bot{token}/sendMessage", data=data,
                                        timeout=20) as resp:
                return json.loads(resp.read()).get("ok") is True
        except (OSError, ValueError):
            return False

    # ---------- tick parts ----------

    def do_queue(self, panes: dict[str, str | None]) -> None:
        pend: dict = self.state.setdefault("queue", {})
        claim = QUEUE_FILE.with_name(".channel-restart-request.claim-root")
        if os.path.lexists(claim) or os.path.lexists(QUEUE_FILE):
            src = QUEUE_FILE
            if not self.dry:  # claim by rename (same /tmp): a request written after this lands in a new file
                src = claim
                if not os.path.lexists(claim):  # a claim left by a crashed tick is read first, not lost
                    os.rename(QUEUE_FILE, claim)
            try:
                want = safe_read(src, 4096).split()
            except OSError:
                want = []
            names = QUEUE_ORDER if "all" in want else want
            for n in names:
                if n in AGENTS:
                    pend.setdefault(n, int(time.time()))
                else:
                    self.say(f"QUEUE skip unknown '{n[:40]}'")
            self.save()  # accepted requests are durable before the claim file goes
            if not self.dry:
                src.unlink(missing_ok=True)
        for agent in QUEUE_ORDER:  # one restart per tick, richard last
            if agent not in pend:
                continue
            waited = time.time() - pend[agent]
            if AGENTS[agent]["tmux"] and is_busy(panes.get(agent)) and waited < QUEUE_MAX_WAIT:
                self.say(f"QUEUE {agent}: busy, waiting ({int(waited)} s)")
                return
            ok = self.restart(agent, f"очередь, ждал {int(waited)} с")
            if ok is None:  # deferred: the request stays queued, no attempt is spent
                self.save()
                return
            tries = self.state.setdefault("queue_tries", {})
            tries[agent] = tries.get(agent, 0) + 1
            if ok or tries[agent] >= 2:
                del pend[agent]
                tries.pop(agent, None)
                self.alert(f"queue:{agent}:{int(time.time())}",
                           f"{AGENTS[agent]['name']}: перезапуск по очереди {'прошёл' if ok else 'НЕ поднялся (2 попытки)'}.")
            self.save()
            return

    def do_agent(self, agent: str, pane: str | None) -> datetime | None:
        a, name = AGENTS[agent], AGENTS[agent]["name"]
        if not unit_active(a["unit"]):
            self.alert(f"down:{agent}", f"{name}: служба {a['unit']} не активна (systemd поднимает сам, проверьте).")
            return None
        young = time.time() - unit_since(a["unit"]) < 120
        if a["tmux"] and pane is None and not young:
            self.alert(f"nopane:{agent}", f"{name}: служба жива, а панель tmux не читается.")
            return None
        if agent == "richard":
            pane = run(["journalctl", "-u", a["unit"], "--since", "-10min", "--no-pager", "-o", "cat"]).stdout
            if re.search(r"Not logged in|Please run /login|OAuth token has expired", pane):
                self.alert(f"login:{agent}", f"{name}: в журнале «нужен вход в Claude». Нужен /login под {USER}.")
            if re.search(r"hit your (session|weekly) limit|Usage limit reached", pane, re.I):
                self.alert(f"limit:{agent}", f"{name}: в журнале «лимит Claude».")
            return None
        st = self.state.setdefault("agents", {}).setdefault(agent, {})
        # login
        if login_broken(pane) and not young:
            if not cred_has_refresh():
                self.alert(f"login:{agent}", f"{name}: вход в Claude слетел, в ключе нет refresh. Нужен /login под {USER}.")
            elif len(self.recent_restarts(agent, 6 * 3600)) >= LOGIN_RESTARTS_PER_6H:
                self.alert(f"login:{agent}", f"{name}: вход в Claude слетел, два перезапуска за 6 ч не помогли. Нужен /login под {USER}.")
            elif not self.recent_restarts(agent, AUTO_RESTART_COOLDOWN):
                ok = self.restart(agent, "Not logged in")
                self.alert(f"loginheal:{agent}:{int(time.time()) // 3600}",
                           f"{name}: «Not logged in» в панели, перезапустил, сессия перечитает ключ ({'поднялся' if ok else 'НЕ поднялся'}).")
            return None
        # permission question
        q = question(pane) if pane else None
        if q:
            st["q"], st["qn"] = q, (st.get("qn", 0) + 1 if st.get("q") == q else 1)
            if st["qn"] >= QUESTION_TICKS:
                self.alert(f"question:{agent}:{q}", f"{name}: висит на вопросе разрешения {st['qn']} мин, ход стоит. Сторож не нажимает, нужен человек.")
        else:
            st.pop("q", None), st.pop("qn", None)
        # frozen long turn
        ts = turn_state(pane) if pane else None
        if ts and ts[2] and ts[0] >= LONG_TURN_MIN:
            prev = st.get("turn") or [0, 0, 0]
            stale = 0 if (ts[0] < prev[1] or ts[1] != prev[0]) else prev[2] + 1
            st["turn"] = [ts[1], ts[0], stale]
            if stale >= LONG_TURN_STALE_TICKS and not self.recent_restarts(agent, AUTO_RESTART_COOLDOWN):
                ok = self.restart(agent, f"ход {ts[0] // 60} мин без прогресса токенов")
                st.pop("turn", None)
                self.alert(f"frozen:{agent}:{int(time.time()) // 60}",
                           f"{name}: ход завис ({ts[0] // 60} мин, токены стоят {stale} мин), перезапустил ({'поднялся' if ok else 'НЕ поднялся'}).")
                return None
        else:
            st.pop("turn", None)
        # limit and usage
        lim = limit_state(pane, self.now)
        if lim:
            reset = lim[0]
            if reset and lim[1]:
                self.alert(f"limit:{reset:%Y%m%d%H%M}", f"Аккаунт Claude на лимите до {fmt_msk(reset)} МСК (по панели агента {name}).")
            else:
                self.alert(f"limit:unknown:{agent}", f"{name}: на лимите Claude, время сброса не прочитано (автоответ владельцу не шлю).")
        up = usage_pct(pane)
        if up:
            for th in USAGE_THRESHOLDS:
                if up[0] >= th:
                    self.alert(f"usage:{up[1]}:{th}:{self.now:%Y%m%d}",
                               f"Расход Claude: {up[0]}% {'недельного' if up[1] == 'weekly' else 'сессионного'} лимита (порог {th}%).")
        return lim

    def do_restart_check(self, agent: str, pane: str | None) -> bool:
        """Part 5a. True while the check for the current start is still due (owner nudge waits)."""
        if (STATE_DIR / "RESTART_CHECK_OFF").exists():
            return False
        st = self.state.setdefault("agents", {}).setdefault(agent, {})
        rc = st.setdefault("rc", {})
        unit = AGENTS[agent]["unit"]

        def current() -> tuple[str, float, float]:
            if f"{agent}.inv" in self.ov:
                since = float(self.ov[f"{agent}.since"])
                return self.ov[f"{agent}.inv"], since, float(self.ov.get(f"{agent}.main", since))
            return unit_start(unit)

        inv, started_ts, main_ts = current()
        if not started_ts or not main_ts or not inv:
            return False
        if "inv" not in rc:  # first run after deploy: this start was not a restart we saw
            rc["inv"] = inv
            self.save()
            return False
        if rc["inv"] == inv:
            return False
        uptime = self.now.timestamp() - started_ts
        if uptime > RC_MAX_AGE:
            rc["inv"] = inv
            self.save()
            self.alert(f"rc:{agent}:stale:{inv}", f"{AGENTS[agent]['name']}: после рестарта сессия "
                       f"{RC_MAX_AGE // 3600} ч не освобождалась, проверку неотвеченного пропустил.")
            return False

        def idle() -> bool:
            cur = capture(agent, self.ov)
            return cur is not None and bool(_READY.search(cur)) and not is_busy(cur)

        if uptime < RC_MIN_UPTIME or pane is None or not _READY.search(pane) or is_busy(pane):
            self.say(f"RC {agent}: waiting (uptime {int(uptime)} s)")
            return True
        started = datetime.fromtimestamp(main_ts, UTC)  # old/new session boundary
        done: dict = rc.setdefault("done", {})
        for k in [k for k, v in done.items() if time.time() - v > 3 * 86400]:
            del done[k]
        ru, pend = restart_pending(agent, started, self.now, self.jsonl.get(agent), set(done))
        if pend is None:  # e.g. a line being appended right now: no send, retry next tick
            self.say(f"RC {agent}: transcripts cannot be judged now, retry next tick")
            return True
        # The start is marked handled only after every chat went through; a chat already handed
        # over is in `done` (saved BEFORE its send), so a retry next tick never repeats it.
        name = AGENTS[agent]["name"]
        sent = rc.get("sent") if isinstance(rc.get("sent"), dict) else {}
        if sent.get("inv") != inv:
            sent = rc["sent"] = {"inv": inv, "chats": []}
        sent_chats: list = sent["chats"]
        for first in pend:
            # revalidate THIS chat right before its send: fresh read of the transcripts (a reply
            # or new speech since the first read drops the chat), THEN same start and idle pane,
            # then the transcripts must not have grown since before the re-read: a turn that
            # started and finished in between (reply appended, pane idle again) is caught here
            if first.chat in sent_chats:
                continue
            sig = transcript_sig(agent, self.jsonl.get(agent))
            _ru, again = restart_pending(agent, started, self.now, self.jsonl.get(agent), set(done))
            if again is None:
                self.say(f"RC {agent}: transcripts cannot be judged on recheck, retry next tick")
                return True
            if current()[0] != inv or not idle() or transcript_sig(agent, self.jsonl.get(agent)) != sig:
                self.say(f"RC {agent}: start changed, agent busy or transcripts moved before chat {first.chat}, retry next tick")
                return True
            p = next((x for x in again if x.chat == first.chat), None)
            if p is None:
                self.say(f"RC {agent}: chat {first.chat} closed on recheck, no nudge")
                continue
            last = p.last.isoformat()
            if p.chat == OWNER_CHAT and any(t >= main_ts for t in st.get("nudges", {}).get(last, [])):
                self.say(f"RC {agent}: owner nudge for {last} already went to this session")
                continue
            for k in p.keys() + p.dropped_keys:
                done[k] = int(time.time())
            sent_chats.append(p.chat)   # one nudge per chat per start, whatever arrives later
            if p.chat == OWNER_CHAT:  # the owner nudge of part 5 counts this one (gap and max)
                st.setdefault("nudges", {}).setdefault(last, []).append(int(time.time()))
            self.save()
            ok = self.nudge(agent, ru.build_message(p, RC_LABELS.get(p.chat, "личный чат")), p.chat)
            self.say(f"RC {agent}: chat {p.chat} pending {len(p.messages)} since {p.messages[0][0].isoformat()} nudge ok={ok}")
            self.alert(f"rc:{agent}:{p.chat}:{last}",
                       f"{name} после рестарта: в чате {RC_LABELS.get(p.chat, p.chat)} нашлось без ответа "
                       f"{len(p.messages) + p.dropped} (с {fmt_msk(p.messages[0][0])} МСК), "
                       f"передал ему тексты ({'доставлено' if ok else 'вебхук НЕ принял'}).")
        rc["inv"] = inv
        self.save()
        if not pend:
            self.say(f"RC {agent}: nothing pending after restart")
        return False

    def notice_periods(self, agent: str) -> list:
        """Limit windows in which THIS agent's bot already wrote to the owner (4a or part 5)."""
        per = self.state.get("limit_notice_periods")
        if not isinstance(per, dict):
            per = self.state["limit_notice_periods"] = {}
        lst = per.get(agent)
        if not isinstance(lst, list) or not all(isinstance(u, str) and re.fullmatch(r"\d{12}", u) for u in lst):
            lst = per[agent] = []
        return lst

    def limit_notice(self, agent: str, lim: tuple[datetime | None, bool]) -> None:
        """Part 4a: one line to the owner per limit window, sent by the bot, never by the model."""
        reset, reliable = lim
        if (not reliable or not reset or reset <= self.now + timedelta(minutes=2) or self.no_autoreply
                or (STATE_DIR / "LIMIT_NOTICE_OFF").exists()):
            return
        period = f"{reset:%Y%m%d%H%M}"
        used = self.state.setdefault("autoreply_periods", [])
        mine = self.notice_periods(agent)
        live = any(datetime.strptime(u, "%Y%m%d%H%M").replace(tzinfo=UTC) > self.now for u in mine)
        if period in mine or live:  # this bot already spoke in this window (here or in part 5)
            return
        if AGENTS[agent].get("limit_notice_needs_dm"):
            verdict, silent, _last = owner_wait(agent, self.now, self.jsonl.get(agent))
            if verdict != "unanswered" or silent >= 6 * 3600:
                return  # no DM to this bot waits: the main agent's line covers it
        text = limit_notice_text(reset, agent)
        for lst in (used, mine):
            if period not in lst:
                lst.append(period)
            del lst[:-20]
        self.save()  # marker durable BEFORE sending: an unclear result is never retried
        ok = self.bot_send(agent, text)
        self.alert(f"limitnotice:{agent}:{period}",
                   f"{AGENTS[agent]['name']} на лимите до {fmt_msk(reset)} МСК; владельцу ушло «{text}» "
                   f"({'доставлено' if ok else 'НЕ доставлено, повтора не будет'}).")

    def do_owner(self, agent: str, lim: tuple[datetime | None, bool] | None, autoreply_off: bool) -> None:
        name = AGENTS[agent]["name"]
        verdict, silent, last = owner_wait(agent, self.now, self.jsonl.get(agent))
        st = self.state.setdefault("agents", {}).setdefault(agent, {})
        if verdict != "unanswered":
            self.say(f"OWNER {agent}: {verdict}")
            return
        self.say(f"OWNER {agent}: unanswered {silent} s since {last}")
        if lim:  # on the limit: never nudge; at most ONE answer per period across all the owner's bots
            reset, reliable = lim
            if (reliable and reset and reset > self.now + timedelta(minutes=2) and silent < 6 * 3600
                    and not autoreply_off and not self.no_autoreply):
                period = f"{reset:%Y%m%d%H%M}"
                used = self.state.setdefault("autoreply_periods", [])
                live = any(datetime.strptime(u, "%Y%m%d%H%M").replace(tzinfo=UTC) > self.now for u in used)
                if period not in used and not live:  # a period still running blocks any other reset value
                    text = limit_text(reset)
                    used.append(period)
                    del used[:-20]
                    self.notice_periods(agent).append(period)  # this bot spoke: no 4a line from it
                    self.save()  # marker durable BEFORE sending: an unclear result is never retried
                    ok = self.bot_send(agent, text)
                    self.alert(f"autoreply:{period}",
                               f"{name} на лимите до {fmt_msk(reset)} МСК; владельцу ушёл автоответ «{text}» ({'доставлен' if ok else 'НЕ доставлен, повтора не будет'}).")
            return
        if silent < UNANSWERED_SEC or agent in self.restarted:
            return
        nk = st.setdefault("nudges", {}).setdefault(last, [])
        if len(nk) < NUDGE_MAX and (not nk or time.time() - nk[-1] >= NUDGE_GAP_SEC):
            msg = (f"[Сторож, авто-nudge] {OWNER} написал(а) тебе в личку примерно {silent // 60} мин назад, "
                   f"ответа через mcp__dashi-channel__reply нет. Пока reply не вызван, она не получает НИЧЕГО. "
                   f"Ответь на это сообщение: mcp__dashi-channel__reply chat_id={OWNER_CHAT}.")
            nk.append(int(time.time()))
            self.save()
            ok = self.nudge(agent, msg)
            self.say(f"NUDGE {agent} ok={ok}")
        self.alert(f"unanswered:{agent}:{last}",
                   f"{name}: сообщение владельца без ответа {silent // 60} мин (с {fmt_msk(datetime.fromisoformat(last))} МСК). Агент подтолкнут через вебхук.")
        st["nudges"] = {k: v for k, v in st["nudges"].items() if k == last}

    def do_auditor(self) -> None:
        for u in AUDITOR_UNITS:
            if not unit_active(u):
                self.alert(f"auditor:down:{u}", f"Аудитор: служба {u} не активна.")
        try:
            gs = json.loads(safe_read(AUDITOR_STATE))
            upd = datetime.fromisoformat(gs["updated_at"])
            age = (self.now - upd).total_seconds()
            if age > AUDITOR_HEARTBEAT_MAX or gs.get("gateway_state") != "running":
                self.alert("auditor:stale", f"Аудитор: шлюз не отмечался {int(age) // 60} мин (state={gs.get('gateway_state')}).")
            for pname, p in (gs.get("platforms") or {}).items():
                if p.get("state") != "connected" or p.get("needs_attention"):
                    self.alert(f"auditor:platform:{pname}", f"Аудитор: канал {pname} в состоянии {p.get('state')}.")
        except (OSError, ValueError, KeyError, TypeError):
            self.alert("auditor:nostate", "Аудитор: gateway_state.json не читается.")
        try:
            con = sqlite3.connect(f"file:{AUDITOR_DB}?mode=ro", uri=True, timeout=5)
            rows = con.execute("select session_id, max(case when role='user' then timestamp end), "
                               "max(case when role='assistant' then timestamp end) from messages "
                               "where timestamp > ? group by session_id", (time.time() - 2 * 86400,)).fetchall()
            la_all = con.execute("select max(timestamp) from messages where role='assistant'").fetchone()[0]
            con.close()
        except sqlite3.Error:
            self.alert("auditor:db", "Аудитор: state.db не читается.")
            return
        self.state["auditor_last_answer"] = la_all or 0
        for sid, lu, la in rows:  # per conversation: an answer elsewhere does not close this one
            lu, la = lu or 0, la or 0
            if lu > la and time.time() - lu > AUDITOR_ANSWER_SEC:
                self.alert(f"auditor:unanswered:{sid}:{int(lu)}",
                           f"Аудитор: задача с {fmt_msk(datetime.fromtimestamp(lu, UTC))} МСК без ответа {int(time.time() - lu) // 60} мин.")

    def tick(self) -> None:
        self.seen: set[str] = set()
        if (STATE_DIR / "STOP").exists():
            self.say("STOP")
            return
        panes: dict[str, str | None] = {}
        for a in AGENTS:
            if AGENTS[a]["tmux"]:
                try:
                    panes[a] = capture(a, self.ov)
                except (OSError, subprocess.SubprocessError):
                    panes[a] = None
        if not (STATE_DIR / "QUEUE_OFF").exists():
            try:
                self.do_queue(panes)
            except Exception as exc:
                self.failed = True
                log.exception("queue")
                self.alert(f"error:queue:{type(exc).__name__}", f"Сторож: очередь рестартов упала ({type(exc).__name__}).")
        autoreply_off = (STATE_DIR / "AUTOREPLY_OFF").exists()
        if self.state.get("no_autoreply_until_clear"):
            seen_limit = any(limit_state(panes.get(a), self.now) for a in panes)
            if all(panes.get(a) for a in panes) and not seen_limit:
                self.state.pop("no_autoreply_until_clear")  # the period known to be over: dedup safe again
            else:
                self.no_autoreply = True
        for agent in AGENTS:
            if agent in self.restarted:  # the pane snapshot predates the restart: judge next tick
                continue
            try:
                lim = self.do_agent(agent, panes.get(agent))
                if lim and AGENTS[agent].get("limit_notice"):
                    self.limit_notice(agent, lim)
                rc_due = False
                if AGENTS[agent].get("restart_check") and agent not in self.restarted:
                    rc_due = self.do_restart_check(agent, panes.get(agent))
                if AGENTS[agent]["owner_dm"] and agent not in self.restarted and not rc_due:
                    self.do_owner(agent, lim, autoreply_off)
            except Exception as exc:  # one agent's failure must not blind the others
                self.failed = True
                log.exception("agent %s", agent)
                self.alert(f"error:{agent}:{type(exc).__name__}", f"Сторож: проверка {agent} упала ({type(exc).__name__}).")
        try:
            if AUDITOR_UNITS:
                self.do_auditor()
        except Exception as exc:
            self.failed = True
            log.exception("auditor")
            self.alert(f"error:auditor:{type(exc).__name__}", f"Сторож: проверка аудитора упала ({type(exc).__name__}).")
        # re-arm keys whose condition is gone (queue/heal/autoreply keys are one-shot by name);
        # a tick with a failed check proves nothing about absence, so it re-arms nothing
        if not self.failed:
            self.state["open"] = {k: v for k, v in self.state.get("open", {}).items()
                                  if k in self.seen or time.time() - v < 86400 and k.split(":")[0] in
                                  ("queue", "loginheal", "frozen", "autoreply", "usage", "limit", "unanswered", "rc")}
        self.state["last_tick"] = int(time.time())


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--drain", action="store_true")
    ap.add_argument("--ack", nargs="*")
    ap.add_argument("--test-alert", action="store_true")
    ap.add_argument("--pane", action="append", default=[], help="agent=file (dry-run simulation)")
    ap.add_argument("--jsonl", action="append", default=[], help="agent=transcript (dry-run simulation)")
    ap.add_argument("--sim-state", help="state file for multi-tick dry-run simulation")
    args = ap.parse_args(argv)
    os.environ["PATH"] = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"  # cron PATH lacks runuser
    STATE_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s",
                        filename=None if args.dry_run else str(LOG_FILE))
    if args.drain:
        items = [json.loads(p.read_text(encoding="utf-8")) for p in sorted(OUTBOX.glob("*.json"))] if OUTBOX.exists() else []
        try:
            last = json.loads(STATE_FILE.read_text(encoding="utf-8")).get("last_tick", 0)
        except (OSError, ValueError):
            last = 0
        print(json.dumps({"items": items, "last_tick_age": int(time.time() - last)}, ensure_ascii=False))
        return 0
    if args.ack is not None:
        for i in args.ack:
            if re.fullmatch(r"[0-9]+-[0-9a-f]{8}", i):
                (OUTBOX / f"{i}.json").unlink(missing_ok=True)
        return 0
    overrides = dict(p.split("=", 1) for p in args.pane)
    jsonl = dict(p.split("=", 1) for p in args.jsonl)
    if (overrides or jsonl or args.sim_state) and not args.dry_run:
        print("--pane only with --dry-run", file=sys.stderr)
        return 64
    with open(STATE_DIR / ".lock", "w") as lk:
        try:
            fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 0
        resource.setrlimit(resource.RLIMIT_AS, (2 << 30, 2 << 30))
        signal.alarm(170)  # hard deadline: a hung read must not hold the lock (restart waits <= 90 s)
        g = Guard(args.dry_run, overrides, jsonl)
        sfile = Path(args.sim_state) if args.sim_state else STATE_FILE
        g.sfile, g.persist = sfile, (not args.dry_run) or bool(args.sim_state)
        corrupt = False
        try:
            g.state = json.loads(sfile.read_text(encoding="utf-8"))
            if not isinstance(g.state, dict):
                raise ValueError("state is not an object")
        except FileNotFoundError:
            g.state = {}
        except (OSError, ValueError):
            corrupt, g.state, g.no_autoreply = True, {"no_autoreply_until_clear": True}, True
            if g.persist:
                # copy aside, then atomically REPLACE the bad file by a blocking state: there is no
                # moment without a state file, so a crash here cannot drop the block (Codex r3)
                shutil.copy2(sfile, sfile.with_name(f"state.json.corrupt-{int(time.time())}"))
                g.save()
        if args.test_alert:
            g.seen = set()
            g.alert(f"test:{int(time.time())}", "Сторож агентов: проверка доставки алерта.", test=True)
        else:
            g.seen = set()
            if corrupt:
                g.alert("error:state", "Сторож: state.json был испорчен, отложен в сторону; автоответ владельцу выключен до конца текущего лимита.")
            g.tick()
        g.save()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
