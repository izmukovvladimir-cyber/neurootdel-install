#!/usr/bin/env python3
"""Richard launcher: the bot token never reaches stdout/stderr (journald), whatever writes it."""
from __future__ import annotations

import importlib.util
import os
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LAUNCHER = REPO / "templates" / "richard-launch.py"
TOKEN = "123456789:AAHabcdefghijklmnopqrstuvwxyz0123456"
OTHER = "9876543210:ZYXWVUTSRQPONMLKJIHGFEDCBAzyxwvut_-"
SECRET = TOKEN.partition(":")[2]
OTHER_SECRET = OTHER.partition(":")[2]

sys.dont_write_bytecode = True  # no __pycache__ next to the template
spec = importlib.util.spec_from_file_location("richard_launch", LAUNCHER)
rl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rl)

FAILS: list[str] = []


def check(name: str, cond: bool, detail: object = "") -> None:
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else f"  {detail!r}"[:300]))
    if not cond:
        FAILS.append(name)


def launch(body: str, env_token: str = TOKEN, timeout: float = 30) -> tuple[int, str]:
    """Run the launcher with a stand-in src.main whose run() is body; return (rc, output)."""
    with tempfile.TemporaryDirectory() as tmp:
        pkg = Path(tmp) / "src"
        pkg.mkdir()
        (pkg / "__init__.py").write_text("")
        (pkg / "main.py").write_text(body)
        env = {**os.environ, "PYTHONPATH": tmp, "TELEGRAM_BOT_TOKEN": env_token, "OTHER_TOKEN": OTHER}
        p = subprocess.run([sys.executable, str(LAUNCHER)], env=env, capture_output=True, timeout=timeout)
        return p.returncode, (p.stdout + p.stderr).decode(errors="replace")


HEAD = "import os, sys, logging, json, subprocess, faulthandler\nT = os.environ['TELEGRAM_BOT_TOKEN']\nO = os.environ['OTHER_TOKEN']\n"

# --- pure helpers -----------------------------------------------------------------------
s = rl.secrets_from_env({"TELEGRAM_BOT_TOKEN": TOKEN})
check("mask: env token", rl.mask(f"x {TOKEN} y".encode(), s) == b"x <bot-token> y")
check("mask: secret alone", SECRET.encode() not in rl.mask(f"secret={SECRET}".encode(), s))
check("mask: other token by shape", OTHER_SECRET.encode() not in rl.mask(OTHER.encode(), []))
check("mask: short configured value", b"123:abc" not in rl.mask(b"t=123:abc.", rl.secrets_from_env({"TELEGRAM_BOT_TOKEN": "123:abc"})))
check("mask: plain text kept", rl.mask(b"hello 12:30 world", s) == b"hello 12:30 world")
emit, hold = rl.split_ready(b"line one\npart " + TOKEN[:15].encode(), final=False)
check("split: unfinished token held", emit == b"line one\npart " and hold == TOKEN[:15].encode(), (emit, hold))
emit, hold = rl.split_ready(b"abc", final=True)
check("split: final flushes all", emit == b"abc" and hold == b"")
emit, hold = rl.split_ready(b"x" * 5000, final=False)
check("split: endless run not held whole", len(hold) == rl._HOLD_TAIL and len(emit) == 5000 - rl._HOLD_TAIL)

# --- every writer, one process ------------------------------------------------------------
rc, out = launch(HEAD + """
class InvalidToken(Exception):
    pass
def run():
    logging.basicConfig(level=logging.INFO, format="%(message)s", stream=sys.stdout)
    logging.getLogger("httpx").info("HTTP Request: POST https://api.telegram.org/bot%s/getUpdates", T)
    print("LEVEL", logging.getLevelName(logging.getLogger("httpx").getEffectiveLevel()))
    try:
        raise InvalidToken(f"The token `{T}` was rejected by the server.")
    except InvalidToken:
        logging.getLogger("src.main").exception("start failed")
    print(json.dumps({"exception": f"InvalidToken: The token `{T}` was rejected"}))
    print(T[:15], T[15:], sep="", flush=True)
    sys.stdout.writelines([T[:20], T[20:], "\\n"]); sys.stdout.flush()
    sys.stdout.buffer.write(T.encode() + b"\\n"); sys.stdout.buffer.flush()
    sys.__stderr__.write("dunder " + T + "\\n"); sys.__stderr__.flush()
    os.write(2, ("fd " + T + "\\n").encode())
    os.write(1, T[:12].encode()); os.write(1, T[12:].encode() + b"\\n")
    subprocess.run(["sh", "-c", 'echo "subprocess $0"', T])
    print("other", O, file=sys.stderr, flush=True)
    sys.stdout.write("no newline at the end " + T)
    sys.stdout.flush()
    print("RUN-DONE", flush=True)
    raise InvalidToken(f"The token `{T}` was rejected by the server.")
""")
check("all writers: ran to the end", "RUN-DONE" in out, out)
check("all writers: exit 1 like an uncaught error", rc == 1, rc)
check("all writers: token secret absent", SECRET not in out, out)
check("all writers: other token secret absent", OTHER_SECRET not in out, out)
check("all writers: bot id + secret prefix absent", TOKEN[:15] not in out, out)
check("all writers: traceback still readable", "InvalidToken: The token `<bot-token>` was rejected" in out, out)
check("all writers: httpx at WARNING", "LEVEL WARNING" in out, out)
check("all writers: masks counted", out.count("<bot-token>") >= 12, out.count("<bot-token>"))

