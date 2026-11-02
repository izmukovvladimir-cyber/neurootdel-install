#!/usr/bin/env python3
"""Tests for lib/agents-guard.py part 4a, the limit notice to the owner. Run: python3 tests/test_agents_guard_limit_notice.py"""
from __future__ import annotations

import importlib.util
import os
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

LIB = Path(__file__).resolve().parent.parent / "lib"
# synthetic install: owner 5550001, two channel agents, main = jarvis (guard.conf is read at import)
_CONF_DIR = tempfile.mkdtemp()
(Path(_CONF_DIR) / "guard.conf").write_text(
    f'AGENT_USER="agentuser"\nAGENT_HOME="{_CONF_DIR}/home"\nCHANNEL_AGENTS="jarvis coder"\n'
    'MAIN_AGENT="jarvis"\nOWNER_TG_ID="5550001"\nOWNER_TIMEZONE="Europe/Moscow"\n', encoding="utf-8")
os.environ["NEUROOTDEL_GUARD_CONF"] = str(Path(_CONF_DIR) / "guard.conf")
os.environ["NEUROOTDEL_GUARD_STATE"] = str(Path(_CONF_DIR) / "state")
sys.path.insert(0, str(LIB))
spec = importlib.util.spec_from_file_location("ag", LIB / "agents-guard.py")
ag = importlib.util.module_from_spec(spec)
sys.modules["ag"] = ag
spec.loader.exec_module(ag)

UTC = timezone.utc
NOW = datetime(2026, 10, 28, 22, 59, 30, tzinfo=UTC)  # the real event: 01:59 МСК, resets 11:30pm UTC
# bottom of a live agent pane on the limit
PANE = """  ⎿  You've hit your 5-hour limit · resets 11:30pm (UTC)
✻ Baked for 0s · done 11:07 PM
─────────────────────────────────────────────────────
❯ 
─────────────────────────────────────────────────────
  ⚠ Usage limit reached · limit resets 11:30pm
    Continuing automatically at 11:30pm · Esc to cancel · /usage-credits to
    continue now
  ⏵⏵ bypass permissions on (shift+tab to cycle)"""
SCROLLBACK_ONLY = """  ⎿  You've hit your 5-hour limit · resets 11:30pm (UTC)
✻ Baked for 0s · done 11:07 PM
─────────────────────────────────────────────────────
❯ 
─────────────────────────────────────────────────────
  ⏵⏵ bypass permissions on (shift+tab to cycle)"""

CASES = []


def case(fn):
    CASES.append(fn)
    return fn


class G(ag.Guard):
    def __init__(self, now=NOW, state=None, send_ok=True, send_exc=None):
        super().__init__(False, {})
        self.persist = False
        self.now, self.state = now, state if state is not None else {}
        self.sent, self.alerts, self.saved_used = [], [], []
        self.send_ok, self.send_exc = send_ok, send_exc

    def save(self):
        self.saved_used.append(list(self.state.get("autoreply_periods", [])))

    def bot_send(self, agent, text):
        if self.send_exc:
            raise self.send_exc
        self.sent.append((agent, text))
        return self.send_ok

    def alert(self, key, text, test=False):
        self.alerts.append((key, text))


def tmp_state_dir():
    d = Path(tempfile.mkdtemp())
    ag.STATE_DIR = d
    return d


def notice(g, pane=PANE):
    lim = ag.limit_state(pane, g.now)
    if lim and ag.AGENTS["jarvis"].get("limit_notice"):
        g.limit_notice("jarvis", lim)
    return lim


@case
def real_event_sends_one_line_in_msk():
    tmp_state_dir()
    g = G()
    notice(g)
    assert g.sent == [("jarvis", "Мы на лимите до 02:30 мск, ответим после.")], g.sent
    assert g.state["autoreply_periods"] == ["202610282330"]
    assert g.state["limit_notice_periods"] == {"jarvis": ["202610282330"]}
    assert g.alerts and g.alerts[0][0] == "limitnotice:jarvis:202610282330"


