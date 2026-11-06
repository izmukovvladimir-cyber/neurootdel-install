"""readonly: the auditor checks and never edits (installed by neurootdel-install).

Two layers, this plugin is the first one:
1. Here: write_file and patch (and cronjob_manage except "list") are refused for every session, the parent and every
   delegate_task child alike (children call tools through the same handler, so the same pre_tool_call fires).
   The refusal text tells the model to describe the defect instead.
2. The kernel (systemd drop-in hermes-auditor.service.d/10-readonly.conf): ProtectHome=read-only with only the
   engine's own state writable. That layer stops terminal, execute_code and anything a shell can do; a tool-name
   list can not judge shell commands, so this plugin does not try.

Reading is untouched: read_file, search_files, terminal reads, journals.

Stop: hermes plugins disable readonly, then sudo systemctl restart hermes-auditor.
"""
from __future__ import annotations

import json
import logging
import time
from pathlib import Path
from typing import Any

log = logging.getLogger(__name__)

LOG_PATH = Path.home() / ".hermes" / "logs" / "readonly.log"
WRITE_TOOLS = frozenset({"write_file", "patch"})
# cron: the auditor does not schedule anything by itself; only listing jobs stays open.
CRON_TOOL, CRON_READ_ACTIONS = "cronjob_manage", frozenset({"list"})
BLOCK = ("[read-only] Аудитор только читает: {tool} запрещён, в том числе в дочерней задаче. Ничего не правь, "
         "опиши дефект (где, что не так, как исправить) и передай владельцу работы.")


def write_log(rec: dict[str, Any]) -> None:
    try:
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        with LOG_PATH.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps({"ts": ts, **rec}, ensure_ascii=False) + "\n")
    except OSError:
        log.warning("readonly: log write failed", exc_info=True)


def on_pre_tool_call(tool_name: str = "", args: Any = None, session_id: str = "", **_: Any) -> dict | None:
    name = str(tool_name or "")
    if name == CRON_TOOL:
        action = str(args.get("action") or "").strip().lower() if isinstance(args, dict) else ""
        if action in CRON_READ_ACTIONS:
            return None
        write_log({"event": "tool", "tool": name, "verdict": "block", "session": str(session_id)[:24],
                   "action": action[:40]})
        return {"action": "block", "message": BLOCK.format(tool=f"{name} ({action or 'без действия'})")}
    if name not in WRITE_TOOLS:
        return None
    path = args.get("path") if isinstance(args, dict) else None
    write_log({"event": "tool", "tool": name, "verdict": "block", "session": str(session_id)[:24],
               "path": str(path)[:200] if path else ""})
    return {"action": "block", "message": BLOCK.format(tool=name)}


def register(ctx: Any) -> None:
    ctx.register_hook("pre_tool_call", on_pre_tool_call)
    write_log({"event": "loaded", "verdict": "registered"})
