#!/usr/bin/env python3
"""Tests for paragraph-gate.py (run: python3 test_paragraph_gate.py). Uses a temp state dir."""
import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent / "lib" / "hooks"
GATE = HERE / "paragraph-gate.py"
spec = importlib.util.spec_from_file_location("paragraph_gate", GATE)
pg = importlib.util.module_from_spec(spec)
sys.modules["paragraph_gate"] = pg
spec.loader.exec_module(pg)

WALL = ("Анна, по задаче коротко: я проверил все источники, сверил цифры с отчётом за неделю, "
        "нашёл два расхождения в охватах и одно в подписчиках, поправил таблицу, записал правило в "
        "память, чтобы в следующий раз не повторять ту же ошибку, и отдельно передал редактору поправку "
        "по тексту поста, потому что там было слово, которое вы просили не использовать, а ещё "
        "подготовил черновик на завтра и поставил его в очередь на утро, жду вашего слова.")
PARAGRAPHS = ("Анна, по задаче коротко.\n\n"
              "Источники проверил, цифры сверил с отчётом за неделю. Нашёл два расхождения в охватах.\n\n"
              "Таблицу поправил, правило записал в память, чтобы ошибка не повторилась.\n\n"
              "редактору передал поправку по тексту поста: там было слово, которое вы просили не писать.\n\n"
              "Черновик на завтра готов и стоит в очереди на утро. Жду вашего слова.")
CHECKLIST = ("Анна, план на завтра по каналу и по рилсам, всё по порядку:\n"
             "1. Утром собираю новости из источников и отбираю три.\n"
             "2. К 10:00 черновик первого поста вам в личку.\n"
             "3. После «да» публикую в медиа-канал.\n"
             "4. Дизайнер готовит обложку и подпись к рилсу.\n"
             "5. В 14:00 второй пост, тема из вашего списка.\n"
             "6. Вечером сводка охватов за день.\n"
             "7. Правки по стилю записываю в правила.")
LONG_LIST_SHORT = "Каналы для новостей:\n" + "\n".join(f"{i}. Канал номер {i}" for i in range(1, 30))
LONG_ITEMS = "Пять вопросов:\n" + "\n".join(f"{i}. " + "Очень длинный пункт без перерыва " * 8 for i in range(1, 6))
CODE = ("Анна, вот команда для проверки, вставьте её целиком:\n\n```\n"
        + "\n".join(f"echo line {i} with some padding text to make it longer" for i in range(1, 15))
        + "\n```\n\nПосле запуска пришлите мне вывод, я разберу.")


def run_hook(state: Path, tool: str, args: dict) -> str:
    payload = json.dumps({"tool_name": tool, "tool_input": args}, ensure_ascii=False)
    done = subprocess.run([sys.executable, str(GATE), str(state)], input=payload, capture_output=True,
                          text=True, timeout=10, check=True)
    return done.stdout


class DecideTest(unittest.TestCase):
    def test_wall_blocks(self) -> None:
        self.assertFalse(pg.decide(WALL).allow)

    def test_wall_of_many_lines_blocks(self) -> None:
        text = "\n".join(["Первая мысль, и она довольно длинная, чтобы не быть пунктом списка, правда."] * 6)
        v = pg.decide(text)
        self.assertFalse(v.allow)
        self.assertEqual(v.why, "lines")

    def test_paragraphs_pass(self) -> None:
        self.assertTrue(pg.decide(PARAGRAPHS).allow)

    def test_short_one_line_passes(self) -> None:
        self.assertTrue(pg.decide("Принял, делаю.").allow)

    def test_checklist_passes(self) -> None:
        self.assertTrue(pg.decide(CHECKLIST).allow)

    def test_long_list_of_short_items_passes(self) -> None:
        self.assertTrue(pg.decide(LONG_LIST_SHORT).allow)

    def test_list_of_long_items_blocks(self) -> None:
        v = pg.decide(LONG_ITEMS)
        self.assertFalse(v.allow)
        self.assertEqual(v.why, "list_item_long")

    def test_code_block_ignored(self) -> None:
        self.assertTrue(pg.decide(CODE).allow)

    def test_wall_after_code_still_blocks(self) -> None:
        self.assertFalse(pg.decide(CODE + "\n\n" + WALL).allow)