@case
def every_later_tick_of_the_window_is_silent():
    tmp_state_dir()
    g = G()
    notice(g)
    for minute in (1, 5, 20, 29):
        g.now = NOW + timedelta(minutes=minute)
        notice(g)
    assert len(g.sent) == 1, g.sent


@case
def part5_answer_from_same_bot_blocks_notice():
    tmp_state_dir()
    g = G(state={"autoreply_periods": ["202610282330"], "limit_notice_periods": {"jarvis": ["202610282330"]}})
    notice(g)
    assert g.sent == []


@case
def notice_blocks_part5_answer_in_same_window():
    tmp_state_dir()
    g = G()
    notice(g)
    used = g.state["autoreply_periods"]
    live = any(datetime.strptime(u, "%Y%m%d%H%M").replace(tzinfo=UTC) > NOW for u in used)
    assert "202610282330" in used and live  # the exact test do_owner makes before its answer


@case
def a_live_period_blocks_a_different_reset_value():
    tmp_state_dir()
    g = G(state={"limit_notice_periods": {"jarvis": ["202610282345"]}})
    notice(g)
    assert g.sent == []


@case
def next_window_sends_again():
    tmp_state_dir()
    g = G(state={"autoreply_periods": ["202610281800"], "limit_notice_periods": {"jarvis": ["202610281800"]}})
    notice(g)
    assert len(g.sent) == 1


@case
def reset_too_close_is_silent():
    tmp_state_dir()
    g = G(now=datetime(2026, 10, 28, 23, 28, 30, tzinfo=UTC))
    notice(g)
    assert g.sent == []


@case
def scrollback_line_alone_is_not_a_limit():
    tmp_state_dir()
    g = G(now=datetime(2026, 10, 28, 23, 40, tzinfo=UTC))
    assert notice(g, SCROLLBACK_ONLY) is None and g.sent == []


@case
def unreadable_time_is_silent():
    tmp_state_dir()
    g = G()
    notice(g, PANE.replace("limit resets 11:30pm", "limit resets soon").replace("at 11:30pm", "at soon"))
    assert g.sent == []


@case
def far_dateless_reset_is_treated_as_stale():
    tmp_state_dir()
    g = G()
    lim = notice(g, PANE.replace("11:30pm", "8:00am"))
    assert lim and lim[1] is False and g.sent == [], (lim, g.sent)


@case
def corrupt_state_blocks_notice():
    tmp_state_dir()
    g = G()
    g.no_autoreply = True
    notice(g)
    assert g.sent == []


@case
def stop_file_blocks_notice():
    d = tmp_state_dir()
    (d / "LIMIT_NOTICE_OFF").touch()
    g = G()
    notice(g)
    assert g.sent == []


@case
def marker_is_durable_before_send_and_failure_is_not_retried():
    tmp_state_dir()
    g = G(send_exc=OSError("net"))
    try:
        notice(g)
    except OSError:
        pass
    assert g.saved_used and "202610282330" in g.saved_used[0]
    g.send_exc, g.send_ok = None, True
    notice(g)
    assert g.sent == []


@case
def failed_send_is_reported_not_retried():
    tmp_state_dir()
    g = G(send_ok=False)
    notice(g)
    g.now = NOW + timedelta(minutes=1)
    notice(g)
    assert len(g.sent) == 1 and "НЕ доставлено" in g.alerts[0][1]


@case
def main_and_other_agent_have_the_notice():
    assert ag.AGENTS["jarvis"].get("limit_notice") is True and ag.AGENTS["coder"].get("limit_notice") is True
    assert not ag.AGENTS["jarvis"].get("limit_notice_needs_dm") and ag.AGENTS["coder"].get("limit_notice_needs_dm")
    assert not ag.AGENTS.get("richard", {}).get("limit_notice")


