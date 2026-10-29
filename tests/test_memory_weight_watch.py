#!/usr/bin/env python3
"""Tests for lib/memory_weight_watch.py (rule 5b weight watch). Run: python3 tests/test_memory_weight_watch.py"""
from __future__ import annotations

import importlib.util
import json
import os
import sys
import tempfile
from pathlib import Path

LIB = Path(__file__).resolve().parent.parent / "lib"
_CONF_DIR = Path(tempfile.mkdtemp())
_CONF = _CONF_DIR / "guard.conf"
_CONF.write_text(f'AGENT_USER="agentuser"\nAGENT_HOME="{_CONF_DIR}/home"\nCONFIG_ROOT="/etc/agent-plugin"\n'
                 'CHANNEL_AGENTS="jarvis coder"\nOWNER_TG_ID="5550001"\nOWNER_TIMEZONE="Europe/Moscow"\n',
                 encoding="utf-8")
os.environ["NEUROOTDEL_GUARD_CONF"] = str(_CONF)
os.environ["NEUROOTDEL_WEIGHT_STATE"] = str(_CONF_DIR / "state")
spec = importlib.util.spec_from_file_location("mww", LIB / "memory_weight_watch.py")
mww = importlib.util.module_from_spec(spec)
sys.modules["mww"] = mww
spec.loader.exec_module(mww)

BIG = "x" * (16 * 1024)
SMALL = "x" * 1024
D1, D2, D3, D5 = "2026-10-29", "2026-10-30", "2026-10-31", "2026-11-02"


def make_agent(lab: Path, name: str, decisions: str = SMALL, handoff: str = SMALL,
               rules: str = SMALL, include_handoff: bool = True) -> None:
    core = lab / name / ".claude" / "core"
    (core / "warm").mkdir(parents=True, exist_ok=True)
    (core / "hot").mkdir(parents=True, exist_ok=True)
    (core / "warm" / "decisions.md").write_text(decisions)
    (core / "hot" / "handoff.md").write_text(handoff)
    (core / "rules.md").write_text(rules)
    inc = "@core/rules.md\n@core/warm/decisions.md\n" + ("@core/hot/handoff.md\n" if include_handoff else "")
    (lab / name / ".claude" / "CLAUDE.md").write_text("# agent\n" + inc)


class Rec:
    def __init__(self, ok: bool = True) -> None:
        self.ok, self.calls = ok, []

    def __call__(self, who: str, text: str) -> bool:
        self.calls.append((who, text))
        return self.ok


CASES = []


def case(fn):
    CASES.append(fn)
    return fn


def env():
    tmp = Path(tempfile.mkdtemp())
    return tmp / "lab", tmp / "state.json"


def go(lab, st, day, n, a=None, agents=("a",)):
    return mww.run(list(agents), lab, st, day, n, a if a is not None else Rec())


@case
def light_agent_is_silent():
    lab, st = env()
    make_agent(lab, "a")
    n, a = Rec(), Rec()
    assert go(lab, st, D1, n, a) == []
    assert n.calls == [] and a.calls == [] and json.loads(st.read_text()) == {}


@case
def heavy_handoff_signals_once_per_day():
    lab, st = env()
    make_agent(lab, "a", handoff=BIG + "x" * 9000)  # ~25 KB like Nikolai's
    n = Rec()
    assert go(lab, st, D1, n) == []
    assert go(lab, st, D1, n) == []  # second manual run the same day: no second signal
    assert len(n.calls) == 1 and n.calls[0][0] == "a", n.calls
    t = n.calls[0][1]
    assert ".claude/core/hot/handoff.md: 24 КБ при потолке 15 КБ" in t, t
    assert "только ОТКРЫТОЕ" in t and "2-4 строки" in t and "7 дней" in t and "Бэкап" in t and "core/archive" in t


@case
def heavy_decisions_signals_too():
    lab, st = env()
    make_agent(lab, "a", decisions=BIG)
    n = Rec()
    go(lab, st, D1, n)
    assert len(n.calls) == 1 and "decisions.md: 16 КБ" in n.calls[0][1], n.calls


