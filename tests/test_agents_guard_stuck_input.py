#!/usr/bin/env python3
"""Tests for lib/agents-guard.py part 2b, Enter on a received message stuck in the input box.

Run: python3 tests/test_agents_guard_stuck_input.py   (no network, no root, no tmux)
"""
from __future__ import annotations

import importlib.util
import os
import sys
import tempfile
import types
import unittest
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
spec = importlib.util.spec_from_file_location("ag_input", LIB / "agents-guard.py")
ag = importlib.util.module_from_spec(spec)
sys.modules["ag_input"] = ag
spec.loader.exec_module(ag)

FRAME = "─" * 60
FOOT = "  ⏵⏵ bypass permissions on (shift+tab to cycle)"


def pane(box: str, above: str = "✻ Worked for 3s") -> str:
    return f"{above}\n{FRAME}\n{box}\n{FRAME}\n{FOOT}\n"


MSG = "❯ привет, пришли подборку за неделю"
STUCK = pane(MSG)
# the same message in a colour snapshot: typed text is drawn in a colour (38;5;244), not dim
STUCK_COLOUR = pane("\x1b[39m❯\xa0\x1b[38;5;244mпривет, пришли подборку за неделю\x1b[39m")
# a CLI prompt suggestion: in the plain snapshot it looks like typed text, only SGR 2 tells it apart
HINT_PLAIN = pane("❯ проверь почту")
HINT_COLOUR = pane("\x1b[39m❯\xa0\x1b[2mпроверь почту\x1b[22m")
EMPTY = pane("❯ ")
WORKING = "❯ привет\n✻ Thinking… (12s · ↓ 300 tokens · esc to interrupt)\n"
QUESTION = (" Bash command\n   │ rm -rf build │\n Do you want to proceed?\n ❯ 1. Yes\n   2. No\n"
            " Esc to cancel · Tab to amend\n")
LIMIT = pane(MSG) + "  ⚠ Usage limit reached · limit resets 11:30pm\n    Continuing automatically at 11:30pm\n"
WRAPPED_A = pane("❯ первая строка длинного сообщения\n  хвост А")
WRAPPED_B = pane("❯ первая строка длинного сообщения\n  хвост Б")


class Clock:
    def __init__(self, t: int = 1_800_000_000) -> None:
        self.t = t

    def time(self) -> float:
        return float(self.t)


class G(ag.Guard):
    def __init__(self, dry: bool = False) -> None:
        super().__init__(dry, {})
        self.persist = False
        self.state, self.seen = {}, set()
        self.pressed: list[str] = []
        self.alerts: list[tuple[str, str]] = []
        self.press_ok = True

    def save(self) -> None:
        pass

    def press_enter(self, agent: str) -> bool:
        self.pressed.append(agent)
        return self.press_ok

    def alert(self, key: str, text: str, test: bool = False) -> None:
        self.seen.add(key)
        self.alerts.append((key, text))


class Base(unittest.TestCase):
    def setUp(self) -> None:
        self.clock = Clock()
        self.saved = (ag.time, ag.capture_colour, ag.STATE_DIR, ag.run, ag.unit_active, ag.unit_since)
        ag.time = types.SimpleNamespace(time=self.clock.time, sleep=lambda s: None)
        self.colour = STUCK_COLOUR
        ag.capture_colour = lambda agent, ov: self.colour
        ag.STATE_DIR = Path(tempfile.mkdtemp())
        self.g = G()
        self.st: dict = {}

    def tearDown(self) -> None:
        ag.time, ag.capture_colour, ag.STATE_DIR, ag.run, ag.unit_active, ag.unit_since = self.saved

    def tick(self, plain: str = STUCK, after: int = 60) -> None:
        self.clock.t += after
        self.g.do_input("jarvis", plain, self.st)