@case
def text_has_no_em_dash():
    tmp_state_dir()
    g = G()
    notice(g)
    assert "—" not in g.sent[0][1]


@case
def tick_sends_one_line_from_main_when_other_has_no_dm():
    tmp_state_dir()
    saved = ag.capture, ag.unit_active, ag.unit_since, ag.run, ag.owner_wait
    ag.capture = lambda agent, ov: PANE
    ag.unit_active = lambda unit: True
    ag.unit_since = lambda unit: 0
    try:
        g = G()
        g.do_queue = lambda panes: None
        g.do_restart_check = lambda agent, pane: False
        g.do_owner = lambda agent, lim, off: None
        g.do_auditor = lambda: None
        ag.run = lambda *a, **k: type("R", (), {"stdout": "", "returncode": 0})()
        ag.owner_wait = lambda agent, now, override=None: ("unknown", 0, "")
        g.tick()
        g.now = NOW + timedelta(minutes=1)
        g.tick()
    finally:
        ag.capture, ag.unit_active, ag.unit_since, ag.run, ag.owner_wait = saved
    assert g.sent == [("jarvis", "Мы на лимите до 02:30 мск, ответим после.")], g.sent


def with_owner_wait(verdict, silent=600):
    saved = ag.owner_wait
    ag.owner_wait = lambda agent, now, override=None: (verdict, silent, "2026-10-28T22:49:30+00:00")
    return saved


@case
def coder_is_silent_without_a_waiting_dm():
    tmp_state_dir()
    lim = ag.limit_state(PANE, NOW)
    for verdict, silent in (("unknown", 0), ("answered", 600), ("unanswered", 6 * 3600)):
        g = G()
        saved = with_owner_wait(verdict, silent)
        try:
            g.limit_notice("jarvis", lim)
            g.limit_notice("coder", lim)
        finally:
            ag.owner_wait = saved
        assert g.sent == [("jarvis", "Мы на лимите до 02:30 мск, ответим после.")], (verdict, g.sent)
        assert "coder" not in g.state["limit_notice_periods"] or not g.state["limit_notice_periods"]["coder"]


@case
def other_agent_writes_once_when_owners_dm_waits():
    tmp_state_dir()
    lim = ag.limit_state(PANE, NOW)
    g = G()
    saved = with_owner_wait("unanswered", 600)
    try:
        g.limit_notice("jarvis", lim)
        g.limit_notice("coder", lim)
        g.limit_notice("coder", lim)
        g.limit_notice("jarvis", lim)
    finally:
        ag.owner_wait = saved
    assert g.sent == [("jarvis", "Мы на лимите до 02:30 мск, ответим после."), ("coder", "На лимите до 02:30 мск, отвечу после.")], g.sent
    assert [k for k, _ in g.alerts] == ["limitnotice:jarvis:202610282330", "limitnotice:coder:202610282330"]


@case
def coder_dm_arriving_later_in_the_window_still_gets_its_line():
    tmp_state_dir()
    lim = ag.limit_state(PANE, NOW)
    g = G()
    saved = with_owner_wait("answered")
    try:
        g.limit_notice("coder", lim)
    finally:
        ag.owner_wait = saved
    saved = with_owner_wait("unanswered", 120)
    try:
        g.limit_notice("coder", lim)
    finally:
        ag.owner_wait = saved
    assert g.sent == [("coder", "На лимите до 02:30 мск, отвечу после.")], g.sent


@case
def notice_texts_are_exact():
    reset = datetime(2026, 10, 28, 23, 30, tzinfo=UTC)
    assert ag.limit_notice_text(reset, "jarvis") == "Мы на лимите до 02:30 мск, ответим после."
    assert ag.limit_notice_text(reset, "coder") == "На лимите до 02:30 мск, отвечу после."
    for a in ("jarvis", "coder"):
        assert "\u2014" not in ag.limit_notice_text(reset, a)