@case
def next_day_still_heavy_signals_again():
    lab, st = env()
    make_agent(lab, "a", handoff=BIG)
    n = Rec()
    go(lab, st, D1, n)
    go(lab, st, D2, n)
    assert len(n.calls) == 2 and "ночь подряд: 2" in n.calls[1][1], n.calls


@case
def heavy_rules_file_is_not_a_journal():
    lab, st = env()
    make_agent(lab, "a", rules=BIG)
    n = Rec()
    assert go(lab, st, D1, n) == [] and n.calls == []


@case
def not_included_handoff_is_ignored():
    lab, st = env()
    make_agent(lab, "a", handoff=BIG, include_handoff=False)
    n = Rec()
    assert go(lab, st, D1, n) == [] and n.calls == []


@case
def escalates_to_outbox_on_third_night_once_per_day():
    lab, st = env()
    make_agent(lab, "a", handoff=BIG)
    n, a = Rec(), Rec()
    assert go(lab, st, D1, n, a) == []
    assert go(lab, st, D2, n, a) == []
    out = go(lab, st, D3, n, a)
    assert len(out) == 1 and "3 ночей подряд" in out[0] and "handoff.md 16 КБ" in out[0], out
    assert len(a.calls) == 1 and "3 ночей подряд" in a.calls[0][1]
    go(lab, st, D3, n, a)
    go(lab, st, D3, n, a)
    assert len(a.calls) == 1, a.calls  # outbox not repeated the same day, however many runs
    assert len(n.calls) == 3


@case
def gap_restarts_streak():
    lab, st = env()
    make_agent(lab, "a", handoff=BIG)
    n = Rec()
    go(lab, st, D1, n)
    go(lab, st, D2, n)
    assert go(lab, st, D5, n) == [] and json.loads(st.read_text())["a"]["days"] == 1


@case
def cleaning_resets_streak():
    lab, st = env()
    make_agent(lab, "a", handoff=BIG)
    n = Rec()
    go(lab, st, D1, n)
    go(lab, st, D2, n)
    make_agent(lab, "a")
    assert go(lab, st, D3, n) == []
    make_agent(lab, "a", handoff=BIG)
    assert go(lab, st, "2026-11-01", n) == []
    assert json.loads(st.read_text())["a"]["days"] == 1


@case
def failed_delivery_goes_to_outbox_and_retries_next_night_only():
    lab, st = env()
    make_agent(lab, "a", decisions=BIG)
    a = Rec()
    out = go(lab, st, D1, Rec(ok=False), a)
    assert len(out) == 1 and "НЕ доставлен" in out[0], out
    assert len(a.calls) == 1
    good = Rec()
    go(lab, st, D1, good, a)
    assert good.calls == []  # a timeout may have reached the agent: no second attempt today
    go(lab, st, D2, good, a)
    assert len(good.calls) == 1


@case
def attempt_marker_is_saved_before_the_webhook():
    lab, st = env()
    make_agent(lab, "a", decisions=BIG)
    seen = []

    def notify(agent, text):
        seen.append(json.loads(st.read_text())["a"]["notified"])
        raise KeyboardInterrupt  # process dies mid-send

    try:
        go(lab, st, D1, notify)
    except KeyboardInterrupt:
        pass
    assert seen == [D1]
    n = Rec()
    go(lab, st, D1, n)
    assert n.calls == []


@case
def undelivered_outbox_is_kept_until_taken():
    lab, st = env()
    make_agent(lab, "a", decisions=BIG)
    go(lab, st, D1, Rec(ok=False), Rec(ok=False))
    assert len(json.loads(st.read_text())["_pending"]) == 1
    make_agent(lab, "a")  # cleaned meanwhile: the failure line must still reach the outbox
    a = Rec()
    go(lab, st, D1, Rec(), a)
    assert len(a.calls) == 1 and "НЕ доставлен" in a.calls[0][1], a.calls
    assert "_pending" not in json.loads(st.read_text())