class Classify(Base):
    def test_typed_message(self) -> None:
        got = ag.stuck_input(STUCK)
        self.assertIsNotNone(got)
        self.assertEqual(got[1], "привет, пришли подборку за неделю")

    def test_colour_message_same_signature(self) -> None:
        self.assertEqual(ag.stuck_input(STUCK_COLOUR)[0], ag.stuck_input(STUCK)[0])

    def test_dim_suggestion_is_not_a_message(self) -> None:
        self.assertIsNone(ag.stuck_input(HINT_COLOUR))

    def test_empty_box(self) -> None:
        self.assertIsNone(ag.stuck_input(EMPTY))

    def test_running_turn(self) -> None:
        self.assertIsNone(ag.stuck_input(WORKING))

    def test_permission_question(self) -> None:
        self.assertIsNone(ag.stuck_input(QUESTION))

    def test_none_and_blank(self) -> None:
        self.assertIsNone(ag.stuck_input(None))
        self.assertIsNone(ag.stuck_input("\n  \n"))

    def test_wrapped_message_tail_in_signature(self) -> None:
        a, b = ag.stuck_input(WRAPPED_A), ag.stuck_input(WRAPPED_B)
        self.assertNotEqual(a[0], b[0])
        self.assertIn("хвост А", a[1])

    def test_colour_digit_two_is_not_dim(self) -> None:
        self.assertIsNotNone(ag.stuck_input(pane("❯ \x1b[38;2;200;200;200mпривет\x1b[0m")))


