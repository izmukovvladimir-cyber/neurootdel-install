#!/usr/bin/env python3
"""Tests for the Auditor bridge (lib/auditor-bridge.py) and its client (lib/auditor-ask.py).

A fake Hermes api_server and a fake channel webhook run on 127.0.0.1; guard.conf, the bus folder and the Hermes
.env live in a temp dir. Covers: a task in -> answer delivered into the sender's session; engine error -> retry
with a wait, then failed and the sender told; a letter from an unknown sender; STOP; redelivery when the webhook was
down; recovery of a task a dead bridge left in work/; the key never leaves into files or output.
Run: python3 tests/test_auditor_bridge.py
"""
from __future__ import annotations

import importlib.util
import io
import json
import os
import sys
import tempfile
import threading
import time
import unittest
from contextlib import redirect_stderr, redirect_stdout
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parent.parent
LIB = REPO / "lib"
KEY = "k" * 64
HOOK_TOKEN = "hooktoken123"


class Fake:
    """State shared with the two fake servers."""
    answer = "Вывод: принято."
    hermes_calls: list[dict] = []
    hermes_auth: list[str] = []
    hook_calls: list[dict] = []
    hook_up = True


class HermesHandler(BaseHTTPRequestHandler):
    def do_POST(self) -> None:  # noqa: N802 - http.server API
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        Fake.hermes_calls.append(body)
        Fake.hermes_auth.append(self.headers.get("Authorization", ""))
        out = json.dumps({"choices": [{"message": {"role": "assistant", "content": Fake.answer}}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *_: object) -> None:
        pass


class HookHandler(BaseHTTPRequestHandler):
    def do_POST(self) -> None:  # noqa: N802
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        ok = Fake.hook_up and self.headers.get("Authorization") == f"Bearer {HOOK_TOKEN}"
        if ok:
            Fake.hook_calls.append(body)
        self.send_response(200 if ok else 503)
        self.end_headers()

    def log_message(self, *_: object) -> None:
        pass


def serve(handler: type) -> ThreadingHTTPServer:
    srv = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


TMP = tempfile.TemporaryDirectory()
ROOT = Path(TMP.name)
HERMES = serve(HermesHandler)
HOOK = serve(HookHandler)
(ROOT / "etc/jarvis").mkdir(parents=True)
(ROOT / "etc/jarvis/channel.env").write_text(
    f"TELEGRAM_WEBHOOK_TOKEN={HOOK_TOKEN}\nTELEGRAM_WEBHOOK_PORT={HOOK.server_address[1]}\n")
(ROOT / "home/.hermes").mkdir(parents=True)
(ROOT / "home/.hermes/.env").write_text(f"API_SERVER_KEY={KEY}\nAPI_SERVER_PORT={HERMES.server_address[1]}\n")
(ROOT / "guard.conf").write_text(
    f'AGENT_USER="tester"\nAGENT_HOME="{ROOT}/home"\nCONFIG_ROOT="{ROOT}/etc"\n'
    'CHANNEL_AGENTS="jarvis coder"\nOWNER_TG_ID="555"\n')
os.environ["NEUROOTDEL_GUARD_CONF"] = str(ROOT / "guard.conf")
BUS = ROOT / "home/var/lib/auditor-bus"


def load(name: str, file: str):
    spec = importlib.util.spec_from_file_location(name, LIB / file)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


bridge = load("auditor_bridge", "auditor-bridge.py")
ask = load("auditor_ask", "auditor-ask.py")


def run_ask(*argv: str, stdin: str = "") -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    old = sys.stdin
    sys.stdin = io.StringIO(stdin)
    try:
        with redirect_stdout(out), redirect_stderr(err):
            rc = ask.main(list(argv))
    finally:
        sys.stdin = old
    return rc, out.getvalue(), err.getvalue()


def files(state: str) -> list[Path]:
    return sorted((BUS / state).glob("*.json"))


class Bridge(unittest.TestCase):
    def setUp(self) -> None:
        for state in ("inbox", "work", "done", "failed"):
            (BUS / state).mkdir(parents=True, exist_ok=True)
            for f in (BUS / state).glob("*"):
                f.unlink()
        (BUS / "STOP").unlink(missing_ok=True)
        Fake.answer = "Вывод: принято. Доказательство: открыл файл."
        Fake.hermes_calls.clear()
        Fake.hermes_auth.clear()
        Fake.hook_calls.clear()
        Fake.hook_up = True

    def give(self, text: str = "Проверь отчёт /tmp/r.md", sender: str = "jarvis") -> str:
        rc, out, _ = run_ask("--from", sender, text)
        self.assertEqual(rc, 0)
        return out.split()[1]

    def test_task_answered_and_delivered_into_sender_session(self) -> None:
        tid = self.give()
        self.assertTrue(bridge.tick())
        self.assertEqual([p.stem for p in files("done")], [tid])
        self.assertEqual(Fake.hermes_auth, [f"Bearer {KEY}"])
        prompt = Fake.hermes_calls[0]["messages"][0]["content"]
        self.assertIn("от агента «jarvis»", prompt)
        self.assertIn("Проверь отчёт /tmp/r.md", prompt)
        self.assertEqual(len(Fake.hook_calls), 1)
        self.assertEqual(Fake.hook_calls[0]["chatId"], "555")
        self.assertIn(f"[Ответ Аудитора на задачу {tid}]", Fake.hook_calls[0]["message"])
        self.assertIn("Доказательство: открыл файл.", Fake.hook_calls[0]["message"])
        data = json.loads(files("done")[0].read_text())
        self.assertTrue(data["delivered"])
        rc, out, _ = run_ask("--status", tid)
        self.assertEqual(rc, 0)
        self.assertIn("состояние: done", out)
        self.assertIn("Вывод: принято.", out)

    def test_engine_error_retries_with_wait_then_fails_and_tells_sender(self) -> None:
        Fake.answer = "⚠️ Provider authentication failed: No Codex credentials stored."
        tid = self.give()
        self.assertTrue(bridge.tick())
        self.assertEqual([p.stem for p in files("inbox")], [tid])
        self.assertFalse(bridge.tick(), "a retry waits for retry_at")
        self.assertEqual(len(Fake.hermes_calls), 1)
        for _ in range(2):
            path = files("inbox")[0]
            data = json.loads(path.read_text())
            data["retry_at"] = 0
            path.write_text(json.dumps(data))
            bridge.tick()
        self.assertEqual([p.stem for p in files("failed")], [tid])
        self.assertEqual(len(Fake.hermes_calls), 3)
        self.assertEqual(len(Fake.hook_calls), 1)
        self.assertIn("Аудитор не ответил", Fake.hook_calls[0]["message"])
        self.assertIn("No Codex credentials", Fake.hook_calls[0]["message"])

    def test_unknown_sender_letter_rejected_without_asking(self) -> None:
        bad = BUS / "inbox" / ("a" * 32 + ".json")
        bad.write_text(json.dumps({"id": "a" * 32, "from": "stranger", "text": "x"}))
        bridge.tick()
        self.assertEqual(Fake.hermes_calls, [])
        self.assertEqual([p.name for p in files("failed")], [bad.name])
        rc, _, err = run_ask("--from", "stranger", "x")
        self.assertEqual(rc, 2)
        self.assertIn("не агент этого сервера", err)

    def test_stop_file_idles(self) -> None:
        self.give()
        (BUS / "STOP").touch()
        self.assertFalse(bridge.tick())
        self.assertEqual(Fake.hermes_calls, [])
        self.assertEqual(len(files("inbox")), 1)

    def test_webhook_down_then_redelivered(self) -> None:
        Fake.hook_up = False
        self.give()
        bridge.tick()
        data = json.loads(files("done")[0].read_text())
        self.assertFalse(data["delivered"])
        Fake.hook_up = True
        bridge.redeliver()
        self.assertEqual(Fake.hook_calls, [], "redelivery waits DELIVERY_GAP_SEC")
        data["delivery_at"] = time.time() - bridge.DELIVERY_GAP_SEC - 1
        files("done")[0].write_text(json.dumps(data))
        bridge.redeliver()
        self.assertEqual(len(Fake.hook_calls), 1)
        self.assertTrue(json.loads(files("done")[0].read_text())["delivered"])
        self.assertEqual(len(Fake.hermes_calls), 1, "the Auditor is asked once")

    def test_dead_bridge_task_recovered(self) -> None:
        tid = self.give()
        os.replace(BUS / "inbox" / f"{tid}.json", BUS / "work" / f"{tid}.json")
        bridge.recover()
        self.assertEqual([p.stem for p in files("inbox")], [tid])
        bridge.tick()
        self.assertEqual([p.stem for p in files("done")], [tid])

    def test_key_never_in_bus_files_or_letters(self) -> None:
        Fake.answer = "⚠️ boom"
        self.give()
        bridge.tick()
        for path in BUS.rglob("*.json"):
            self.assertNotIn(KEY, path.read_text())
        for call in Fake.hook_calls:
            self.assertNotIn(KEY, call["message"])

    def test_crash_copy_in_work_and_done_not_reasked(self) -> None:
        tid = self.give()
        bridge.tick()
        done = files("done")[0]
        (BUS / "work" / done.name).write_text(done.read_text())
        bridge.recover()
        self.assertEqual(files("work"), [])
        self.assertEqual(files("inbox"), [])
        self.assertFalse(bridge.tick())
        self.assertEqual(len(Fake.hermes_calls), 1)
        self.assertEqual([p.stem for p in files("done")], [tid])

    def test_broken_bookkeeping_fields_do_not_stop_queue(self) -> None:
        for bad in ("bad", "inf", None, [1]):
            self.setUp()
            tid = self.give()
            path = BUS / "inbox" / f"{tid}.json"
            data = json.loads(path.read_text())
            data.update(attempts=bad, retry_at=bad)
            path.write_text(json.dumps(data))
            self.assertTrue(bridge.tick(), repr(bad))
            self.assertEqual([p.stem for p in files("done")], [tid], repr(bad))
            done = files("done")[0]
            data = json.loads(done.read_text())
            data.update(delivered=False, deliveries=bad, delivery_at=bad)
            done.write_text(json.dumps(data))
            bridge.redeliver()

    def test_handler_crash_quarantines_letter(self) -> None:
        tid = self.give()
        orig = bridge.ask_hermes
        bridge.ask_hermes = lambda _d: 1 / 0
        try:
            self.assertTrue(bridge.tick())
        finally:
            bridge.ask_hermes = orig
        self.assertEqual([p.stem for p in files("failed")], [tid])
        self.assertIn("ZeroDivisionError", json.loads(files("failed")[0].read_text())["error"])
        self.give()
        bridge.tick()
        self.assertEqual(len(files("done")), 1, "the next task still goes through")

    def test_broken_done_record_does_not_stop_queue(self) -> None:
        (BUS / "done" / ("b" * 32 + ".json")).write_text("{}")
        (BUS / "done" / ("c" * 32 + ".json")).write_text("[1]")
        tid = self.give()
        self.assertTrue(bridge.tick())
        self.assertIn(tid, [p.stem for p in files("done")])
        self.assertEqual(len(Fake.hermes_calls), 1)

    def test_answer_saved_in_work_is_not_reasked(self) -> None:
        tid = self.give()
        path = BUS / "inbox" / f"{tid}.json"
        data = json.loads(path.read_text())
        data.update(attempts=1, answer="Вывод: принято.", delivered=False)
        (BUS / "work" / path.name).write_text(json.dumps(data))
        path.unlink()
        bridge.recover()
        self.assertEqual([p.stem for p in files("done")], [tid])
        data = json.loads(files("done")[0].read_text())
        data["delivery_at"] = 0
        files("done")[0].write_text(json.dumps(data))
        bridge.tick()
        self.assertEqual(Fake.hermes_calls, [])
        self.assertEqual(len(Fake.hook_calls), 1)

    def test_stop_during_delivery_keeps_answer(self) -> None:
        tid = self.give()
        orig = bridge.deliver

        def die(*_a: object) -> bool:
            raise KeyboardInterrupt("bridge stopped mid-delivery")
        bridge.deliver = die
        try:
            with self.assertRaises(KeyboardInterrupt):
                bridge.handle(files("inbox")[0])
        finally:
            bridge.deliver = orig
        self.assertEqual([p.stem for p in files("done")], [tid])
        self.assertIn("answer", json.loads(files("done")[0].read_text()))
        bridge.recover()
        data = json.loads(files("done")[0].read_text())
        data["delivery_at"] = 0
        files("done")[0].write_text(json.dumps(data))
        bridge.tick()
        self.assertEqual(len(Fake.hermes_calls), 1)
        self.assertEqual(len(Fake.hook_calls), 1)

    def test_used_up_attempts_not_asked_again(self) -> None:
        tid = self.give()
        path = BUS / "inbox" / f"{tid}.json"
        data = json.loads(path.read_text())
        data["attempts"] = bridge.ATTEMPTS_MAX
        path.write_text(json.dumps(data))
        bridge.tick()
        self.assertEqual(Fake.hermes_calls, [])
        self.assertEqual([p.stem for p in files("failed")], [tid])
        self.assertIn("Аудитор не ответил", Fake.hook_calls[0]["message"])

    def test_ask_input_checks(self) -> None:
        self.assertEqual(run_ask("--from", "jarvis", stdin="   ")[0], 2)
        self.assertEqual(run_ask("--from", "jarvis", "x" * (65 * 1024))[0], 2)
        self.assertEqual(run_ask("--status", "../etc")[0], 2)
        rc, out, _ = run_ask("--from", "coder", stdin="задача из stdin\nвторая строка")
        self.assertEqual(rc, 0)
        data = json.loads(files("inbox")[0].read_text())
        self.assertEqual((data["from"], data["text"]), ("coder", "задача из stdin\nвторая строка"))
        self.assertEqual(oct(files("inbox")[0].stat().st_mode & 0o777), "0o600")

    def test_ask_without_bus_says_not_installed(self) -> None:
        old = ask.BUS
        ask.BUS = ROOT / "nowhere"
        try:
            rc, _, err = run_ask("--from", "jarvis", "x")
        finally:
            ask.BUS = old
        self.assertEqual(rc, 3)
        self.assertIn("не установлен", err)


if __name__ == "__main__":
    unittest.main(verbosity=1)