@case
def failed_outbox_is_retried_same_day():
    lab, st = env()
    make_agent(lab, "a", decisions=BIG)
    bad_a = Rec(ok=False)
    go(lab, st, D1, Rec(ok=False), bad_a)
    assert "_reported" not in json.loads(st.read_text())
    a = Rec()
    go(lab, st, D1, Rec(ok=False), a)
    assert len(a.calls) == 1 and json.loads(st.read_text())["_reported"]["date"] == D1


@case
def missing_agent_is_reported_not_crashed():
    lab, st = env()
    make_agent(lab, "a", decisions=BIG)
    n = Rec()
    out = go(lab, st, D1, n, agents=("ghost", "a"))
    assert len(out) == 1 and "ghost" in out[0], out
    assert [c[0] for c in n.calls] == ["a"]


@case
def corrupt_state_sends_nothing_and_is_set_aside():
    for junk in ("{broken", "[1,2]", '{"a": "str"}', '{"a": {"days": "2", "last_seen": "2026-10-29"}}',
                 '{"a": {"notified": 5}}'):
        lab, st = env()
        make_agent(lab, "a", decisions=BIG)
        st.parent.mkdir(parents=True, exist_ok=True)
        st.write_text(junk)
        n, a = Rec(), Rec()
        out = go(lab, st, D1, n, a)
        assert n.calls == [] and len(out) == 1 and "испорчено" in out[0], out
        assert len(a.calls) == 1 and st.with_name("state.json.corrupt-" + D1).read_text() == junk
        go(lab, st, D1, n, a)
        go(lab, st, D1, n, a)
        assert n.calls == [] and len(a.calls) == 1, (n.calls, a.calls)  # same day: still nothing
        go(lab, st, D2, n, a)
        assert len(n.calls) == 1, n.calls  # next night starts clean


@case
def odd_entries_in_valid_state_start_clean():
    lab, st = env()
    make_agent(lab, "a", decisions=BIG)
    st.parent.mkdir(parents=True, exist_ok=True)
    for junk in ('{"a": {"last_seen": "2026-10-29"}}', '{"a": {"days": -5, "last_seen": "2026-10-28"}}',
                 '{"_pending": "x", "_reported": 7}'):
        st.write_text(junk)
        n = Rec()
        assert go(lab, st, D1, n) == [], junk
        assert json.loads(st.read_text())["a"]["days"] == 1, junk


@case
def signal_has_no_em_dash_and_no_reply_to_owner():
    t = mww.signal_text([(25979, "core/hot/handoff.md")], 1)
    assert "—" not in t
    assert "Владельцу про это не пиши" in t
    assert "закрытое переносить в core/archive, не удалять" in t.lower()
    assert "Обещания и сроки не трогать" in t and "УДАЛИ" not in t


@case
def clean_then_heavy_same_day_does_not_signal_twice():
    lab, st = env()
    make_agent(lab, "a", decisions=BIG)
    n = Rec()
    go(lab, st, D1, n)
    make_agent(lab, "a")
    go(lab, st, D1, n)
    make_agent(lab, "a", decisions=BIG)
    go(lab, st, D1, n)
    assert len(n.calls) == 1, n.calls
    make_agent(lab, "a")
    go(lab, st, D2, n)
    assert json.loads(st.read_text()) == {}


@case
def one_agent_failure_does_not_stop_the_pass():
    lab, st = env()
    for x in ("a", "b", "c"):
        make_agent(lab, x, decisions=BIG)

    def notify(agent, text):
        if agent == "b":
            raise RuntimeError("boom")
        return True

    orig = mww.heavy_journals

    def heavy(agent_dir, rows=None):
        if agent_dir.name == "a":
            raise OSError("vanished")
        return orig(agent_dir, rows)

    mww.heavy_journals = heavy
    try:
        out = go(lab, st, D1, notify, agents=("a", "b", "c"))
    finally:
        mww.heavy_journals = orig
    assert any("a: память не взвешена" in l for l in out), out
    assert any("b: сигнал о чистке памяти НЕ доставлен" in l for l in out), out
    saved = json.loads(st.read_text())
    assert saved["c"]["notified"] == D1 and "failed" not in saved["c"], saved
    assert saved["b"]["failed"] == D1, saved