# --- exit codes ---------------------------------------------------------------------------
rc, out = launch(HEAD + "def run():\n    print('fine')\n")
check("exit: normal run -> 0", rc == 0 and "fine" in out, (rc, out))
rc, out = launch(HEAD + "def run():\n    sys.exit(3)\n")
check("exit: sys.exit(3) -> 3", rc == 3, rc)
rc, out = launch(HEAD + "def run():\n    print('half line', T, end='')\n", env_token=TOKEN)
check("exit: unfinished last line flushed masked", "half line <bot-token>" in out and SECRET not in out, out)

# --- systemd stop: SIGTERM to the whole group ----------------------------------------------
with tempfile.TemporaryDirectory() as tmp:
    pkg = Path(tmp) / "src"
    pkg.mkdir()
    (pkg / "__init__.py").write_text("")
    (pkg / "main.py").write_text(HEAD + "import time\ndef run():\n    print('up', T, flush=True)\n    time.sleep(60)\n")
    env = {**os.environ, "PYTHONPATH": tmp, "TELEGRAM_BOT_TOKEN": TOKEN, "OTHER_TOKEN": OTHER}
    p = subprocess.Popen([sys.executable, str(LAUNCHER)], env=env, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, start_new_session=True)
    time.sleep(1.5)
    os.killpg(p.pid, signal.SIGTERM)
    try:
        out = p.communicate(timeout=15)[0].decode()
        check("stop: ends by SIGTERM like the bot", p.returncode == -signal.SIGTERM, p.returncode)
        check("stop: output before stop masked", "up <bot-token>" in out and SECRET not in out, out)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        check("stop: ends by SIGTERM like the bot", False, "hung")

# --- the main PID does not hang on a grandchild that keeps the pipe ------------------------
rc, out = launch(HEAD + "def run():\n    subprocess.Popen(['sleep', '20'], start_new_session=True)\n    print('parent done', flush=True)\n", timeout=15)
check("grandchild: launcher ends when the bot ends", rc == 0 and "parent done" in out, (rc, out))

# --- review round 2 ---------------------------------------------------------------------
rc, out = launch(HEAD + "import time\ndef run():\n    os.write(1, b'x' * 4100 + T.encode() + b'x' * 110)\n    time.sleep(1.5)\n    os.write(1, b'\\n')\n")
check("long run: token near the hold cut still masked", SECRET not in out and "<bot-token>" in out, out[-300:])
rc, out = launch(HEAD + "def run():\n    print('cfg', T, flush=True)\n", env_token="1:abc")
check("short configured token masked", "1:abc" not in out and "cfg <bot-token>" in out, out)
pidfile = Path(tempfile.mkdtemp()) / "writer.pid"
t0 = time.monotonic()
rc, out = launch(HEAD + f"def run():\n    w = subprocess.Popen(['sh', '-c', 'while :; do echo tick; sleep 0.2; done'], start_new_session=True)\n    open({str(pidfile)!r}, 'w').write(str(w.pid))\n    sys.exit(3)\n", timeout=20)
took = time.monotonic() - t0
check("writing grandchild: launcher still ends with the bot's code", rc == 3 and took < 8, (rc, round(took, 1)))
try:
    os.kill(int(pidfile.read_text()), signal.SIGKILL)
except (OSError, ValueError):
    pass
rc, out = launch(HEAD + "import signal\ndef run():\n    os.kill(os.getpid(), signal.SIGKILL)\n")
check("SIGKILL of the bot: launcher ends by SIGKILL, no own traceback", rc == -signal.SIGKILL and "Traceback" not in out, (rc, out))
t0 = time.monotonic()
rl.mask(b"7" * 65536, s)
rl.mask(b"7" * 65536 + b":" + b"a" * 20, s)
check("mask: 64 KB digit run is linear", time.monotonic() - t0 < 0.5, round(time.monotonic() - t0, 3))
emit, hold = rl.split_ready(b"x" * 5000 + TOKEN.encode() + b"y" * 100, False, s)
check("split: complete token not cut by the tail limit", SECRET.encode() not in rl.mask(emit, s) and SECRET.encode() not in rl.mask(hold, s), (len(emit), len(hold)))
emit, hold = rl.split_ready(b"log line with " + TOKEN[:30].encode(), False, rl.secrets_from_env({"TELEGRAM_BOT_TOKEN": TOKEN}))
check("split: beginning of the configured token held", TOKEN[:30].encode() not in emit, emit)

emit, hold = rl.split_ready(TOKEN.encode() + b"x" * 1_000_000, False, s)
check("split: token then an endless run, hold stays small", len(hold) <= rl._HOLD_TAIL and SECRET.encode() not in rl.mask(emit, s), len(hold))
rc, out = launch(HEAD + "def run():\n    os.write(1, T.encode())\n    for _ in range(16):\n        os.write(1, b'x' * 65536)\n    os.write(1, b'\\nEND\\n')\n", timeout=60)
check("stream: 1 MB unfinished line after a token goes out, masked", rc == 0 and len(out) > 1_000_000 and SECRET not in out and "END" in out, (rc, len(out)))

print(f"FAILS: {len(FAILS)}")
sys.exit(1 if FAILS else 0)
