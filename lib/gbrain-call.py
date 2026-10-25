#!/usr/bin/env python3
"""Call one gbrain MCP tool over stateless streamable HTTP with an agent's own token.

Usage: gbrain-call.py <agent> <service> <tool> ['<json args>']
  service: memory | recall | swarm | tasks
Token is read from <agent home>/.claude-lab/shared/secrets/gbrain-token-<agent>
and never printed. Prints the tool result (text content) to stdout.
Exit codes: 0 ok, 2 usage, 3 http/transport error, 4 tool error.
"""
from __future__ import annotations

import json
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import guard_conf  # noqa: E402

PORTS: dict[str, int] = {"swarm": 8766, "memory": 8767, "recall": 8768, "tasks": 8769}
SECRETS = guard_conf.load().agent_home / ".claude-lab/shared/secrets"


def _post(url: str, headers: dict[str, str], payload: dict, timeout: float) -> tuple[str, str]:
    req = urllib.request.Request(url, data=json.dumps(payload).encode(), method="POST",
                                 headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.headers.get("mcp-session-id", ""), resp.read().decode("utf-8", "replace")


def call(agent: str, service: str, tool: str, args: dict, timeout: float = 60.0) -> tuple[bool, str]:
    token = (SECRETS / f"gbrain-token-{agent}").read_text().strip()
    url = f"http://127.0.0.1:{PORTS[service]}/mcp"
    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json",
               "Accept": "application/json, text/event-stream"}
    # Streamable HTTP with sessions: initialize -> initialized -> tools/call.
    sid, _ = _post(url, headers, {"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {
        "protocolVersion": "2025-03-26", "capabilities": {},
        "clientInfo": {"name": "gbrain-call", "version": "1"}}}, timeout)
    if sid:
        headers["mcp-session-id"] = sid
    _post(url, headers, {"jsonrpc": "2.0", "method": "notifications/initialized"}, timeout)
    _, raw = _post(url, headers, {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                  "params": {"name": tool, "arguments": args}}, timeout)
    datas = re.findall(r"^data:\s*(\{.*\})\s*$", raw, re.M)
    obj = json.loads(datas[-1] if datas else raw)
    if "error" in obj:
        return False, json.dumps(obj["error"], ensure_ascii=False)
    res = obj.get("result") or {}
    texts = [c.get("text", "") for c in res.get("content", []) if isinstance(c, dict)]
    out = "\n".join(t for t in texts if t)
    if not out and "structuredContent" in res:
        out = json.dumps(res["structuredContent"], ensure_ascii=False)
    return not res.get("isError", False), out


def main() -> int:
    if len(sys.argv) < 4 or sys.argv[2] not in PORTS:
        print(__doc__, file=sys.stderr)
        return 2
    agent, service, tool = sys.argv[1:4]
    args = json.loads(sys.argv[4]) if len(sys.argv) > 4 else {}
    try:
        ok, out = call(agent, service, tool, args)
    except (urllib.error.URLError, OSError, ValueError) as exc:
        print(f"transport error: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 3
    print(out)
    return 0 if ok else 4


if __name__ == "__main__":
    sys.exit(main())