@case
def corrupt_notice_survives_outbox_failure():
    lab, st = env()
    make_agent(lab, "a", decisions=BIG)
    st.parent.mkdir(parents=True, exist_ok=True)
    st.write_text("{broken")
    go(lab, st, D1, Rec(), Rec(ok=False))
    assert "испорчено" in json.loads(st.read_text())["_pending"][0]
    a, n = Rec(), Rec()
    go(lab, st, D1, n, a)
    assert n.calls == [] and len(a.calls) == 1 and "испорчено" in a.calls[0][1], a.calls


@case
def crash_inside_corrupt_alert_keeps_block_and_notice():
    lab, st = env()
    make_agent(lab, "a", decisions=BIG)
    st.parent.mkdir(parents=True, exist_ok=True)
    st.write_text("{broken")

    def dies(key, text):
        raise KeyboardInterrupt

    try:
        go(lab, st, D1, Rec(), dies)
    except KeyboardInterrupt:
        pass
    n, a = Rec(), Rec()
    go(lab, st, D1, n, a)
    assert n.calls == [] and len(a.calls) == 1 and "испорчено" in a.calls[0][1], (n.calls, a.calls)


@case
def new_line_after_todays_outbox_still_goes_out():
    lab, st = env()
    make_agent(lab, "a", decisions=BIG)
    a = Rec()
    go(lab, st, D1, Rec(), a, agents=("ghost",))
    assert len(a.calls) == 1 and "ghost" in a.calls[0][1]
    go(lab, st, D1, Rec(ok=False), a, agents=("ghost", "a"))
    assert len(a.calls) == 2 and "ghost" not in a.calls[1][1] and "НЕ доставлен" in a.calls[1][1], a.calls


@case
def outbox_exception_still_saves_state():
    lab, st = env()
    make_agent(lab, "a", decisions=BIG)

    def boom(key, text):
        raise OSError("no outbox")

    go(lab, st, D1, Rec(ok=False), boom)
    saved = json.loads(st.read_text())
    assert saved["a"]["days"] == 1 and len(saved["_pending"]) == 1


@case
def main_refuses_args_and_honours_stop():
    assert mww.main(["x"]) == 2
    tmp = Path(tempfile.mkdtemp())
    orig = mww.STOP_FILE, mww.run
    mww.STOP_FILE = tmp / "STOP"
    mww.STOP_FILE.touch()
    called = []
    mww.run = lambda *a, **k: called.append(1) or []
    try:
        assert mww.main([]) == 0 and called == []
    finally:
        mww.STOP_FILE, mww.run = orig


@case
def main_skips_when_another_pass_holds_the_lock():
    import fcntl
    tmp = Path(tempfile.mkdtemp())
    orig = mww.STATE_DIR, mww.LOCK_FILE, mww.STOP_FILE, mww.run
    mww.STATE_DIR, mww.LOCK_FILE, mww.STOP_FILE = tmp, tmp / ".lock", tmp / "STOP"
    called = []
    mww.run = lambda *a, **k: called.append(1) or []
    try:
        with open(tmp / ".lock", "w") as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            assert mww.main([]) == 0 and called == []
        assert mww.main([]) == 0 and called == [1]
    finally:
        mww.STATE_DIR, mww.LOCK_FILE, mww.STOP_FILE, mww.run = orig


@case
def roster_comes_from_guard_conf_each_with_own_env_and_owner_chat():
    assert set(mww.AGENTS) == {"jarvis", "coder"}, mww.AGENTS
    assert mww.AGENTS["coder"]["env"] == "/etc/agent-plugin/coder/channel.env"
    assert all(v["chat"] == "5550001" for v in mww.AGENTS.values())
    assert mww.LAB == _CONF_DIR / "home" / ".claude-lab"
    assert str(mww.STATE_DIR) == str(_CONF_DIR / "state")


