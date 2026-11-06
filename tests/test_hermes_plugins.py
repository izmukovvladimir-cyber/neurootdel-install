#!/usr/bin/env python3
"""Tests for the Auditor's Hermes plugins (templates/hermes-plugins): readonly, secretguard, factcheck.

No Hermes needed: each plugin is imported from its folder and its hooks are called the way the engine calls them
(keyword arguments, the same names the engine passes). The vendored rules are compared with their sources so the
copies can not drift. Run: python3 tests/test_hermes_plugins.py
"""
from __future__ import annotations

import ast
import importlib.util
import json
import os
import re
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True   # no __pycache__ inside templates/ (the installer copies plugin folders)
REPO = Path(__file__).resolve().parent.parent
PLUGINS = REPO / "templates" / "hermes-plugins"
_HOME = tempfile.TemporaryDirectory()
os.environ["HOME"] = _HOME.name   # plugins log under ~/.hermes/logs: keep it in a temp dir
os.environ.pop("HERMES_HOME", None)


def load(name: str):
    spec = importlib.util.spec_from_file_location(f"plug_{name}", PLUGINS / name / "__init__.py",
                                                  submodule_search_locations=[str(PLUGINS / name)])
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    return mod


def assigned_sources(path: Path, names: set[str]) -> dict[str, str]:
    """Source text of top-level assignments NAME = ... (whitespace-normalised)."""
    text = path.read_text(encoding="utf-8")
    out = {}
    for node in ast.parse(text).body:
        targets = node.targets if isinstance(node, ast.Assign) else [node.target] if isinstance(node, ast.AnnAssign) else []
        for t in targets:
            if isinstance(t, ast.Name) and t.id in names:
                out[t.id] = re.sub(r"\s+", " ", ast.get_source_segment(text, node.value) or "")
    return out


class Ctx:
    def __init__(self) -> None:
        self.hooks: dict[str, object] = {}

    def register_hook(self, name: str, fn: object) -> None:
        self.hooks[name] = fn


class Manifests(unittest.TestCase):
    def test_manifest_matches_registered_hooks(self) -> None:
        for name in ("readonly", "secretguard", "factcheck"):
            manifest = (PLUGINS / name / "plugin.yaml").read_text(encoding="utf-8")
            self.assertRegex(manifest, rf"(?m)^name: {name}$")
            declared = set(re.findall(r"(?m)^  - (\w+)$", manifest))
            ctx = Ctx()
            load(name).register(ctx)
            self.assertEqual(declared, set(ctx.hooks), name)

    def test_no_personal_names_or_hosts(self) -> None:
        bad = re.compile(r"Светлан|Николай|Юли|Виктори|Владимир|neurootdel-swarm|\b\d{1,3}(?:\.\d{1,3}){3}\b|gosteva")
        for path in PLUGINS.rglob("*"):
            if path.is_file() and path.suffix in (".py", ".yaml"):
                self.assertIsNone(bad.search(path.read_text(encoding="utf-8")), str(path))


class Readonly(unittest.TestCase):
    def setUp(self) -> None:
        self.m = load("readonly")

    def test_write_tools_blocked(self) -> None:
        for tool in ("write_file", "patch"):
            res = self.m.on_pre_tool_call(tool_name=tool, args={"path": "/x"}, session_id="s")
            self.assertEqual(res["action"], "block")
            self.assertIn("только читает", res["message"])

    def test_cron_only_list(self) -> None:
        self.assertIsNone(self.m.on_pre_tool_call(tool_name="cronjob_manage", args={"action": "list"}))
        self.assertEqual(self.m.on_pre_tool_call(tool_name="cronjob_manage", args={"action": "create"})["action"],
                         "block")

    def test_reading_untouched(self) -> None:
        for tool in ("read_file", "search_files", "terminal", "web_search"):
            self.assertIsNone(self.m.on_pre_tool_call(tool_name=tool, args={"path": "/x"}))


class Secretguard(unittest.TestCase):
    TOKEN = "123456789:AAHabcdefghijklmnopqrstuvwxyz012345"

    def setUp(self) -> None:
        self.m = load("secretguard")

    def test_patterns_identical_to_claude_guard(self) -> None:
        mine = assigned_sources(PLUGINS / "secretguard" / "__init__.py", {"PATTERNS"})
        theirs = assigned_sources(REPO / "templates" / "secret-outbound-guard.py", {"PATTERNS"})
        self.assertTrue(theirs.get("PATTERNS"))
        self.assertEqual(mine, theirs)

    def test_answer_with_token_replaced_and_reminded(self) -> None:
        out = self.m.on_transform_llm_output(response_text=f"вот токен {self.TOKEN}", session_id="s1")
        self.assertEqual(out, self.m.STUB)
        self.assertNotIn(self.TOKEN, out)
        self.assertEqual(self.m.on_pre_llm_call(session_id="s1"), {"context": self.m.REMIND})
        self.assertIsNone(self.m.on_pre_llm_call(session_id="s1"))

    def test_clean_answer_passes(self) -> None:
        self.assertIsNone(self.m.on_transform_llm_output(response_text="Пароль лежит в панели, значение не повторяю."))

    def test_outbound_tool_blocked(self) -> None:
        res = self.m.on_pre_tool_call(tool_name="send_message", args={"message": f"key {self.TOKEN}"})
        self.assertEqual(res["action"], "block")
        self.assertNotIn(self.TOKEN, res["message"])
        self.assertIsNone(self.m.on_pre_tool_call(tool_name="read_file", args={"path": self.TOKEN}))

    def test_log_never_has_value(self) -> None:
        self.m.on_transform_llm_output(response_text=f"t {self.TOKEN}", session_id="s2")
        self.assertNotIn(self.TOKEN, self.m.LOG_PATH.read_text(encoding="utf-8"))

    def test_install_secret_matched_literally(self) -> None:
        key = "ab12" * 16
        env = Path(_HOME.name) / ".hermes" / ".env"
        env.parent.mkdir(parents=True, exist_ok=True)
        env.write_text(f"API_SERVER_KEY={key}\nAPI_SERVER_PORT=8642\nTELEGRAM_ALLOWED_USERS=555\n")
        self.assertEqual(self.m.on_transform_llm_output(response_text=f"ключ {key}", session_id="k"), self.m.STUB)
        self.assertEqual(self.m.on_pre_tool_call(tool_name="send_message", args={"message": key})["action"], "block")
        self.assertIsNone(self.m.on_transform_llm_output(response_text="порт 8642, пользователь 555"))
        self.assertNotIn(key, self.m.LOG_PATH.read_text(encoding="utf-8"))
        env.unlink()

    def test_too_deep_fails_closed(self) -> None:
        deep: object = "x"
        for _ in range(30):
            deep = [deep]
        self.assertEqual(self.m.on_pre_tool_call(tool_name="mcp_x_notify", args={"a": deep})["action"], "block")


