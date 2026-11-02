#!/usr/bin/env python3
"""Is a long job (funnel build, script) running inside an agent's channel service?

A restart of channel-<agent>.service kills the whole cgroup, including jobs the
agent started with setsid/nohup (KillMode=control-group). agents-reset.sh
asks this helper before restarting, so a background build is not cut off.

The session itself is ignored:
  - the tmux server (service MainPID) and the single `claude` process under it;
  - MCP servers: children of claude that stay in claude's session (sid == claude pid),
    with their subtrees. Bash tool calls get their own session, so an early build
    started through the tool is still a job (a start-time heuristic missed it).
Everything else forms job trees. A tree is judged by its ROOT (top-most job ancestor):
root younger than MIN_AGE_SEC is a short tool call, older than MAX_AGE_SEC is STALE and
does not hold the reset, so a forgotten loop that keeps spawning children cannot block
resets forever.

stdout, one line (only the executable and script basenames, never full argv):
  NONE
  JOB <pid> <age_sec> <exe> [script]
  STALE <pid> <age_sec> <exe> [script]
  ERR <reason>
"""
from __future__ import annotations

import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

MIN_AGE_SEC = 60
MAX_AGE_SEC = 3 * 3600
CGROUP_ROOT = Path("/sys/fs/cgroup")


@dataclass
class Proc:
    pid: int
    ppid: int
    sid: int
    age: int
    cmd: str


def read_proc(pid: int) -> Proc | None:
    try:
        with open(f"/proc/{pid}/stat") as fh:
            stat = fh.read()
        with open(f"/proc/{pid}/cmdline", "rb") as fh:
            cmd = fh.read().replace(b"\0", b" ").decode(errors="replace").strip()
        with open("/proc/uptime") as fh:
            uptime = float(fh.read().split()[0])
    except OSError:
        return None  # exited between listing and reading
    fields = stat[stat.rindex(")") + 2:].split()
    start = int(fields[19]) / os.sysconf("SC_CLK_TCK")
    return Proc(pid=pid, ppid=int(fields[1]), sid=int(fields[3]),
                age=int(uptime - start), cmd=cmd)


def short_cmd(cmd: str) -> str:
    """Executable basename, plus the script name only when it is argv[1] itself. No other argv."""
    parts = cmd.split()
    if not parts:
        return "?"
    out = [os.path.basename(parts[0])]
    if (len(parts) > 1 and not parts[1].startswith("-") and "=" not in parts[1]
            and "://" not in parts[1] and parts[1].endswith((".py", ".sh", ".mjs", ".js"))):
        out.append(os.path.basename(parts[1]))
    return " ".join(out)[:80]


def is_claude(p: Proc) -> bool:
    first = p.cmd.split()[0] if p.cmd else ""
    return os.path.basename(first) == "claude"


def classify(procs: list[Proc], main_pid: int, min_age: int = MIN_AGE_SEC) -> tuple[str, Proc | None]:
    """Return ("NONE"|"JOB"|"STALE"|"ERR", proc). Pure function, tested directly."""
    by_pid = {p.pid: p for p in procs}
    claudes = [p for p in procs if p.ppid == main_pid and is_claude(p)]
    if len(claudes) > 1:
        return "ERR", None
    claude = claudes[0] if claudes else None

    session: set[int] = {main_pid}
    if claude is not None:
        session.add(claude.pid)
        infra_roots = {p.pid for p in procs if p.ppid == claude.pid and p.sid == claude.pid}
        for p in procs:
            cur, seen = p, set()
            while cur is not None and cur.pid not in seen:
                if cur.pid in infra_roots:
                    session.add(p.pid)
                    break
                seen.add(cur.pid)
                cur = by_pid.get(cur.ppid)

    def root_of(p: Proc) -> Proc:
        cur, seen = p, {p.pid}
        while True:
            parent = by_pid.get(cur.ppid)
            if parent is None or parent.pid in session or parent.pid in seen:
                return cur
            seen.add(parent.pid)
            cur = parent

    roots = {root_of(p).pid: root_of(p) for p in procs if p.pid not in session and p.cmd}
    roots = {pid: r for pid, r in roots.items() if r.age >= min_age}
    if not roots:
        return "NONE", None
    live = [r for r in roots.values() if r.age <= MAX_AGE_SEC]
    if live:
        return "JOB", max(live, key=lambda r: r.age)
    return "STALE", max(roots.values(), key=lambda r: r.age)


def main() -> int:
    args = sys.argv[1:]
    min_age = MIN_AGE_SEC
    if args[:1] == ["--no-min-age"]:
        min_age, args = 0, args[1:]
    if len(args) != 1:
        print("ERR usage: agent_running_job.py [--no-min-age] <agent>")
        return 0
    unit = f"channel-{args[0]}.service"
    try:
        out = subprocess.run(
            ["systemctl", "show", unit, "-p", "LoadState", "-p", "MainPID", "-p", "ControlGroup"],
            capture_output=True, text=True, timeout=15, check=True).stdout
        props = dict(line.split("=", 1) for line in out.splitlines() if "=" in line)
        main_pid = int(props.get("MainPID") or 0)
    except (OSError, subprocess.SubprocessError, ValueError) as exc:
        print(f"ERR systemctl: {type(exc).__name__}")
        return 0
    if props.get("LoadState") != "loaded":
        print(f"ERR unit not loaded: {unit}")
        return 0
    cgroup = props.get("ControlGroup", "")
    if main_pid <= 0 or not cgroup:
        print("NONE")  # service not running: nothing to protect
        return 0
    try:
        pids = [int(x) for x in (CGROUP_ROOT / cgroup.lstrip("/") / "cgroup.procs").read_text().split()]
    except (OSError, ValueError) as exc:
        print(f"ERR cgroup.procs: {type(exc).__name__}")
        return 0
    procs = [p for p in (read_proc(pid) for pid in pids) if p is not None]
    verdict, proc = classify(procs, main_pid, min_age)
    if verdict == "ERR":
        print("ERR ambiguous claude process under tmux")
    elif proc is None:
        print(verdict)
    else:
        print(f"{verdict} {proc.pid} {proc.age} {short_cmd(proc.cmd)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