@case
def webhook_uses_the_agents_own_port_token_and_chat():
    import urllib.request
    tmp = Path(tempfile.mkdtemp())
    env = tmp / "channel.env"
    env.write_text("TELEGRAM_WEBHOOK_TOKEN=tok-c\nTELEGRAM_WEBHOOK_PORT=8090\n")
    orig_agents, orig_open = mww.AGENTS, urllib.request.urlopen
    seen = []

    class Resp:
        status = 200
        def __enter__(self): return self
        def __exit__(self, *a): return False

    def fake_open(req, timeout=0):
        seen.append((req.full_url, req.get_header("Authorization"), json.loads(req.data)))
        return Resp()

    mww.AGENTS = {"coder": {"env": str(env), "chat": "111"}}
    urllib.request.urlopen = fake_open
    try:
        assert mww.webhook_notify("coder", "hi") is True
    finally:
        mww.AGENTS, urllib.request.urlopen = orig_agents, orig_open
    assert seen == [("http://127.0.0.1:8090/hooks/agent", "Bearer tok-c", {"message": "hi", "chatId": "111"})], seen


@case
def two_agents_are_tracked_independently():
    lab, st = env()
    make_agent(lab, "jarvis", handoff=BIG)
    make_agent(lab, "coder")
    n = Rec()
    go(lab, st, D1, n, agents=("jarvis", "coder"))
    make_agent(lab, "coder", decisions=BIG)
    go(lab, st, D1, n, agents=("jarvis", "coder"))
    assert [c[0] for c in n.calls] == ["jarvis", "coder"], n.calls


RULES_BIG = "x" * (31 * 1024)


def make_claude(lab: Path, name: str, extra: int) -> None:
    md = lab / name / ".claude" / "CLAUDE.md"
    md.write_text(md.read_text() + "y" * extra)


@case
def rules_over_30k_wakes_agent_and_tells_jarvis_once_a_day():
    lab, st = env()
    make_agent(lab, "a", rules=RULES_BIG)
    n, a = Rec(), Rec()
    out = go(lab, st, D1, n, a)
    assert len(n.calls) == 1 and "core/rules.md: 31 КБ при потолке 30 КБ" in n.calls[0][1], n.calls
    assert "В ЭТОМ ЖЕ ХОДЕ" in n.calls[0][1] and "ни одно правило владельца не удаляется" in n.calls[0][1]
    assert out == ["- a: core/rules.md 31 КБ при пороге 30 КБ, агенту ушёл сигнал свернуть"], out
    assert len(a.calls) == 1 and "core/rules.md 31 КБ" in a.calls[0][1], a.calls
    go(lab, st, D1, n, a)
    assert len(n.calls) == 1 and len(a.calls) == 1, (n.calls, a.calls)  # same day: nothing repeats
    go(lab, st, D2, n, a)
    assert len(n.calls) == 2 and len(a.calls) == 2  # still heavy next night: again


@case
def rules_at_30k_or_below_is_silent():
    lab, st = env()
    make_agent(lab, "a", rules="x" * (30 * 1024))
    n, a = Rec(), Rec()
    assert go(lab, st, D1, n, a) == [] and n.calls == [] and a.calls == []


@case
def claude_md_over_40k_signals():
    lab, st = env()
    make_agent(lab, "a")
    make_claude(lab, "a", 41 * 1024)
    n, a = Rec(), Rec()
    out = go(lab, st, D1, n, a)
    assert len(n.calls) == 1 and "CLAUDE.md: 41 КБ при потолке 40 КБ" in n.calls[0][1], n.calls
    assert out and "CLAUDE.md 41 КБ при пороге 40 КБ" in out[0], out


@case
def claude_md_at_37k_is_silent():
    lab, st = env()
    make_agent(lab, "a")
    make_claude(lab, "a", 37 * 1024)
    n = Rec()
    assert go(lab, st, D1, n) == [] and n.calls == []


@case
def rules_not_included_is_ignored():
    lab, st = env()
    make_agent(lab, "a", rules=RULES_BIG)
    md = lab / "a" / ".claude" / "CLAUDE.md"
    md.write_text(md.read_text().replace("@core/rules.md\n", ""))
    n = Rec()
    assert go(lab, st, D1, n) == [] and n.calls == []


@case
def rules_and_journal_go_in_one_signal():
    lab, st = env()
    make_agent(lab, "a", rules=RULES_BIG, handoff=BIG)
    n = Rec()
    go(lab, st, D1, n)
    assert len(n.calls) == 1 and "rules.md" in n.calls[0][1] and "handoff.md: 16 КБ при потолке 15 КБ" in n.calls[0][1]


