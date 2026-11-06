#!/usr/bin/env python3
"""Tests for the Auditor's factcheck plugin, shared-memory part (templates/hermes-plugins/factcheck).

1) A successful read of the shared memory (gbrain recall server: recall, get) is a source, like read_file: an answer
   after it is not stubbed. Empty results, other recall tools, batches and swarm letters are not a read.
2) Four exact template answers (empty recall, null get, failed call, refusal) pass only as the whole answer and only
   when their event happened in this turn; the turn record is born in pre_llm_call and closed by the final answer.

No Hermes needed: hooks are called the way the engine calls them. All data synthetic.
Run: python3 tests/test_factcheck_c3.py
"""
from __future__ import annotations

import importlib.util
import itertools
import json
import os
import re
import sys
import tempfile
import threading
import unittest
from pathlib import Path

sys.dont_write_bytecode = True   # no __pycache__ inside templates/ (the installer copies plugin folders)
REPO = Path(__file__).resolve().parent.parent
PLUGIN = REPO / "templates" / "hermes-plugins" / "factcheck"
SOUL = REPO / "templates" / "auditor-SOUL.md"
_HOME = tempfile.TemporaryDirectory()
os.environ["HOME"] = _HOME.name
os.environ.pop("HERMES_HOME", None)

_spec = importlib.util.spec_from_file_location("plug_factcheck_c3", PLUGIN / "__init__.py",
                                               submodule_search_locations=[str(PLUGIN)])
fc = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = fc
_spec.loader.exec_module(fc)

RECALL, GET = "mcp__gbrain_recall__recall", "mcp__gbrain_recall__get"
ER = "Поиск в общей памяти по этому запросу ничего не дал. Подтверждённого ответа дать не могу."
EG = "Документ по этому пути в общей памяти не найден. Подтверждённого ответа дать не могу."
F = "Не удалось получить подтверждённый результат обращения. Подтверждённого ответа дать не могу."
R = "Эти сведения не раскрываю без прямого разрешения владельца."
FACT = "В марте 2019 продано 12 мест."

DOC = {"path": "50-external/synthetic/x.md", "frontmatter": "{}", "body": "синтетика: в марте продано 12 мест",
       "source_type": "external", "agent": "coder", "scope": "shared", "created_at": None, "updated_at": None}
HITS = [{"path": "50-external/synthetic/x.md", "source_type": "external", "score": 0.05,
         "snippet": "синтетика: в марте продано 12 мест", "scope": "shared"}]


def text_env(payload: object) -> str:
    return json.dumps({"result": json.dumps(payload, ensure_ascii=False)}, ensure_ascii=False)


def structured_env(payload: object) -> str:
    return json.dumps({"result": {"result": payload}}, ensure_ascii=False)


EMPTY_R_SHAPES = (json.dumps({"result": "[]"}), structured_env([]), json.dumps({"result": "[]", "_meta": {"x": 1}}))
NULL_G_SHAPES = (json.dumps({"result": "null"}), structured_env(None),
                 json.dumps({"result": "null", "structuredContent": {"result": None}}))
FAIL_SHAPES = (
    ("transport", json.dumps({"error": "MCP call failed: ConnectError: refused"}), "error"),
    ("trust", json.dumps({"error": "Agent 'auditor' cannot read scope 'private'"}), "error"),
    ("status-error-empty", json.dumps({"result": "[]"}), "error"),
    ("result-empty-string", json.dumps({"result": ""}), "ok"),
    ("not-json", "Error executing tool recall: boom", "ok"),
    ("empty-object", json.dumps({}), "ok"),
    ("doc-error", text_env({**DOC, "body": "Document not found", "error": "not found", "success": False}), "ok"),
    ("hits-without-path", text_env([{"snippet": "без пути тут три слова"}]), "ok"),
    ("contradictory", json.dumps({"result": "[]", "structuredContent": {"result": HITS}}), "ok"),
    ("status-missing-empty", json.dumps({"result": "[]"}), ""),
)