@case
def single_agent_install_speaks_for_itself():
    saved = dict(ag.AGENTS)
    try:
        ag.AGENTS.pop("coder")
        assert ag.limit_notice_text(datetime(2026, 10, 28, 23, 30, tzinfo=UTC), "jarvis") == "На лимите до 02:30 мск, отвечу после."
    finally:
        ag.AGENTS.clear()
        ag.AGENTS.update(saved)


@case
def owner_timezone_is_used_outside_moscow():
    saved = ag.owner_zone
    ag.owner_zone = lambda: (ag.ZoneInfo("Asia/Novosibirsk"), "по вашему времени")
    try:
        assert ag.limit_notice_text(datetime(2026, 10, 28, 23, 30, tzinfo=UTC), "coder") == "На лимите до 06:30 по вашему времени, отвечу после."
    finally:
        ag.owner_zone = saved


@case
def part5_answer_marks_only_its_own_bot():
    tmp_state_dir()
    g = G()
    g.notice_periods("coder").append("202610282330")  # what do_owner records for the coder bot
    lim = ag.limit_state(PANE, g.now)
    g.limit_notice("coder", lim)
    g.limit_notice("jarvis", lim)
    assert g.sent == [("jarvis", "Мы на лимите до 02:30 мск, ответим после.")], g.sent


@case
def do_owner_records_its_answer_for_that_bot():
    tmp_state_dir()
    src = Path(ag.__file__).read_text()
    assert "self.notice_periods(agent).append(period)  # this bot spoke" in src
    g = G()
    saved = ag.owner_wait
    ag.owner_wait = lambda agent, now, override=None: ("unanswered", 600, "2026-10-28T22:49:30+00:00")
    try:
        g.do_owner("coder", ag.limit_state(PANE, g.now), False)
    finally:
        ag.owner_wait = saved
    assert len(g.sent) == 1 and g.sent[0][0] == "coder", g.sent
    assert g.state["limit_notice_periods"]["coder"] == ["202610282330"], g.state
    g.limit_notice("coder", ag.limit_state(PANE, g.now))
    assert len(g.sent) == 1, g.sent


@case
def bad_per_bot_state_starts_clean():
    tmp_state_dir()
    for junk in ("x", {"jarvis": "x"}, {"jarvis": [1]}, {"jarvis": ["bad"]}):
        g = G(state={"limit_notice_periods": junk})
        notice(g)
        assert len(g.sent) == 1, (junk, g.sent)


@case
def bot_send_uses_the_agents_own_token_and_owner_chat():
    import urllib.request
    tmp = Path(tempfile.mkdtemp())
    env = tmp / "channel.env"
    env.write_text("TELEGRAM_BOT_TOKEN=coder-tok\n")
    saved_env, saved_open = ag.AGENTS["coder"]["env"], urllib.request.urlopen
    seen = []

    class Resp:
        def __enter__(self): return self
        def __exit__(self, *a): return False
        def read(self): return b'{"ok": true}'

    def fake_open(url, data=None, timeout=0):
        seen.append((url, data.decode()))
        return Resp()

    ag.AGENTS["coder"]["env"] = str(env)
    urllib.request.urlopen = fake_open
    try:
        ok = ag.Guard(False, {}).bot_send("coder", "На лимите до 02:30 мск, отвечу после.")
    finally:
        ag.AGENTS["coder"]["env"], urllib.request.urlopen = saved_env, saved_open
    assert ok is True and seen[0][0] == "https://api.telegram.org/botcoder-tok/sendMessage", seen
    assert "chat_id=5550001" in seen[0][1], seen


def main() -> int:
    failed = 0
    for fn in CASES:
        try:
            fn()
            print(f"ok   {fn.__name__}")
        except AssertionError as exc:
            failed += 1
            print(f"FAIL {fn.__name__}: {exc}")
    print(f"{len(CASES) - failed}/{len(CASES)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