@case
def failed_rules_signal_is_reported_as_not_sent():
    lab, st = env()
    make_agent(lab, "a", rules=RULES_BIG)
    out = go(lab, st, D1, Rec(ok=False))
    assert any("сигнал агенту НЕ ушёл" in l for l in out), out


@case
def caps_come_from_guard_conf():
    def load_with(extra: str):
        conf = _CONF_DIR / f"g{abs(hash(extra))}.conf"
        conf.write_text(_CONF.read_text() + extra, encoding="utf-8")
        saved = os.environ["NEUROOTDEL_GUARD_CONF"]
        os.environ["NEUROOTDEL_GUARD_CONF"] = str(conf)
        try:
            spec2 = importlib.util.spec_from_file_location("mww_conf", Path(mww.__file__))
            m2 = importlib.util.module_from_spec(spec2)
            spec2.loader.exec_module(m2)
        finally:
            os.environ["NEUROOTDEL_GUARD_CONF"] = saved
        return m2.STATIC_LIMITS
    assert load_with('WEIGHT_RULES_KB="35"\nWEIGHT_CLAUDE_KB="50"\n') == {"core/rules.md": 35 * 1024, "CLAUDE.md": 50 * 1024}
    assert load_with('WEIGHT_RULES_KB="x"\nWEIGHT_CLAUDE_KB="0"\n') == {"core/rules.md": 30 * 1024, "CLAUDE.md": 40 * 1024}
    assert mww.STATIC_LIMITS == {"core/rules.md": 30 * 1024, "CLAUDE.md": 40 * 1024}


@case
def fold_text_only_when_rules_are_heavy():
    assert "В ЭТОМ ЖЕ ХОДЕ" not in mww.signal_text([(16 * 1024, "core/hot/handoff.md")], 1)
    t = mww.signal_text([(31 * 1024, "core/rules.md")], 1)
    assert "В ЭТОМ ЖЕ ХОДЕ" in t and "—" not in t


@case
def failed_signal_is_not_reported_as_sent_on_rerun():
    lab, st = env()
    make_agent(lab, "a", rules=RULES_BIG)
    a = Rec()
    go(lab, st, D1, Rec(ok=False), a)
    out = go(lab, st, D1, Rec(), a)
    assert not any("ушёл сигнал свернуть" in l for l in out), out
    assert not any("ушёл сигнал свернуть" in c[1] for c in a.calls), a.calls


@case
def growing_rules_same_day_reports_once():
    lab, st = env()
    make_agent(lab, "a", rules=RULES_BIG)
    a = Rec()
    go(lab, st, D1, Rec(), a)
    make_agent(lab, "a", rules=RULES_BIG + "x" * 2048)
    go(lab, st, D1, Rec(), a)
    assert len(a.calls) == 1, a.calls


@case
def rules_nights_do_not_count_toward_journal_escalation():
    lab, st = env()
    make_agent(lab, "a", rules=RULES_BIG)
    a = Rec()
    go(lab, st, D1, Rec(), a)
    go(lab, st, D2, Rec(), a)
    make_agent(lab, "a", handoff=BIG)
    out = go(lab, st, D3, Rec(), a)
    assert not any("ночей подряд" in l for l in out), out
    assert json.loads(st.read_text())["a"]["days"] == 1


@case
def equivalent_include_path_is_caught():
    lab, st = env()
    make_agent(lab, "a", rules=RULES_BIG)
    md = lab / "a" / ".claude" / "CLAUDE.md"
    md.write_text(md.read_text().replace("@core/rules.md", "@core/../core/rules.md"))
    n = Rec()
    go(lab, st, D1, n)
    assert len(n.calls) == 1 and "rules.md" in n.calls[0][1], n.calls


@case
def clean_then_heavy_rules_same_day_reports_once():
    lab, st = env()
    make_agent(lab, "a", rules=RULES_BIG)
    a = Rec()
    go(lab, st, D1, Rec(), a)
    make_agent(lab, "a")
    go(lab, st, D1, Rec(), a)
    make_agent(lab, "a", rules=RULES_BIG)
    out = go(lab, st, D1, Rec(), a)
    assert len(a.calls) == 1, a.calls
    assert not any("НЕ ушёл" in l for l in out), out