class HookTest(unittest.TestCase):
    def setUp(self) -> None:
        self.state = Path(tempfile.mkdtemp())

    def events(self) -> list[dict]:
        with (self.state / "events.jsonl").open(encoding="utf-8") as fh:
            return [json.loads(line) for line in fh]

    def test_deny_output_and_log_without_text(self) -> None:
        out = run_hook(self.state, "mcp__dashi-channel__reply", {"chat_id": "1", "text": WALL})
        res = json.loads(out)["hookSpecificOutput"]
        self.assertEqual(res["permissionDecision"], "deny")
        self.assertIn("разбей на абзацы", res["permissionDecisionReason"])
        row = self.events()[-1]
        self.assertEqual(row["verdict"], "deny")
        self.assertNotIn("Анна", json.dumps(row, ensure_ascii=False))

    def test_edit_message_checked(self) -> None:
        out = run_hook(self.state, "mcp__dashi-channel__edit_message", {"chat_id": "1", "message_id": "2",
                                                                         "text": WALL})
        self.assertIn("deny", out)

    def test_allow_is_silent(self) -> None:
        out = run_hook(self.state, "mcp__dashi-channel__reply", {"chat_id": "1", "text": PARAGRAPHS,
                                                                 "files": ["/tmp/x.pdf"]})
        self.assertEqual(out, "")
        self.assertEqual(self.events()[-1]["files"], 1)

    def test_stop_file(self) -> None:
        (self.state / "STOP").touch()
        out = run_hook(self.state, "mcp__dashi-channel__reply", {"chat_id": "1", "text": WALL})
        self.assertEqual(out, "")
        self.assertFalse((self.state / "events.jsonl").exists())

    def test_other_tool_ignored(self) -> None:
        self.assertEqual(run_hook(self.state, "Bash", {"command": WALL}), "")

    def test_bad_input_fails_open(self) -> None:
        done = subprocess.run([sys.executable, str(GATE), str(self.state)], input="not json",
                              capture_output=True, text=True, timeout=10)
        self.assertEqual((done.returncode, done.stdout), (0, ""))



class ConfTest(unittest.TestCase):
    """guard.conf switches and the all-agents STOP of the installer layout."""

    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp())
        self.state = self.root / "state" / "jarvis" / "paragraph-gate"
        self.state.mkdir(parents=True)

    def run_with(self, conf_text: str, text: str) -> str:
        conf = self.root / "guard.conf"
        conf.write_text(conf_text, encoding="utf-8")
        payload = json.dumps({"tool_name": "mcp__dashi-channel__reply", "tool_input": {"chat_id": "1", "text": text}},
                             ensure_ascii=False)
        env = {"NEUROOTDEL_GUARD_CONF": str(conf), "PATH": "/usr/bin:/bin"}
        return subprocess.run([sys.executable, str(GATE), str(self.state)], input=payload, capture_output=True,
                              text=True, timeout=10, check=True, env=env).stdout

    def test_default_on(self) -> None:
        self.assertIn("deny", self.run_with("", WALL))

    def test_switched_off(self) -> None:
        self.assertEqual(self.run_with('PARAGRAPH_GATE="0"\n', WALL), "")

    def test_min_total_from_conf(self) -> None:
        self.assertEqual(self.run_with(f'PARAGRAPH_GATE_MIN_TOTAL="{len(WALL) + 10}"\n', WALL), "")

    def test_bad_min_total_falls_back(self) -> None:
        self.assertIn("deny", self.run_with('PARAGRAPH_GATE_MIN_TOTAL="abc"\n', WALL))

    def test_all_agents_stop(self) -> None:
        (self.root / "state" / "paragraph-gate.STOP").touch()
        self.assertEqual(self.run_with("", WALL), "")


if __name__ == "__main__":
    unittest.main()
