#!/usr/bin/env python3
"""Tests for the Auditor session reset: lib/hermes-session-reset.py, lib/hermes-memory-flush.py,
lib/hermes-auditor-reset.sh and its cron in install.sh. No root, no Hermes: a temp state.db with the
engine's tables, a fake carrier result dir, a fake api_server on 127.0.0.1.

Covers: threshold judgment (dry run changes nothing), the mark + restart request in the carrier's
grammar and the wait bound to that request's verdict (DONE / FAIL / not taken -> withdrawn); the
wrapper saves memory first and resets only on a later quiet tick, a failed save holds the reset,
STOP, dry run, the nightly save only at 03:xx of the owner's clock; the flush reads API_SERVER_KEY
from ~/.hermes/.env, continues the session by X-Hermes-Session-Id and never prints the key; the cron
is written only with the Auditor; no names or paths of any one client server.
Run: python3 tests/test_auditor_reset.py
"""
from __future__ import annotations

import importlib.util
import io
import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from contextlib import redirect_stdout
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parent.parent
LIB = REPO / "lib"
HRESET = LIB / "hermes-session-reset.py"
HFLUSH = LIB / "hermes-memory-flush.py"
HWRAP = LIB / "hermes-auditor-reset.sh"
KEY = "K" * 40 + "abc123"
SID = "20261106_120000_deadbeef"
ROUTE = "agent:main:telegram:dm:555"

TMP = Path(tempfile.mkdtemp())
CONF = TMP / "guard.conf"
CONF.write_text(
    f'AGENT_USER="agentu"\nAGENT_HOME="{TMP}/home"\nCHANNEL_AGENTS="jarvis"\n'
    'OWNER_NAME="Анна"\nOWNER_TG_ID="555"\nOWNER_TIMEZONE="Europe/Moscow"\n', encoding="utf-8")
os.environ["NEUROOTDEL_GUARD_CONF"] = str(CONF)
os.environ["NEUROOTDEL_RR_BASE"] = str(TMP / "rr")
os.environ["HERMES_RESET_STATE"] = str(TMP / "rst")


