"""flush_order.py <repo> -- 16 distinct edits plus a repeat of the first: the repeat is the
newest action and must be the last line of the 15 kept (dedup must not drop it)."""
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

repo = sys.argv[1]
t = Path(tempfile.mkdtemp())
home = t / "home"
ws = home / ".claude-lab/jarvis/.claude"
(ws / "core/hot").mkdir(parents=True)
conf = t / "g.conf"
conf.write_text(f'AGENT_HOME="{home}"\nCHANNEL_AGENTS="jarvis"\nOWNER_TIMEZONE="UTC"\n')
pd = home / ".claude/projects" / re.sub(r"[^A-Za-z0-9]", "-", str(ws))
pd.mkdir(parents=True)
now = datetime.now(timezone.utc)
names = [f"f{i}.txt" for i in range(16)] + ["f0.txt"]
with (pd / "s.jsonl").open("w") as fh:
    for i, n in enumerate(names):
        ts = (now - timedelta(minutes=60 - i)).strftime("%Y-%m-%dT%H:%M:%S.000Z")
        fh.write(json.dumps({"type": "assistant", "timestamp": ts, "message": {"content": [
            {"type": "tool_use", "name": "Edit", "input": {"file_path": str(home / n)}}]}}) + "\n")
subprocess.run([sys.executable, f"{repo}/lib/agent-handoff-flush.py", "jarvis"], check=True,
               env={**os.environ, "NEUROOTDEL_GUARD_CONF": str(conf)}, capture_output=True)
rows = [ln for ln in (ws / "core/hot/handoff.md").read_text().splitlines() if ln.startswith("- **")]
sys.exit(0 if len(rows) == 15 and rows[-1].endswith("Edit f0.txt") else 1)