class Nudge(Base):
    def test_waits_before_pressing(self) -> None:
        self.tick(after=0)
        self.tick(after=60)
        self.assertEqual(self.g.pressed, [])
        self.assertIn("inp", self.st)

    def test_presses_after_threshold(self) -> None:
        self.tick(after=0)
        self.tick(after=ag.INPUT_NUDGE_AFTER)
        self.assertEqual(self.g.pressed, ["jarvis"])
        self.assertEqual(self.st["inp"][2], 1)

    def test_three_presses_then_one_alert(self) -> None:
        self.tick(after=0)
        for _ in range(12):  # 12 minutes of ticks
            self.tick(after=60)
        self.assertEqual(len(self.g.pressed), ag.INPUT_NUDGE_MAX)
        # one condition key (Guard.alert publishes a key once until the condition clears)
        self.assertTrue(self.g.alerts)
        self.assertEqual(len({k for k, _ in self.g.alerts}), 1)
        key, text = self.g.alerts[0]
        self.assertTrue(key.startswith("stuckinput:jarvis:"))
        self.assertIn(f"Enter нажат {ag.INPUT_NUDGE_MAX} раз", text)

    def test_presses_spaced_by_gap(self) -> None:
        self.tick(after=0)
        self.tick(after=ag.INPUT_NUDGE_AFTER)
        self.tick(after=60)
        self.assertEqual(len(self.g.pressed), 1)
        self.tick(after=60)
        self.assertEqual(len(self.g.pressed), 2)

    def test_suggestion_never_pressed_never_alerted(self) -> None:
        self.colour = HINT_COLOUR
        self.tick(HINT_PLAIN, after=0)
        for _ in range(15):
            self.tick(HINT_PLAIN, after=60)
        self.assertEqual(self.g.pressed, [])
        self.assertEqual(self.g.alerts, [])

    def test_question_on_fresh_snapshot_not_pressed(self) -> None:
        self.colour = QUESTION
        self.tick(after=0)
        self.tick(after=ag.INPUT_NUDGE_AFTER)
        self.assertEqual(self.g.pressed, [])
        self.assertNotIn("inp", self.st)

    def test_changed_text_on_fresh_snapshot_not_pressed(self) -> None:
        self.colour = pane("❯ другой текст")
        self.tick(after=0)
        self.tick(after=ag.INPUT_NUDGE_AFTER)
        self.assertEqual(self.g.pressed, [])

    def test_fresh_snapshot_missing_not_pressed_count_kept(self) -> None:
        self.colour = None
        self.tick(after=0)
        self.tick(after=ag.INPUT_NUDGE_AFTER)
        self.assertEqual(self.g.pressed, [])
        self.assertIn("inp", self.st)

    def test_fresh_snapshot_raising_not_pressed(self) -> None:
        def boom(agent, ov):
            raise OSError("tmux gone")
        ag.capture_colour = boom
        self.tick(after=0)
        self.tick(after=ag.INPUT_NUDGE_AFTER)
        self.assertEqual(self.g.pressed, [])

    def test_off_switch(self) -> None:
        (ag.STATE_DIR / "INPUT_NUDGE_OFF").touch()
        self.tick(after=0)
        self.tick(after=ag.INPUT_NUDGE_AFTER)
        self.assertEqual(self.g.pressed, [])
        self.assertNotIn("inp", self.st)

    def test_limit_pause_not_pressed(self) -> None:
        self.tick(LIMIT, after=0)
        self.tick(LIMIT, after=ag.INPUT_NUDGE_AFTER)
        self.assertEqual(self.g.pressed, [])

    def test_running_turn_clears(self) -> None:
        self.tick(after=0)
        self.tick(WORKING, after=60)
        self.assertNotIn("inp", self.st)

    def test_new_message_restarts_count(self) -> None:
        self.tick(after=0)
        self.tick(after=ag.INPUT_NUDGE_AFTER)
        other = pane("❯ новое сообщение")
        self.colour = other
        self.tick(other, after=60)
        self.assertEqual(self.st["inp"][2], 0)
        self.assertEqual(len(self.g.pressed), 1)

    def test_failed_press_still_alerts(self) -> None:
        self.g.press_ok = False
        self.tick(after=0)
        for _ in range(12):
            self.tick(after=60)
        self.assertEqual(self.st["inp"][2], 0)
        self.assertTrue(self.g.alerts)
        self.assertIn("Enter нажат 0 раз", self.g.alerts[0][1])

    def test_missing_snapshot_keeps_count(self) -> None:
        self.tick(after=0)
        for _ in range(6):  # three presses at 120/240/360 s
            self.tick(after=60)
        self.assertEqual(len(self.g.pressed), ag.INPUT_NUDGE_MAX)
        self.g.do_input("jarvis", None, self.st)  # tmux did not answer this tick
        self.assertEqual(self.st["inp"][2], ag.INPUT_NUDGE_MAX)
        for _ in range(4):
            self.tick(after=60)
        self.assertEqual(len(self.g.pressed), ag.INPUT_NUDGE_MAX)
        self.assertTrue(self.g.alerts)

    def test_failed_press_alerts_at_threshold_with_slow_ticks(self) -> None:
        self.g.press_ok = False
        self.tick(after=0)
        for _ in range(5):  # ticks every 120 s: 120 .. 600
            self.tick(after=120)
        self.assertTrue(self.g.alerts)
        self.assertIn("Enter нажат 0 раз", self.g.alerts[0][1])

    def test_numbered_line_change_is_new_message(self) -> None:
        a = pane("❯ выполни список\n  1. задача А")
        b = pane("❯ выполни список\n  1. задача Б")
        self.assertNotEqual(ag.stuck_input(a)[0], ag.stuck_input(b)[0])
        self.assertIn("1. задача А", ag.stuck_input(a)[1])
        self.colour = b
        self.tick(a, after=0)
        self.tick(a, after=ag.INPUT_NUDGE_AFTER)
        self.assertEqual(self.g.pressed, [])

    def test_long_message_found_by_its_frames(self) -> None:
        body = "\n".join(f"  строка {n}" for n in range(1, 16))
        long = pane(f"❯ начало длинного сообщения\n{body}")
        got = ag.stuck_input(long)
        self.assertIsNotNone(got)
        self.assertIn("строка 15", got[1])
        self.colour = long
        self.tick(long, after=0)
        self.tick(long, after=ag.INPUT_NUDGE_AFTER)
        self.assertEqual(self.g.pressed, ["jarvis"])

    def test_alert_even_when_last_press_succeeds(self) -> None:
        self.g.press_ok = False
        self.tick(after=0)
        for _ in range(4):  # failures at 120 .. 480 s
            self.tick(after=120)
        self.assertEqual(self.g.alerts, [])
        self.g.press_ok = True  # tmux takes the key at 600 s, the message stays in the box
        self.tick(after=120)
        self.assertEqual(self.g.pressed[-1], "jarvis")
        self.assertTrue(self.g.alerts)

    def test_turn_started_between_snapshots_not_pressed(self) -> None:
        self.colour = pane(MSG, above="✻ Thinking… (3s · ↓ 10 tokens · esc to interrupt)")
        self.tick(after=0)
        self.tick(after=ag.INPUT_NUDGE_AFTER)
        self.assertEqual(self.g.pressed, [])

    def test_arrow_line_inside_box_is_message_text(self) -> None:
        a = pane("❯ сравни\n  ❯ вариант А")
        b = pane("❯ сравни\n  ❯ вариант Б")
        self.assertNotEqual(ag.stuck_input(a)[0], ag.stuck_input(b)[0])
        self.colour = b
        self.tick(a, after=0)
        self.tick(a, after=ag.INPUT_NUDGE_AFTER)
        self.assertEqual(self.g.pressed, [])

    def test_rule_line_inside_box_is_message_text(self) -> None:
        a = pane("❯ сравни варианты\n  ───\n  вариант А")
        b = pane("❯ сравни варианты\n  ───\n  вариант Б")
        self.assertIn("вариант А", ag.stuck_input(a)[1])
        self.assertNotEqual(ag.stuck_input(a)[0], ag.stuck_input(b)[0])
        self.colour = b
        self.tick(a, after=0)
        self.tick(a, after=ag.INPUT_NUDGE_AFTER)
        self.assertEqual(self.g.pressed, [])

    def test_rule_and_arrow_inside_box_keep_the_start(self) -> None:
        a = pane("❯ сравни вариант А\n  ───\n  ❯ общий хвост")
        b = pane("❯ сравни вариант Б\n  ───\n  ❯ общий хвост")
        self.assertIn("сравни вариант А", ag.stuck_input(a)[1])
        self.assertNotEqual(ag.stuck_input(a)[0], ag.stuck_input(b)[0])
        self.colour = b
        self.tick(a, after=0)
        self.tick(a, after=ag.INPUT_NUDGE_AFTER)
        self.assertEqual(self.g.pressed, [])

    def test_bad_state_record_reset(self) -> None:
        sig = ag.stuck_input(STUCK)[0]
        for bad in ([sig, True, 0, 0], [sig, 10**12 * 10, 0, 0], [sig, 1, 99, 0], "x", [sig, 1]):
            self.st = {"inp": bad}
            self.tick(after=60)
            self.assertEqual(self.st["inp"][2], 0, bad)
            self.assertEqual(self.st["inp"][1], self.clock.t, bad)
        self.assertEqual(self.g.pressed, [])