@case
def rules_growth_does_not_repeat_journal_escalation():
    lab, st = env()
    make_agent(lab, "a", handoff=BIG)
    a = Rec()
    go(lab, st, D1, Rec(), a)
    go(lab, st, D2, Rec(), a)
    make_agent(lab, "a", handoff=BIG, rules=RULES_BIG)
    go(lab, st, D3, Rec(), a)
    n_before = sum("ночей подряд" in c[1] for c in a.calls)
    make_agent(lab, "a", handoff=BIG, rules=RULES_BIG + "x" * 2048)
    go(lab, st, D3, Rec(), a)
    assert sum("ночей подряд" in c[1] for c in a.calls) == n_before == 1, a.calls


@case
def as_root_weighing_runs_as_agent_user_with_timeout():
    import subprocess
    lab, st = env()
    make_agent(lab, "a", rules=RULES_BIG)
    seen = []
    real_run = subprocess.run

    def fake_run(cmd, **kw):
        seen.append((cmd, kw))
        return real_run(cmd[cmd.index("--") + 1:], **kw)  # same child (under timeout), without runuser

    saved = mww.os.geteuid, mww.subprocess.run
    mww.os.geteuid, mww.subprocess.run = (lambda: 0), fake_run
    try:
        n = Rec()
        go(lab, st, D1, n)
    finally:
        mww.os.geteuid, mww.subprocess.run = saved
    assert seen and seen[0][0][:7] == ["runuser", "-u", "agentuser", "--", "timeout", "-s", "KILL"], seen
    assert seen[0][1].get("timeout") == mww.WEIGH_TIMEOUT
    assert len(n.calls) == 1 and "rules.md: 31 КБ" in n.calls[0][1], n.calls


@case
def as_root_hung_weighing_is_reported_not_waited():
    import subprocess
    lab, st = env()
    make_agent(lab, "a", rules=RULES_BIG)

    def hang(cmd, **kw):
        raise subprocess.TimeoutExpired(cmd, kw.get("timeout"))

    saved = mww.os.geteuid, mww.subprocess.run
    mww.os.geteuid, mww.subprocess.run = (lambda: 0), hang
    try:
        n = Rec()
        out = go(lab, st, D1, n)
    finally:
        mww.os.geteuid, mww.subprocess.run = saved
    assert n.calls == [] and out == ["- a: память не взвешена (OSError)"], out


@case
def auto_runs_only_in_the_owner_four_oclock_hour():
    from datetime import datetime as real_dt
    tmp = Path(tempfile.mkdtemp())
    orig = mww.STATE_DIR, mww.LOCK_FILE, mww.STOP_FILE, mww.run, mww.datetime
    mww.STATE_DIR, mww.LOCK_FILE, mww.STOP_FILE = tmp, tmp / ".lock", tmp / "STOP"
    called = []
    mww.run = lambda *a, **k: called.append(1) or []

    class At:
        hour = 3

        @classmethod
        def now(cls, tz=None):
            return real_dt(2026, 10, 29, cls.hour, 20, tzinfo=tz)

        strptime = real_dt.strptime
    mww.datetime = At
    try:
        assert mww.main(["--auto"]) == 0 and called == []
        At.hour = 4
        assert mww.main(["--auto"]) == 0 and called == [1]
        assert mww.main(["--bogus"]) == 2
    finally:
        mww.STATE_DIR, mww.LOCK_FILE, mww.STOP_FILE, mww.run, mww.datetime = orig


@case
def recent_md_uses_its_own_cap():
    lab, st = env()
    make_agent(lab, "a")
    hot = lab / "a" / ".claude" / "core" / "hot"
    (hot / "recent.md").write_text("x" * (19 * 1024))
    md = lab / "a" / ".claude" / "CLAUDE.md"
    md.write_text(md.read_text() + "@core/hot/recent.md\n")
    n = Rec()
    assert go(lab, st, D1, n) == [] and n.calls == [], n.calls


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