def load(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def hermes_home(per_turn: int = 300000, age: float = 5000, telegram: bool = True) -> Path:
    home = Path(tempfile.mkdtemp(dir=TMP))
    c = sqlite3.connect(home / "state.db")
    c.execute("create table gateway_routing (scope text, session_key text, entry_json text, updated_at real)")
    c.execute("create table sessions (id text, api_call_count int, cache_read_tokens int, input_tokens int, message_count int)")
    c.execute("create table messages (session_id text, role text, timestamp real, content text, api_content text, "
              "active int, finish_reason text, tool_calls text)")
    c.execute("insert into sessions values (?,?,?,?,?)", (SID, 10, per_turn * 10, 0, 40))
    for i in range(3):
        # newest = a finished answer, so no turn is running
        role, fin = ("assistant", "stop") if i == 0 else ("user", None)
        c.execute("insert into messages values (?,?,?,?,?,?,?,?)",
                  (SID, role, time.time() - age - i, "x" * 100, None, 1, fin, None))
    entry = {"session_id": SID, "suspended": False, "platform": "telegram" if telegram else "api"}
    c.execute("insert into gateway_routing values (?,?,?,?)", ("s", ROUTE, json.dumps(entry), time.time()))
    c.commit()
    c.close()
    return home


def entry_of(home: Path) -> dict:
    c = sqlite3.connect(home / "state.db")
    row = c.execute("select entry_json from gateway_routing").fetchone()
    c.close()
    return json.loads(row[0])


class SessionReset(unittest.TestCase):
    def fresh(self):
        mod = load(HRESET, f"hsr{time.monotonic_ns()}")
        d = Path(tempfile.mkdtemp(dir=TMP))
        mod.WATCHDOG_REQ_DIR = d / "req"
        mod.WATCHDOG_RES_DIR = d / "res"
        mod.WATCHDOG_REQ_DIR.mkdir()
        mod.WATCHDOG_RES_DIR.mkdir()
        mod.WATCHDOG_PENDING = d / "pending"
        mod.unit_started_at = lambda _svc: 100
        return mod

    def run_main(self, mod, home: Path, on_sleep=lambda: None, extra=()) -> tuple[int, str]:
        argv = sys.argv
        sys.argv = ["x", "--home", str(home), "--service", "hermes-auditor", "--threshold", "250000",
                    "--carrier-wait", "1", *extra]
        real_sleep = time.sleep
        mod.time.sleep = lambda _s: (on_sleep(), real_sleep(0.3))
        buf = io.StringIO()
        try:
            with redirect_stdout(buf):
                rc = mod.main() or 0
        except SystemExit as e:
            rc = int(e.code or 0)
        finally:
            sys.argv = argv
            mod.time.sleep = real_sleep
        return rc, buf.getvalue()

    def test_paths_from_guard_conf(self):
        mod = load(HRESET, "hsr_paths")
        self.assertEqual(load(HRESET, "x").WATCHDOG_REQ_DIR, TMP / "rr" / "requests")
        os.environ.pop("NEUROOTDEL_RR_BASE")
        os.environ.pop("HERMES_RESET_STATE")
        try:
            m2 = load(HRESET, "hsr_paths2")
            self.assertEqual(m2.WATCHDOG_REQ_DIR, Path("/var/lib/agentu-requests/requests"))
            self.assertEqual(m2.WATCHDOG_RES_DIR, Path("/var/lib/agentu-requests/results"))
            self.assertEqual(m2.WATCHDOG_PENDING,
                             TMP / "home/.claude-lab/shared/state/hermes-auditor-reset/request-pending")
        finally:
            os.environ["NEUROOTDEL_RR_BASE"] = str(TMP / "rr")
            os.environ["HERMES_RESET_STATE"] = str(TMP / "rst")
        self.assertEqual(mod.WATCHDOG_AGENT, {"hermes-auditor": "auditor"})

    def test_below_threshold_nothing(self):
        mod = self.fresh()
        home = hermes_home(per_turn=30000)
        rc, out = self.run_main(mod, home, extra=("--apply",))
        self.assertEqual(rc, 0)
        self.assertIn("ниже порога", out)
        self.assertIn("сбрасывать нечего", out)
        self.assertFalse(entry_of(home)["suspended"])
        self.assertEqual(list(mod.WATCHDOG_REQ_DIR.iterdir()), [])

    def test_dry_run_changes_nothing(self):
        mod = self.fresh()
        home = hermes_home()
        rc, out = self.run_main(mod, home)
        self.assertEqual(rc, 0)
        self.assertIn("пометил бы 1 сессий", out)
        self.assertFalse(entry_of(home)["suspended"])
        self.assertEqual(list(mod.WATCHDOG_REQ_DIR.iterdir()), [])

    def test_live_turn_not_touched(self):
        mod = self.fresh()
        home = hermes_home(age=60)
        rc, out = self.run_main(mod, home, extra=("--apply",))
        self.assertEqual(rc, 8)
        self.assertIn("ЖИВОЙ ход", out)
        self.assertFalse(entry_of(home)["suspended"])

    def test_apply_done(self):
        mod = self.fresh()
        home = hermes_home()
        seen: list[str] = []

        def done():
            reqs = [p for p in mod.WATCHDOG_REQ_DIR.iterdir() if not p.name.endswith(".tmp")]
            if reqs and not seen:
                seen.append(reqs[0].read_text())
                (mod.WATCHDOG_RES_DIR / f"{reqs[0].name}.result").write_text(
                    "t ACCEPT restart auditor\nt DONE restart auditor: restarted\n")
        rc, out = self.run_main(mod, home, done, ("--apply",))
        self.assertEqual(rc, 0, out)
        self.assertTrue(entry_of(home)["suspended"])
        self.assertEqual(seen, ["restart auditor from=auditor\n"])   # the carrier's closed grammar
        self.assertRegex(mod._watchdog_name, r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")  # carrier RE_NAME
        state = json.loads((home / ".session-reset-state.json").read_text())
        self.assertGreaterEqual(state[ROUTE]["restarted_at"], state[ROUTE]["marked_at"])

    def test_apply_fail_not_done(self):
        mod = self.fresh()
        home = hermes_home()

        def fail():
            for p in mod.WATCHDOG_REQ_DIR.iterdir():
                (mod.WATCHDOG_RES_DIR / f"{p.name}.result").write_text("t FAIL restart auditor: x\n")
        rc, _ = self.run_main(mod, home, fail, ("--apply",))
        self.assertEqual(rc, 12)

    def test_untaken_request_withdrawn(self):
        mod = self.fresh()
        starts = iter(range(100, 10000, 7))
        mod.unit_started_at = lambda _svc: next(starts)   # an unrelated restart must not count
        rc, out = self.run_main(mod, hermes_home(), extra=("--apply",))
        self.assertEqual(rc, 12, out)
        self.assertEqual(list(mod.WATCHDOG_REQ_DIR.iterdir()), [])
        self.assertFalse(mod.WATCHDOG_PENDING.exists())

    def test_new_message_after_request_withdraws_it(self):
        mod = self.fresh()
        home = hermes_home()
        added: list[int] = []

        def human_writes():
            if not added:
                c = sqlite3.connect(home / "state.db")
                c.execute("insert into messages values (?,?,?,?,?,?,?,?)", (SID, "user", time.time(), "new", None, 1, None, None))
                c.commit()
                c.close()
                added.append(1)
        rc, out = self.run_main(mod, home, human_writes, ("--apply", "--carrier-wait", "30"))
        self.assertEqual(rc, 8, out)
        self.assertIn("заявка отозвана", out)
        self.assertEqual(list(mod.WATCHDOG_REQ_DIR.iterdir()), [])
        self.assertFalse(mod.WATCHDOG_PENDING.exists())

    def test_engine_busy_elsewhere_no_request(self):
        mod = self.fresh()
        home = hermes_home()
        c = sqlite3.connect(home / "state.db")
        c.execute("insert into messages values (?,?,?,?,?,?,?,?)", ("OTHER", "user", time.time() - 30, "busy", None, 1, None, None))
        c.commit()
        c.close()
        rc, out = self.run_main(mod, home, extra=("--apply",))
        self.assertEqual(rc, 8, out)
        self.assertIn("заявку не кладу", out)
        self.assertEqual(list(mod.WATCHDOG_REQ_DIR.iterdir()), [])

    def wrapper_fp(self, home: Path) -> str:
        # The wrapper's own `state_q fp` (python block of hermes-auditor-reset.sh), run as the wrapper runs it.
        src = HWRAP.read_text(encoding="utf-8")
        py = src[src.index("\n", src.index("<<'PYF'")) + 1:src.index("\nPYF\n")]
        r = subprocess.run([sys.executable, "-I", "-", str(home / "state.db"), str(HFLUSH), "fp"],
                           input=py, capture_output=True, text=True, env=dict(os.environ))
        return r.stdout.strip()

    def test_fp_same_in_wrapper_and_tool(self):
        mod = self.fresh()
        home = hermes_home()
        c = sqlite3.connect(home / "state.db")
        self.assertEqual(mod.sessions_fp(c), self.wrapper_fp(home))
        c.close()

    def done_on_request(self, mod):
        def done():
            for p in mod.WATCHDOG_REQ_DIR.iterdir():
                if not p.name.endswith(".tmp"):
                    (mod.WATCHDOG_RES_DIR / f"{p.name}.result").write_text("t DONE restart auditor: ok\n")
        return done

    def test_expect_fp_match_marks(self):
        mod = self.fresh()
        home = hermes_home()
        fp = self.wrapper_fp(home)
        rc, out = self.run_main(mod, home, self.done_on_request(mod), ("--apply", "--expect-fp", fp))
        self.assertEqual(rc, 0, out)
        self.assertTrue(entry_of(home)["suspended"])

    def test_expect_fp_mismatch_no_marks(self):
        mod = self.fresh()
        home = hermes_home()
        rc, out = self.run_main(mod, home, extra=("--apply", "--expect-fp", "0" * 64))
        self.assertEqual(rc, 8, out)
        self.assertIn("изменилось после сохранения", out)
        self.assertFalse(entry_of(home)["suspended"])
        self.assertEqual(list(mod.WATCHDOG_REQ_DIR.iterdir()), [])

    def test_pending_mark_lost_after_restart_is_not_done(self):
        mod = self.fresh()
        home = hermes_home()
        c = sqlite3.connect(home / "state.db")
        c.execute("update gateway_routing set entry_json=?",
                  (json.dumps({"session_id": SID, "suspended": True, "platform": "telegram"}),))
        c.commit()
        c.close()
        (home / ".session-reset-state.json").write_text(
            json.dumps({ROUTE: {"session_id": SID, "marked_at": 2.0, "restarted_at": 1.0}}))
        done = self.done_on_request(mod)

        def done_and_engine_overwrites():
            done()
            c2 = sqlite3.connect(home / "state.db")
            c2.execute("update gateway_routing set entry_json=?",
                       (json.dumps({"session_id": SID, "suspended": False, "platform": "telegram"}),))
            c2.commit()
            c2.close()
        rc, out = self.run_main(mod, home, done_and_engine_overwrites, ("--apply",))
        self.assertEqual(rc, 13, out)

    def test_long_running_turn_holds_request(self):
        mod = self.fresh()
        home = hermes_home()
        c = sqlite3.connect(home / "state.db")   # a turn inside one long tool call: last write 20 min ago
        c.execute("insert into messages values (?,?,?,?,?,?,?,?)",
                  (SID, "assistant", time.time() - 1200, "", None, 1, "tool_calls", '[{"id": "t1"}]'))
        c.commit()
        c.close()
        self.assertEqual(mod.open_turns(str(home / "state.db")), 1)
        rc, out = self.run_main(mod, home, extra=("--apply",))
        self.assertEqual(rc, 8, out)
        self.assertIn("незаконченный ход", out)
        self.assertEqual(list(mod.WATCHDOG_REQ_DIR.iterdir()), [])

    def test_no_carrier_mode_left(self):
        src = HRESET.read_text(encoding="utf-8")
        self.assertNotIn("'carrier'", src)
        self.assertIn("default='watchdog'", src)


# ---------- the flush against a fake api_server ----------

class Api:
    calls: list[dict] = []
    status = 200
    answer = "нечего записывать"
    write_to: Path | None = None   # the fake agent writes its memory here during the turn


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_a):
        pass

    def do_POST(self):  # noqa: N802
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        Api.calls.append({"path": self.path, "auth": self.headers.get("Authorization"),
                          "sid": self.headers.get("X-Hermes-Session-Id"), "body": body})
        if Api.write_to is not None:
            Api.write_to.mkdir(parents=True, exist_ok=True)
            with (Api.write_to / "MEMORY.md").open("a", encoding="utf-8") as fh:
                fh.write("договорённость\n")
        out = json.dumps({"choices": [{"message": {"content": Api.answer}}]}).encode()
        self.send_response(Api.status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(out)


class Flush(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()
        cls.port = cls.srv.server_address[1]

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()

    def flush(self, home: Path, *args: str) -> tuple[int, str]:
        r = subprocess.run([sys.executable, str(HFLUSH), "--home", str(home), *args],
                           capture_output=True, text=True, env=dict(os.environ), timeout=60)
        return r.returncode, r.stdout + r.stderr

    def test_flush_continues_session_with_env_key(self):
        Api.calls.clear()
        Api.status = 200
        home = hermes_home(age=600)
        (home / ".env").write_text(f"API_SERVER_KEY={KEY}\nAPI_SERVER_HOST=127.0.0.1\nAPI_SERVER_PORT={self.port}\n")
        rc, out = self.flush(home)
        self.assertEqual(rc, 0, out)
        self.assertEqual(len(Api.calls), 1)
        c = Api.calls[0]
        self.assertEqual(c["path"], "/v1/chat/completions")
        self.assertEqual(c["auth"], f"Bearer {KEY}")
        self.assertEqual(c["sid"], SID)
        prompt = c["body"]["messages"][0]["content"]
        self.assertIn("Анна", prompt)                      # owner from guard.conf
        self.assertIn("Ничего не отправляй в Telegram", prompt)
        self.assertNotIn(KEY, out)

    def test_flush_save_must_be_checkable(self):
        home = hermes_home(age=600)
        (home / ".env").write_text(f"API_SERVER_KEY={KEY}\nAPI_SERVER_PORT={self.port}\n")
        Api.answer, Api.write_to = "память сохранить не удалось: ошибка инструмента", None
        rc, out = self.flush(home)
        self.assertEqual(rc, 1, out)                      # 200 with words but no write: not saved
        self.assertIn("сохранение не подтверждено", out)
        Api.answer = "Ошибка сохранения; нельзя сказать «нечего записывать»"
        rc, out = self.flush(home)
        self.assertEqual(rc, 1, out)                      # the phrase inside other words is no proof
        Api.answer, Api.write_to = "записал: договорённость", home / "memories"
        rc, out = self.flush(home)
        self.assertEqual(rc, 0, out)                      # the memory file changed: saved
        Api.answer, Api.write_to = "нечего записывать", None

    @unittest.skipIf(os.geteuid() == 0, "root reads any dir")
    def test_unreadable_memory_dir_is_no_proof(self):
        mod = load(HFLUSH, "hmf_unread")
        home = Path(tempfile.mkdtemp(dir=TMP))
        sub = home / "memories" / "sub"
        sub.mkdir(parents=True)
        (sub / "MEMORY.md").write_text("x")
        self.assertIsNotNone(mod.memory_state(home))
        sub.chmod(0)
        try:
            self.assertIsNone(mod.memory_state(home))
        finally:
            sub.chmod(0o700)

    def test_empty_memory_dir_is_no_proof(self):
        mod = load(HFLUSH, "hmf_empty")
        home = Path(tempfile.mkdtemp(dir=TMP))
        before = mod.memory_state(home)
        (home / "memories").mkdir()
        self.assertFalse(mod.saved(before, mod.memory_state(home), "сохранить не удалось"))

    def test_bad_route_blocks_save_before_reset(self):
        Api.calls.clear()
        home = hermes_home(age=600)
        c = sqlite3.connect(home / "state.db")
        c.execute("insert into gateway_routing values ('s', 'broken', '{not json', 0)")
        c.commit()
        c.close()
        (home / ".env").write_text(f"API_SERVER_KEY={KEY}\nAPI_SERVER_PORT={self.port}\n")
        rc, out = self.flush(home, "--all-sessions")
        self.assertEqual(rc, 1, out)
        self.assertIn("не разбираются", out)
        self.assertEqual(Api.calls, [])

    def test_route_changed_during_save_fails(self):
        Api.calls.clear()
        home = hermes_home(age=600)
        (home / ".env").write_text(f"API_SERVER_KEY={KEY}\nAPI_SERVER_PORT={self.port}\n")
        mod = load(HFLUSH, "hmf_route")
        real_send = mod.send

        def send_and_new_route(*a, **kw):
            c = sqlite3.connect(home / "state.db")
            c.execute("insert into gateway_routing values ('s', 'agent:new', ?, 0)",
                      (json.dumps({"session_id": "NEW", "platform": "telegram"}),))
            c.commit()
            c.close()
            return real_send(*a, **kw)
        mod.send = send_and_new_route
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = mod.main(["--home", str(home), "--all-sessions"])
        self.assertEqual(rc, 1, buf.getvalue())
        self.assertIn("набор сессий изменился", buf.getvalue())

    def test_saved_judgment(self):
        mod = load(HFLUSH, "hmf_saved")
        self.assertTrue(mod.saved("a", "a", "Нечего записывать."))
        self.assertTrue(mod.saved("a", "a", "«нечего записывать»"))
        self.assertFalse(mod.saved("a", "a", "сохранить не вышло, нечего записывать не скажу"))
        self.assertTrue(mod.saved("", "b", "записал"))
        self.assertFalse(mod.saved(None, "b", "записал"))   # unreadable memory: unprovable
        self.assertFalse(mod.saved("a", None, "нечего записывать"))

    def test_flush_http_error_fails(self):
        Api.status = 500
        home = hermes_home(age=600)
        (home / ".env").write_text(f"API_SERVER_KEY={KEY}\nAPI_SERVER_PORT={self.port}\n")
        rc, out = self.flush(home)
        Api.status = 200
        self.assertEqual(rc, 1)
        self.assertIn("НЕ удалось", out)
        self.assertNotIn(KEY, out)

    def test_flush_no_key(self):
        home = hermes_home(age=600)
        (home / ".env").write_text(f"API_SERVER_PORT={self.port}\n")
        rc, out = self.flush(home)
        self.assertEqual(rc, 1)
        self.assertIn("API_SERVER_KEY", out)

    def test_flush_idle_or_not_telegram_skipped(self):
        Api.calls.clear()
        for home in (hermes_home(age=3 * 86400), hermes_home(age=600, telegram=False)):
            (home / ".env").write_text(f"API_SERVER_KEY={KEY}\nAPI_SERVER_PORT={self.port}\n")
            rc, out = self.flush(home)
            self.assertEqual(rc, 0, out)
        self.assertEqual(Api.calls, [])

    def test_flush_all_sessions_before_reset(self):
        Api.calls.clear()
        for home in (hermes_home(age=3 * 86400), hermes_home(age=600, telegram=False)):
            (home / ".env").write_text(f"API_SERVER_KEY={KEY}\nAPI_SERVER_PORT={self.port}\n")
            rc, out = self.flush(home, "--all-sessions")
            self.assertEqual(rc, 0, out)
        self.assertEqual(len(Api.calls), 2)   # idle and non-Telegram sessions are saved before a reset

    def test_flush_all_sessions_includes_marked(self):
        Api.calls.clear()
        home = hermes_home(age=600)
        c = sqlite3.connect(home / "state.db")
        c.execute("update gateway_routing set entry_json=?",
                  (json.dumps({"session_id": SID, "suspended": True, "platform": "telegram"}),))
        c.commit()
        c.close()
        (home / ".env").write_text(f"API_SERVER_KEY={KEY}\nAPI_SERVER_PORT={self.port}\n")
        rc, _ = self.flush(home)
        self.assertEqual((rc, len(Api.calls)), (0, 0))      # nightly: a marked session is left alone
        rc, out = self.flush(home, "--all-sessions")
        self.assertEqual((rc, len(Api.calls)), (0, 1), out)  # before a restart: saved too

    def test_flush_dry_run_no_call(self):
        Api.calls.clear()
        home = hermes_home(age=600)
        rc, out = self.flush(home, "--dry-run")
        self.assertEqual(rc, 0)
        self.assertIn("сохранил бы", out)
        self.assertEqual(Api.calls, [])


# ---------- the wrapper with fake tools ----------

FAKE_RESET = r'''#!/usr/bin/env python3
import os, sys
with open(os.environ["HAR_CALLS"], "a") as f:
    f.write("reset " + " ".join(sys.argv[1:]) + "\n")
if "--apply" in sys.argv:
    print("[hermes-reset] помечена на сброс: k"); sys.exit(int(os.environ.get("HAR_APPLY_RC", "0")))
print(os.environ.get("HAR_PLAN", "")); sys.exit(int(os.environ.get("HAR_PLAN_RC", "0")))
'''
FAKE_FLUSH = r'''#!/usr/bin/env python3
import os, sqlite3, sys, time
FLUSH_PROMPT = "SAVE-PROMPT"
if __name__ == "__main__":
    with open(os.environ["HAR_CALLS"], "a") as f:
        f.write("flush " + " ".join(sys.argv[1:]) + "\n")
    rc = int(os.environ.get("HAR_FLUSH_RC", "0"))
    if rc == 0 and "--dry-run" not in sys.argv:   # the flush is a turn in the same session, 20 min ago
        c = sqlite3.connect(os.path.join(os.environ["HAR_HOME"], "state.db"))
        t = time.time() - 1200
        c.execute("insert into messages values ('S1', 'user', ?, ?, NULL, NULL)", (t, FLUSH_PROMPT))
        c.execute("insert into messages values ('S1', 'assistant', ?, 'saved', 'stop', NULL)", (t + 1,))
        if os.environ.get("HAR_SWITCH_ROUTE"):   # the route moves to another session after the save
            c.execute("update gateway_routing set entry_json='{\"session_id\": \"S9\"}'")
        c.commit(); c.close()
    print("[memory-flush] k: записал"); sys.exit(rc)
'''
NEED = "[hermes-reset] сухой прогон: пометил бы 1 сессий, рестартовал бы ради 0 недоехавших пометок. Для дела нужен --apply"


class Wrapper(unittest.TestCase):
    def setUp(self):
        self.lib = Path(tempfile.mkdtemp(dir=TMP))
        (self.lib / "hermes-session-reset.py").write_text(FAKE_RESET)
        (self.lib / "hermes-memory-flush.py").write_text(FAKE_FLUSH)
        self.st = Path(tempfile.mkdtemp(dir=TMP))
        self.home = Path(tempfile.mkdtemp(dir=TMP))
        c = sqlite3.connect(self.home / "state.db")
        c.execute("create table gateway_routing (scope text, session_key text, entry_json text, updated_at real)")
        c.execute("create table messages (session_id text, role text, timestamp real, content text, "
                  "finish_reason text, tool_calls text)")
        c.execute("insert into gateway_routing values ('s','k','{\"session_id\": \"S1\"}',0)")
        c.execute("insert into messages values ('S1', 'user', 1000, 'x', NULL, NULL)")
        c.commit()
        c.close()

    def wrap(self, env_extra: dict | None = None, args: list[str] | None = None) -> tuple[list[str], str]:
        calls = self.st / "calls"
        calls.unlink(missing_ok=True)
        env = {"PATH": "/usr/bin:/bin", "HAR_TEST": "1", "HAR_LIB": str(self.lib), "HAR_ST": str(self.st),
               "HAR_HOME": str(self.home), "HAR_CALLS": str(calls), "NEUROOTDEL_GUARD_CONF": str(CONF)}
        env.update(env_extra or {})
        r = subprocess.run(["bash", str(HWRAP), *(args or [])], env=env, capture_output=True, text=True, timeout=60)
        got = calls.read_text().splitlines() if calls.exists() else []
        return got, r.stdout + r.stderr

    @staticmethod
    def applied(got: list[str]) -> bool:
        return any("--apply" in g for g in got)

    def test_syntax(self):
        self.assertEqual(subprocess.run(["bash", "-n", str(HWRAP)]).returncode, 0)

    def test_below_threshold_nothing(self):
        got, _ = self.wrap({"HAR_PLAN": "[hermes-reset] сбрасывать нечего"})
        self.assertEqual(len(got), 1)
        self.assertIn("--threshold 250000", got[0])
        self.assertIn("--restart-mode watchdog", got[0])
        self.assertIn("--service hermes-auditor", got[0])

    def test_save_first_then_reset(self):
        got, _ = self.wrap({"HAR_PLAN": NEED})
        self.assertTrue(any(g.startswith("flush") and "--all-sessions" in g for g in got), got)
        self.assertFalse(self.applied(got))
        self.assertTrue((self.st / "flushed-fp").is_file())
        saved = (self.st / "flushed-fp").read_text().strip()
        got, _ = self.wrap({"HAR_PLAN": NEED})
        self.assertTrue(self.applied(got), got)
        self.assertTrue(any(f"--apply --expect-fp {saved}" in g for g in got), got)
        self.assertFalse(any(g.startswith("flush") for g in got))
        self.assertFalse((self.st / "flushed-fp").exists())

    def test_pending_restart_needs_fresh_save(self):
        only_restart = NEED.replace("пометил бы 1 сессий, рестартовал бы ради 0", "пометил бы 0 сессий, рестартовал бы ради 1")
        got, _ = self.wrap({"HAR_PLAN": only_restart})          # no save bound to the current state yet
        self.assertTrue(any(g.startswith("flush") for g in got), got)
        self.assertFalse(self.applied(got))
        got, _ = self.wrap({"HAR_PLAN": only_restart})          # nothing said since: restart
        self.assertTrue(self.applied(got), got)

    def test_route_switch_after_save_not_recorded(self):
        got, out = self.wrap({"HAR_PLAN": NEED, "HAR_SWITCH_ROUTE": "1"})
        self.assertTrue(any(g.startswith("flush") for g in got))
        self.assertFalse((self.st / "flushed-fp").exists(), out)
        self.assertIn("set of sessions changed", out)

    def test_running_turn_is_live_for_wrapper(self):
        c = sqlite3.connect(self.home / "state.db")
        c.execute("insert into messages values ('S1', 'user', ?, 'long task', NULL, NULL)", (time.time() - 1500,))
        c.commit()
        c.close()
        got, out = self.wrap({"HAR_PLAN": NEED})
        self.assertFalse(self.applied(got))
        self.assertFalse(any(g.startswith("flush") for g in got), got)
        self.assertIn("engine not quiet", out)

    def test_failed_save_holds_reset(self):
        got, out = self.wrap({"HAR_PLAN": NEED, "HAR_FLUSH_RC": "1"})
        self.assertFalse(self.applied(got))
        self.assertEqual((self.st / "flush-fails").read_text().strip(), "1")
        (self.st / "flush-fails").write_text("5\n")
        got, out = self.wrap({"HAR_PLAN": NEED, "HAR_FLUSH_RC": "1"})
        self.assertFalse(self.applied(got))
        self.assertIn("STUCK", out)

    def test_stop(self):
        (self.st / "STOP").touch()
        got, out = self.wrap({"HAR_PLAN": NEED})
        self.assertEqual(got, [])
        self.assertIn("STOP", out)
        got, _ = self.wrap({"HAR_HOUR": "3"}, ["--nightly-flush"])
        self.assertEqual(got, [])

    def test_dry_run_saves_and_resets_nothing(self):
        got, out = self.wrap({"HAR_PLAN": NEED}, ["--dry-run"])
        self.assertFalse(self.applied(got))
        self.assertFalse(any(g.startswith("flush") for g in got))
        self.assertIn("would save memory first", out)

    def test_nightly_flush_only_at_three(self):
        got, _ = self.wrap({"HAR_HOUR": "14"}, ["--nightly-flush"])
        self.assertEqual(got, [])
        got, out = self.wrap({"HAR_HOUR": "3"}, ["--nightly-flush"])
        self.assertEqual(len(got), 1)
        self.assertTrue(got[0].startswith("flush --home"))
        self.assertNotIn("--all-sessions", got[0])
        self.assertIn("nightly memory save rc=0", out)

    def test_nightly_hour_judged_before_lock(self):
        src = HWRAP.read_text(encoding="utf-8")
        night = src[src.index('if [ "$NIGHT" = 1 ]; then'):]
        self.assertLess(night.index('[ "$hour" = 3 ] || exit 0'), night.index("flock -w 2400 9"))
        got, _ = self.wrap({"HAR_HOUR": "3"}, ["--nightly-flush"])
        self.assertTrue((self.st / "run.lock").exists())

    def test_unknown_arg(self):
        r = subprocess.run(["bash", str(HWRAP), "--bogus"], capture_output=True, text=True,
                           env={"PATH": "/usr/bin:/bin", "NEUROOTDEL_GUARD_CONF": str(CONF)})
        self.assertEqual(r.returncode, 2)


# ---------- install.sh: cron only with the Auditor ----------

HARNESS = r'''
set -uo pipefail
TDIR="$1"; REPO="$2"
sed -e "s#/etc/systemd/system/#${TDIR}/systemd/#g" "${REPO}/install.sh" >"${TDIR}/install.sh"
export INSTALL_SH_SOURCED_FOR_TESTING=1 NEUROOTDEL_TEMPLATES_DIR="${REPO}/templates" NEUROOTDEL_INSTALLER_ROOT="$REPO"
source "${TDIR}/install.sh"
set +e
apply_install_names new
AGENT_HOME="${TDIR}/home"; GUARD_LIB_DIR="/usr/local/lib/${AGENT_USER}"
as_agent() { "$@"; }
step() { :; }
_install_cron_file() { mkdir -p "${TDIR}/cron.d"; printf '%s\n' "$2" >"${TDIR}/cron.d/$1"; }
case "$3" in
  cron) install_auditor_reset_cron; echo "rc=$?" ;;
  skip) AUDITOR_BOT_TOKEN=""; _auditor_env_token() { :; }; install_auditor >/dev/null 2>&1; echo "rc=$?" ;;
esac
'''


class InstallCron(unittest.TestCase):
    def harness(self, mode: str) -> tuple[Path, str]:
        t = Path(tempfile.mkdtemp(dir=TMP))
        r = subprocess.run(["bash", "-c", HARNESS, "_", str(t), str(REPO), mode],
                           capture_output=True, text=True, timeout=120)
        return t, r.stdout + r.stderr

    def test_cron_written_with_auditor(self):
        t, out = self.harness("cron")
        self.assertIn("rc=0", out)
        cron = (t / "cron.d" / "neurootdel-hermes-reset").read_text()
        st = f"{t}/home/.claude-lab/shared/state/hermes-auditor-reset"
        self.assertTrue(Path(st).is_dir())
        self.assertIn(f"*/10 * * * * neurootdel /usr/bin/flock -n {st}/run.lock /bin/bash "
                      "/usr/local/lib/neurootdel/hermes-auditor-reset.sh >> ", cron)
        self.assertIn("50 * * * * neurootdel /bin/bash "
                      "/usr/local/lib/neurootdel/hermes-auditor-reset.sh --nightly-flush", cron)
        self.assertIn(f"touch {st}/STOP", cron)
        self.assertNotIn(" root ", cron)   # runs as the agent user: root never touches the WAL database

    def test_no_cron_without_auditor(self):
        t, out = self.harness("skip")
        self.assertIn("rc=0", out)
        self.assertFalse((t / "cron.d").exists())

    def test_install_auditor_calls_it(self):
        src = (REPO / "install.sh").read_text(encoding="utf-8")
        body = src[src.index("install_auditor() {"):src.index("install_auditor_reset_cron() {")]
        self.assertIn("install_auditor_reset_cron ||", body)
        self.assertLess(body.index("install_auditor_reset_cron ||"), body.index("AUDITOR_INSTALLED=1"))

    def test_carrier_takes_restart_auditor(self):
        src = (LIB / "agents-root-requests.sh").read_text(encoding="utf-8")
        self.assertIn("[auditor]=hermes-auditor", src)
        self.assertRegex(src, r"RE_AGENT_ANY='\^\(jarvis\|coder\|richard\|auditor\)\$'")


class Generic(unittest.TestCase):
    def test_no_client_names_or_paths(self):
        bad = re.compile(r"neurootdel-gosteva|147\.45|Светлан|svetlana|gosteva|/home/neurootdel|"
                         r"/home/edgelab|montage|Саня|Герман", re.I)
        for f in (HRESET, HFLUSH, HWRAP):
            hits = [ln for ln in f.read_text(encoding="utf-8").splitlines() if bad.search(ln)]
            self.assertEqual(hits, [], f.name)


if __name__ == "__main__":
    unittest.main(verbosity=2)