class Factcheck(unittest.TestCase):
    FACT = "Сервис работает, ошибок 0."
    READ_OK = json.dumps({"content": "1|строка лога о работе сервиса\n2|ещё одна строка"})

    def setUp(self) -> None:
        self.m = load("factcheck")

    def read(self, sid: str, tid: str, result: str | None = None, path: str = "/var/log/x.log") -> None:
        self.m.on_post_tool_call(tool_name="read_file", args={"path": path}, result=result or self.READ_OK,
                                 session_id=sid, turn_id=tid)

    def test_vendored_rules_identical_to_gate(self) -> None:
        names = {"STATUS_RE", "CANT_RE", "NEWS_RE", "LONG_FACT_CHARS"}
        mine = assigned_sources(PLUGINS / "factcheck" / "__init__.py", names)
        theirs = assigned_sources(REPO / "lib" / "hooks" / "fact-check-gate.py", names)
        self.assertEqual(set(theirs), names)
        self.assertEqual(mine, theirs)

    def test_fact_without_read_is_stubbed_then_reminded(self) -> None:
        out = self.m.on_transform_llm_output(response_text=self.FACT, session_id="a", turn_id="1", platform="telegram")
        self.assertEqual(out, self.m.STUB)
        self.assertEqual(self.m.on_pre_llm_call(session_id="a"), {"context": self.m.REMIND})
        self.assertIsNone(self.m.on_pre_llm_call(session_id="a"))

    def test_fact_after_read_in_same_turn_passes(self) -> None:
        self.read("b", "1")
        self.assertIsNone(self.m.on_transform_llm_output(response_text=self.FACT, session_id="b", turn_id="1"))

    def test_read_in_other_turn_does_not_count(self) -> None:
        self.read("c", "1")
        self.assertEqual(self.m.on_transform_llm_output(response_text=self.FACT, session_id="c", turn_id="2"),
                         self.m.STUB)

    def test_failed_or_empty_read_does_not_count(self) -> None:
        self.read("d", "1", result=json.dumps({"error": "No such file"}))
        self.read("d", "1", result=json.dumps({"content": "1|"}))
        self.m.on_post_tool_call(tool_name="terminal", args={"command": "cat /x"}, result="ok ok ok",
                                 session_id="d", turn_id="1")
        self.assertEqual(self.m.on_transform_llm_output(response_text=self.FACT, session_id="d", turn_id="1"),
                         self.m.STUB)

    def test_agent_letter_is_not_a_source(self) -> None:
        self.read("e", "1", path="/home/u/var/lib/auditor-bus/inbox/x.json")
        self.assertEqual(self.m.on_transform_llm_output(response_text=self.FACT, session_id="e", turn_id="1"),
                         self.m.STUB)

    def test_plain_text_passes(self) -> None:
        self.assertIsNone(self.m.on_transform_llm_output(response_text="Какой отчёт посмотреть? Дайте путь к файлу.",
                                                         session_id="f", turn_id="1"))
        self.assertTrue(self.m.has_fact("по данным аналитика всё хорошо"))
        self.assertTrue(self.m.has_fact("а" * 300))

    def test_send_tool_blocked_until_read(self) -> None:
        res = self.m.on_pre_tool_call(tool_name="send_message", args={"message": self.FACT}, session_id="g",
                                      turn_id="1")
        self.assertEqual(res["action"], "block")
        self.read("g", "1")
        self.assertIsNone(self.m.on_pre_tool_call(tool_name="send_message", args={"message": self.FACT},
                                                  session_id="g", turn_id="1"))

    def test_subagent_not_checked(self) -> None:
        self.m.on_subagent_start(child_session_id="child")
        self.assertIsNone(self.m.on_transform_llm_output(response_text=self.FACT, session_id="child", turn_id="1"))
        self.assertIsNone(self.m.on_transform_llm_output(response_text=self.FACT, session_id="x", platform="subagent"))

    def test_checker_bug_fails_open(self) -> None:
        orig = self.m.has_fact
        self.m.has_fact = lambda _t: 1 / 0
        try:
            self.assertIsNone(self.m.on_transform_llm_output(response_text=self.FACT, session_id="h", turn_id="1"))
        finally:
            self.m.has_fact = orig

    def test_log_has_hash_not_text(self) -> None:
        self.m.on_transform_llm_output(response_text="Секретная фраза 12345", session_id="i", turn_id="1")
        log = self.m.LOG_PATH.read_text(encoding="utf-8")
        self.assertNotIn("Секретная фраза", log)
        self.assertIn('"verdict": "fact-unread"', log)


if __name__ == "__main__":
    unittest.main(verbosity=1)
