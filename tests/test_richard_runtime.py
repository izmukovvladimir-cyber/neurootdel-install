#!/usr/bin/env python3
"""Richard launcher: his own runtime gets the configured setting sources and the doctor's role file.

Stand-in package only (no network, no real bot). Run: python3 tests/test_richard_runtime.py
"""
from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import types
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LAUNCHER = REPO / "templates" / "richard-launch.py"

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("richard_launch", LAUNCHER)
rl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rl)

FAILS: list[str] = []


def check(name: str, cond: bool, detail: object = "") -> None:
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else f"  {detail!r}"[:300]))
    if not cond:
        FAILS.append(name)


# --- pure helpers ------------------------------------------------------------------------------
check("sources: user,project", rl.sources_from_env({"RICHARD_SETTING_SOURCES": "user, project"}) == ["user", "project"])
check("sources: unknown dropped, dups once", rl.sources_from_env({"RICHARD_SETTING_SOURCES": "user,evil,user"}) == ["user"])
check("sources: empty -> None (package default)", rl.sources_from_env({}) is None)
role_file = Path(tempfile.mkdtemp()) / "DOCTOR.md"
role_file.write_text("# Роль\nОтчёт не длиннее 6 строк.\n", encoding="utf-8")
check("role: read from the file", "6 строк" in rl.role_from_env({"RICHARD_ROLE_FILE": str(role_file)}))
check("role: missing file -> empty", rl.role_from_env({"RICHARD_ROLE_FILE": "/nonexistent/x.md"}) == "")

calls: list[dict] = []
mod = types.SimpleNamespace(ClaudeAgentOptions=lambda **kw: calls.append(kw) or kw)
check("patch: nothing configured -> untouched", rl.patch_options(mod, None, "") is False)
check("patch: applied", rl.patch_options(mod, ["user", "project"], "ROLE TEXT") is True)
mod.ClaudeAgentOptions(system_prompt="base", setting_sources=["project"], model="m")
check("patch: sources replaced", calls[-1]["setting_sources"] == ["user", "project"], calls[-1])
check("patch: role appended after the base prompt", calls[-1]["system_prompt"] == "base\n\nROLE TEXT", calls[-1])
check("patch: other options kept", calls[-1]["model"] == "m", calls[-1])

# --- end to end through the launcher: the child process builds options with the patch ---------------
with tempfile.TemporaryDirectory() as tmp:
    pkg = Path(tmp) / "src"
    (pkg / "claude").mkdir(parents=True)
    (pkg / "__init__.py").write_text("")
    (pkg / "claude" / "__init__.py").write_text("")
    (pkg / "claude" / "sdk_integration.py").write_text(
        "def ClaudeAgentOptions(**kw):\n    return kw\n"
        "def build():\n    return ClaudeAgentOptions(system_prompt='All file operations', setting_sources=['project'])\n")
    (pkg / "main.py").write_text(
        "import json\nfrom src.claude import sdk_integration\n"
        "def run():\n    print('OPTS', json.dumps(sdk_integration.build(), ensure_ascii=False), flush=True)\n")
    base = {k: v for k, v in os.environ.items() if not k.startswith("RICHARD_")}
    base.update(PYTHONPATH=tmp, TELEGRAM_BOT_TOKEN="123456789:AAHabcdefghijklmnopqrstuvwxyz0123456")

    def launch(extra: dict[str, str]) -> dict:
        p = subprocess.run([sys.executable, str(LAUNCHER)], env={**base, **extra}, capture_output=True, timeout=30)
        out = p.stdout.decode()
        line = next((ln for ln in out.splitlines() if ln.startswith("OPTS ")), "OPTS {}")
        return {"rc": p.returncode, **json.loads(line[5:]), "_out": out + p.stderr.decode()}

    got = launch({"RICHARD_SETTING_SOURCES": "user,project", "RICHARD_ROLE_FILE": str(role_file)})
    check("launch: rc 0", got["rc"] == 0, got)
    check("launch: user rules source loaded", got.get("setting_sources") == ["user", "project"], got)
    check("launch: role in the system prompt", "6 строк" in got.get("system_prompt", ""), got)
    got = launch({})
    check("launch: unset -> package behaviour", got.get("setting_sources") == ["project"]
          and got.get("system_prompt") == "All file operations", got)
    got = launch({"RICHARD_ROLE_FILE": "/nonexistent/DOCTOR.md"})
    check("launch: unreadable role is reported, bot still runs", got["rc"] == 0 and "role not loaded" in got["_out"], got)

print(f"FAILS: {len(FAILS)}")
sys.exit(1 if FAILS else 0)