class Base(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.addCleanup(setattr, fc, "LOG_PATH", fc.LOG_PATH)
        fc.LOG_PATH = Path(self.tmp.name) / "factcheck.log"
        self.clear()

    def clear(self) -> None:
        fc.LOG_PATH.unlink(missing_ok=True)
        for od in (fc._reads, fc._stubbed, fc._subagents, fc._events, fc._lost):
            od.clear()
        fc._saturated = False
        self.started: set[tuple[str, str]] = set()

    def start(self, sid: str = "s1", turn: str = "t1") -> None:
        fc.on_pre_llm_call(session_id=sid, turn_id=turn, platform="api_server")
        self.started.add((sid, turn))

    def post(self, name: str, result: str, status: str = "ok", args: dict | None = None, sid: str = "s1",
             turn: str = "t1") -> None:
        if sid and turn and (sid, turn) not in self.started:  # every engine turn starts before its tool calls
            self.start(sid, turn)
        if args is None:
            args = {"query": "продажи март 2019"} if name == RECALL else {"path": DOC["path"]}
        fc.on_post_tool_call(tool_name=name, args=args, result=result, session_id=sid, turn_id=turn, status=status)

    def empty_r(self, **kw: str) -> None:
        self.post(RECALL, json.dumps({"result": "[]"}), **kw)

    def null_g(self, **kw: str) -> None:
        self.post(GET, json.dumps({"result": "null"}), **kw)

    def read_r(self, **kw: str) -> None:
        self.post(RECALL, text_env(HITS), **kw)

    def read_g(self, **kw: str) -> None:
        self.post(GET, text_env(DOC), **kw)

    def fail_r(self, **kw: str) -> None:
        self.post(RECALL, json.dumps({"error": "MCP call failed: ConnectError: refused"}), status="error", **kw)

    def events(self, sid: str = "s1", turn: str = "t1") -> dict[str, int]:
        return fc._events_of(fc.snapshot(sid, turn)["rec"])

    def recorded(self) -> dict:
        return {k: c for k, rec in fc._events.items() if (c := {e: v for e, v in rec.items() if e != "ended" and v})}

    def final(self, text: str, sid: str = "s1", turn: str = "t1") -> tuple[str | None, dict]:
        out = fc.on_transform_llm_output(response_text=text, session_id=sid, platform="api_server", turn_id=turn)
        rec = json.loads(fc.LOG_PATH.read_text(encoding="utf-8").splitlines()[-1])
        return out, rec

    def verdict(self, text: str, **kw: str) -> str:
        return self.final(text, **kw)[1]["verdict"]

    def assert_pass(self, text: str, verdict: str, **kw: str) -> None:
        out, rec = self.final(text, **kw)
        self.assertEqual(rec["verdict"], verdict, text)
        self.assertIsNone(out)

    def assert_stub(self, text: str, verdict: str, **kw: str) -> None:
        out, rec = self.final(text, **kw)
        self.assertEqual(rec["verdict"], verdict, text)
        self.assertEqual(out, fc.STUB)


class SharedMemoryIsASource(Base):
    """C3: an answer after a real read of the shared memory is not stubbed."""

    def test_recall_hits_count_as_read(self) -> None:
        self.read_r()
        self.assert_pass(FACT, "pass:read")

    def test_get_document_counts_as_read(self) -> None:
        self.read_g()
        self.assert_pass(FACT, "pass:read")

    def test_structured_hits_count_as_read(self) -> None:
        self.post(RECALL, structured_env(HITS))
        self.assert_pass(FACT, "pass:read")

    def test_empty_null_or_failed_memory_is_not_a_read(self) -> None:
        for setup in (self.empty_r, self.null_g, self.fail_r):
            with self.subTest(setup=setup.__name__):
                self.clear()
                setup()
                self.assert_stub(FACT, "fact-unread")

    def test_other_recall_tools_are_not_a_read(self) -> None:
        for name in ("mcp__gbrain_recall__recent", "mcp__gbrain_recall__related", "mcp__gbrain_memory__get",
                     "mcp__other__recall", "tool_call"):
            with self.subTest(name=name):
                self.clear()
                self.post(name, text_env(HITS), args={"query": "q"})
                self.assert_stub(FACT, "fact-unread")

    def test_single_bridge_counts_batch_does_not(self) -> None:
        self.post("tool_call", text_env(HITS), args={"calls": [{"name": RECALL, "arguments": {"query": "q"}}]})
        self.assert_pass(FACT, "pass:read")
        self.clear()
        self.post("tool_call", text_env(DOC), args={"calls": json.dumps([{"name": GET,
                                                                          "arguments": '{"path": "a/b.md"}'}])})
        self.assert_pass(FACT, "pass:read")
        self.clear()
        self.post("tool_call", text_env(HITS), args={"calls": [{"name": RECALL, "arguments": {"query": "q"}},
                                                               {"name": RECALL, "arguments": {"query": "q2"}}]})
        self.assert_stub(FACT, "fact-unread")

    def test_swarm_letter_in_memory_is_not_a_source(self) -> None:
        self.post(RECALL, text_env(HITS), args={"query": "gbrain-swarm outbox"})
        self.assertEqual(self.recorded(), {})
        self.assert_stub(FACT, "fact-unread")

    def test_send_tool_passes_after_memory_read(self) -> None:
        args = {"message": FACT, "chat_id": "1"}
        self.assertEqual(fc.on_pre_tool_call(tool_name="send_message", args=args, session_id="s1",
                                             turn_id="t1")["action"], "block")
        self.read_g()
        self.assertIsNone(fc.on_pre_tool_call(tool_name="send_message", args=args, session_id="s1", turn_id="t1"))

    def test_block_and_reminder_name_shared_memory(self) -> None:
        self.assertIn("mcp__gbrain_recall__recall", fc.FACT_BLOCK)
        self.assertIn("общую память", fc.REMIND)


class Templates(Base):
    def test_four_templates_verbatim_and_in_soul(self) -> None:
        self.assertEqual(fc.TEMPLATES, {"E-R": ER, "E-G": EG, "F": F, "R": R})
        soul = SOUL.read_text(encoding="utf-8")
        for t in fc.TEMPLATES.values():
            self.assertIn(f"«{t}»", soul)

    def test_soul_names_shared_memory_as_source(self) -> None:
        self.assertIn("общую память", SOUL.read_text(encoding="utf-8"))

    def test_normalization_keeps_case_and_punct(self) -> None:
        self.assertEqual(fc.normalize(" Ёлка и\u0085ЁЖ​ ‍﻿  «x» "), "Елка и ЕЖ «x»")
        self.assertEqual(fc.normalize("ПОИСК"), "ПОИСК")

    def test_rule_ids_unique_and_case_insensitive(self) -> None:
        rules = fc.STRONG_RULES + fc.WEAK_RULES
        self.assertEqual(len({rid for rid, _ in rules}), len(rules))
        for rid, rx in rules:
            self.assertTrue(rx.flags & re.IGNORECASE, rid)


class Positives(Base):
    def test_empty_recall_shapes(self) -> None:
        for i, env in enumerate(EMPTY_R_SHAPES):
            with self.subTest(env=env):
                self.post(RECALL, env, turn=f"p{i}")
                self.assert_pass(ER, "pass:tpl-E-R", turn=f"p{i}")

    def test_null_get_shapes(self) -> None:
        for i, env in enumerate(NULL_G_SHAPES):
            with self.subTest(env=env):
                self.post(GET, env, turn=f"g{i}")
                self.assert_pass(EG, "pass:tpl-E-G", turn=f"g{i}")

    def test_every_fail_kind_allows_f_only(self) -> None:
        for kind, env, status in FAIL_SHAPES:
            for name in (RECALL, GET):
                with self.subTest(kind=kind, name=name):
                    self.clear()
                    self.post(name, env, status=status)
                    self.assertEqual(self.events()["FAIL"], 1)
                    self.assert_pass(F, "pass:tpl-F")
                    self.assert_stub(ER, "tpl-unbound")
                    self.assert_stub(EG, "tpl-unbound")

    def test_refusal_without_tools_and_after_reads(self) -> None:
        self.start()
        self.assert_pass(R, "pass:tpl-R")
        self.read_r(turn="t2")
        self.assert_pass(R, "pass:tpl-R", turn="t2")

    def test_empty_recall_plus_read_get(self) -> None:
        self.empty_r()
        self.read_g()
        self.assert_pass(ER, "pass:tpl-E-R")

    def test_normalized_variants(self) -> None:
        self.empty_r()
        for text in (ER.replace(" ", " ", 2), ER.replace(". ", ".  "), ER.replace("ё", "е"),
                     ER.replace("Поиск", "Пои​ск"), " " + ER + "\n"):
            with self.subTest(text=text):
                self.assert_pass(text, "pass:tpl-E-R")

    def test_promise_and_defect_report_are_not_stubbed(self) -> None:
        self.assert_pass("Поищу в памяти и вернусь с ответом.", "pass:no-fact")
        self.read_r(turn="t2")
        self.read_g(turn="t2")
        self.assert_pass("Файл не найден, тест 3 падает.", "pass:read", turn="t2")


class Negatives(Base):
    def test_fabrication_after_empty(self) -> None:
        self.empty_r()
        self.assert_stub(FACT, "fact-unread")

    def test_template_plus_tail(self) -> None:
        for setup, text in ((self.empty_r, ER + " В марте было 12 мест."),
                            (lambda: None, R + " Выручка 5 млн."),
                            (lambda: (self.read_r(), self.read_g()), R + " Выручка 5 млн."),
                            (self.empty_r, ER + " https://t.me/x"),
                            (self.empty_r, "Коллега, " + ER[0].lower() + ER[1:])):
            with self.subTest(text=text):
                self.clear()
                setup()
                self.assert_stub(text, "tpl-addition")

    def test_template_sentence_after_read_still_stubbed(self) -> None:
        """Accepted limitation, same as the live C3 r4 design: the template branches run before the fact check, so
        quoting a template phrase inside a longer answer is stubbed even after a real read."""
        self.read_g()
        self.assert_stub("В документе правило: «" + R + "»", "tpl-addition")

    def test_template_sentence_inside(self) -> None:
        self.empty_r()
        self.assert_stub("Поиск в общей памяти по этому запросу ничего не дал, но в марте 12 мест. "
                         "Подтверждённого ответа дать не могу.", "tpl-addition")

    def test_two_templates(self) -> None:
        self.empty_r()
        self.fail_r()
        self.assert_stub(ER + " " + F, "tpl-addition")

    def test_case_changed_template_is_not_exact(self) -> None:
        self.empty_r()
        self.assert_stub(ER.lower(), "tpl-addition")
        self.assert_stub(ER.upper(), "tpl-addition")

    def test_paraphrases_hit_the_lexicon(self) -> None:
        self.empty_r()
        self.assert_stub("По запросу ничего не нашлось.", "template-mismatch")
        self.clear()
        self.read_r()
        self.read_g()
        self.assert_stub("Эти данные не раскрою, там 5 млн.", "template-mismatch")
        self.clear()
        self.read_r()
        self.assert_stub("Nothing found in shared memory.", "template-mismatch")

    def test_weak_lexicon_only_without_reads(self) -> None:
        self.assert_stub("No results.", "template-mismatch")
        self.clear()
        self.read_r()
        self.assert_pass("No results.", "pass:no-fact")

    def test_look_alikes_not_caught(self) -> None:
        self.read_r()
        for text in ("Верно, давай запустим.", "Наверное, проверено вчера.", "Это пустяк."):
            with self.subTest(text=text):
                self.assertIsNone(fc.lexicon_rule(fc.normalize(text), 1))

    def test_no_events_no_event_template(self) -> None:
        for t in (ER, EG, F):
            with self.subTest(t=t):
                self.clear()
                self.start()
                self.assert_stub(t, "tpl-unbound")

    def test_wrong_template_for_event(self) -> None:
        self.empty_r()
        self.assert_stub(EG, "tpl-unbound")
        self.assert_stub(F, "tpl-unbound")

    def test_event_swap_shapes_are_fail(self) -> None:
        for name, env in ((RECALL, NULL_G_SHAPES[0]), (GET, EMPTY_R_SHAPES[0])):
            with self.subTest(name=name):
                self.clear()
                self.post(name, env)
                ev = self.events()
                self.assertEqual((ev["EMPTY_R"], ev["NULL_G"], ev["FAIL"]), (0, 0, 1))
                self.assert_stub(ER, "tpl-unbound")
                self.assert_stub(EG, "tpl-unbound")

    def test_retry_succeeded_or_fail_then_read(self) -> None:
        self.empty_r()
        self.read_r()
        self.assert_stub(ER, "tpl-unbound")
        self.clear()
        self.fail_r()
        self.read_r()
        self.assert_stub(F, "tpl-unbound")

    def test_other_tool_with_empty_shape_records_nothing(self) -> None:
        for name in ("mcp__gbrain_recall__recent", "mcp__gbrain_swarm__list_my_pending", "read_file", "terminal"):
            with self.subTest(name=name):
                self.clear()
                self.post(name, json.dumps({"result": "[]"}), args={"query": "q"})
                self.assertEqual(self.recorded(), {})
                self.assert_stub(ER, "tpl-unbound")


class Isolation(Base):
    def test_previous_turn_and_other_session(self) -> None:
        self.empty_r(turn="t1")
        self.assert_stub(ER, "tpl-unbound", turn="t2")
        self.empty_r(sid="A", turn="x")
        self.assert_stub(ER, "tpl-unbound", sid="B", turn="x")
        self.assert_pass(ER, "pass:tpl-E-R", turn="t1")

    def test_missing_ids_allow_no_template(self) -> None:
        for sid, turn in (("", "t1"), ("A", ""), ("", "")):
            with self.subTest(sid=sid, turn=turn):
                self.clear()
                self.empty_r(sid=sid, turn=turn)
                self.fail_r(sid=sid, turn=turn)
                self.assertEqual(dict(fc._events), {})
                for t in (ER, EG, F, R):
                    self.assert_stub(t, "tpl-unbound", sid=sid, turn=turn)

    def test_events_without_turn_start_are_ignored(self) -> None:
        fc.on_post_tool_call(tool_name=RECALL, args={"query": "q"}, result=json.dumps({"result": "[]"}),
                             session_id="s1", turn_id="N", status="ok")
        self.assert_stub(ER, "tpl-unbound", turn="N")

    def test_late_event_after_end_does_not_change_turn(self) -> None:
        self.start(turn="T")
        self.final(ER, turn="T")
        self.fail_r(turn="T")
        self.assert_stub(F, "tpl-unbound", turn="T")
        self.empty_r(turn="U")
        self.assert_pass(ER, "pass:tpl-E-R", turn="U")
        self.read_r(turn="U")
        self.assert_pass(ER, "pass:tpl-E-R", turn="U")

    def test_any_order_same_verdict(self) -> None:
        steps = {"E": self.empty_r, "RG": self.read_g, "RR": self.read_r, "F": self.fail_r, "N": self.null_g}
        for seq, expect in ((("E", "RG"), {ER: "pass:tpl-E-R", F: "tpl-unbound"}),
                            (("E", "RR"), {ER: "tpl-unbound"}),
                            (("E", "F"), {ER: "tpl-unbound", F: "pass:tpl-F"}),
                            (("F", "RR"), {F: "tpl-unbound"}),
                            (("N", "RR"), {EG: "pass:tpl-E-G", F: "tpl-unbound"})):
            for perm in set(itertools.permutations(seq)):
                with self.subTest(perm=perm):
                    self.clear()
                    for s in perm:
                        steps[s]()
                    for t, v in expect.items():
                        self.assertEqual(self.verdict(t), v)

    def test_concurrent_posts(self) -> None:
        for _ in range(20):
            self.clear()
            self.start()
            ths = [threading.Thread(target=f) for f in (self.empty_r, self.read_g, self.empty_r, self.null_g)]
            for t in ths:
                t.start()
            for t in ths:
                t.join()
            ev = self.events()
            self.assertEqual((ev["EMPTY_R"], ev["READ_G"], ev["NULL_G"], ev["FAIL"]), (2, 1, 1, 0))
            self.assertEqual(self.verdict(ER), "pass:tpl-E-R")

    def test_events_bounded(self) -> None:
        for i in range(fc.MAX_TURNS + 5):
            self.empty_r(turn=f"x{i}")
        self.assertEqual(len(fc._events), fc.MAX_TURNS)


class Lifecycle(Base):
    """A forgotten turn never starts clean again; overflow of the loss list = global fail-closed until restart."""

    def setUp(self) -> None:
        super().setUp()
        for name, val in (("MAX_TURNS", 3), ("MAX_LOST", 50)):
            self.addCleanup(setattr, fc, name, getattr(fc, name))
            setattr(fc, name, val)

    def raw(self, turn: str, result: str) -> None:
        fc.on_post_tool_call(tool_name=RECALL, args={"query": "q"}, result=result, session_id="s1", turn_id=turn,
                             status="ok")

    def test_ended_turn_dropped_first(self) -> None:
        self.read_r(turn="A")              # A live, never answered
        for t in ("B", "C"):
            self.empty_r(turn=t)
            self.final(ER, turn=t)
        self.empty_r(turn="D")             # cap 3: an ENDED turn is dropped, live A keeps its history
        self.empty_r(turn="A")
        self.assert_stub(ER, "tpl-unbound", turn="A")

    def test_restart_after_eviction_does_not_reset(self) -> None:
        self.read_r(turn="T")
        for i in range(4):
            self.empty_r(turn=f"o{i}")     # T evicted while live
        fc.on_pre_llm_call(session_id="s1", turn_id="T", platform="api_server")
        self.raw("T", json.dumps({"result": "[]"}))
        self.assert_stub(ER, "tpl-history-lost", turn="T")

    def test_overflow_is_global_and_irreversible(self) -> None:
        fc.MAX_LOST = 2
        for i in range(8):
            self.read_r(turn=f"o{i}")
        self.assertLessEqual(len(fc._lost), 2)
        self.empty_r(turn="E")
        self.assert_stub(ER, "tpl-saturated", turn="E")
        self.fail_r(turn="G")
        self.assert_stub(F, "tpl-saturated", turn="G")
        self.start(turn="R")
        self.assert_pass(R, "pass:tpl-R", turn="R")

    def test_memory_bounded(self) -> None:
        fc.MAX_LOST = 5
        for i in range(60):
            self.empty_r(turn=f"m{i}")
            if i % 2:
                self.final(ER, turn=f"m{i}")
        self.assertLessEqual(len(fc._events), 3)
        self.assertLessEqual(len(fc._lost), 5)


class SendToolsAndReminder(Base):
    def pre(self, text: str, tool: str = "send_message") -> dict | None:
        args = {"message": text, "chat_id": "1"} if tool == "send_message" else {"payload": {"body": text}}
        return fc.on_pre_tool_call(tool_name=tool, args=args, session_id="s1", turn_id="t1", platform="api_server")

    def test_unbound_template_blocked(self) -> None:
        for tool in ("send_message", "mcp__gbrain_swarm__notify"):
            with self.subTest(tool=tool):
                self.clear()
                self.start()
                res = self.pre(ER, tool)
                self.assertEqual(res["action"], "block")
                self.assertIn("[шаблон-гейт]", res["message"])

    def test_bound_template_passes_tail_blocked(self) -> None:
        self.empty_r()
        self.assertEqual(self.pre(ER + " В марте 12 мест.")["action"], "block")
        self.assertIsNone(self.pre(ER))
        self.assertIsNone(self.pre(R))

    def test_reminder_after_template_stub(self) -> None:
        self.start()
        self.assert_stub(ER, "tpl-unbound")
        self.assertEqual(fc.on_pre_llm_call(session_id="s1", turn_id="t2"), {"context": fc.TPL_REMIND})
        self.assertIsNone(fc.on_pre_llm_call(session_id="s1", turn_id="t3"))

    def test_subagent_untouched(self) -> None:
        fc.on_subagent_start(child_session_id="child")
        fc.on_pre_llm_call(session_id="child", turn_id="t1", platform="api_server")
        self.assertEqual(dict(fc._events), {})
        self.assertIsNone(fc.on_transform_llm_output(response_text=ER, session_id="child", turn_id="t1"))

    def test_log_has_rule_id_and_hash_not_text(self) -> None:
        self.read_r()
        self.final("Секретная фраза: в общей памяти ничего не нашлось.")
        log = fc.LOG_PATH.read_text(encoding="utf-8")
        self.assertNotIn("Секретная", log)
        self.assertIn("lex:S-mem-empty", log)
        self.assertIn('"events":', log)


if __name__ == "__main__":
    unittest.main(verbosity=1)