class Press(Base):
    def test_dry_run_runs_nothing(self) -> None:
        def fail(cmd, timeout=30):
            raise AssertionError("dry run must not call tmux")
        ag.run = fail
        self.assertTrue(ag.Guard.press_enter(G(dry=True), "jarvis"))

    def test_real_press_is_enter_in_agent_session(self) -> None:
        calls = []
        ag.run = lambda cmd, timeout=30: calls.append(cmd) or types.SimpleNamespace(returncode=0)
        self.assertTrue(ag.Guard.press_enter(G(), "coder"))
        self.assertEqual(calls, [["runuser", "-u", "agentuser", "--", "tmux", "-L", "channel-coder",
                                  "send-keys", "-t", "channel-coder", "Enter"]])


class ThroughDoAgent(Base):
    """do_agent calls part 2b only when there is no permission question."""

    def setUp(self) -> None:
        super().setUp()
        ag.unit_active = lambda unit: True
        ag.unit_since = lambda unit: 0.0  # started long ago: not young
        sig = ag.stuck_input(STUCK)[0]
        self.g.state = {"agents": {"jarvis": {"inp": [sig, self.clock.t - 300, 0, 0]}}}

    def test_stuck_pressed(self) -> None:
        self.g.do_agent("jarvis", STUCK)
        self.assertEqual(self.g.pressed, ["jarvis"])

    def test_question_never_pressed(self) -> None:
        self.colour = QUESTION
        self.g.do_agent("jarvis", QUESTION)
        self.assertEqual(self.g.pressed, [])


if __name__ == "__main__":
    unittest.main(verbosity=1)
