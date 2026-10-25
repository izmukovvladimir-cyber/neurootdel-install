"""Shared settings of the agent guard scripts, read from guard.conf.

The installer writes <lib dir>/guard.conf (root-owned, no secrets) as plain KEY="value"
lines, so bash scripts `source` it and Python scripts read it here. Values never hold
quotes, backslashes, `$` or backticks (the installer refuses them).
NEUROOTDEL_GUARD_CONF points to another file (tests).
"""
from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from pathlib import Path

_LINE = re.compile(r'^([A-Z_][A-Z0-9_]*)="([^"\\$`]*)"\s*$')


def conf_path() -> Path:
    env = os.environ.get("NEUROOTDEL_GUARD_CONF")
    return Path(env) if env else Path(__file__).resolve().parent / "guard.conf"


def read_raw(path: Path | None = None) -> dict[str, str]:
    out: dict[str, str] = {}
    try:
        with (path or conf_path()).open(encoding="utf-8") as fh:
            for line in fh:
                m = _LINE.match(line.rstrip("\n"))
                if m:
                    out[m.group(1)] = m.group(2)
    except (OSError, UnicodeDecodeError):
        return {}   # no conf: defaults below; owner-bound hooks then stay silent
    return out


def project_dir_name(path: str) -> str:
    """Claude Code names a project dir after its cwd, every non-alphanumeric char as '-'."""
    return re.sub(r"[^A-Za-z0-9]", "-", path)


@dataclass
class Conf:
    agent_user: str
    agent_home: Path
    lib_dir: Path
    config_root: Path
    channel_agents: list[str]
    main_agent: str
    owner_name: str
    owner_tg_id: str
    owner_timezone: str
    richard_unit: str
    richard_env: str
    alert_mode: str
    alert_tg_chat_id: str
    labels: dict[str, str] = field(default_factory=dict)

    @property
    def lab(self) -> Path:
        return self.agent_home / ".claude-lab"

    @property
    def projects(self) -> Path:
        return self.agent_home / ".claude" / "projects"

    def workspace(self, agent: str) -> Path:
        return self.lab / agent / ".claude"

    def project_prefix(self, agent: str) -> str:
        return project_dir_name(str(self.workspace(agent)))

    def channel_env(self, agent: str) -> Path:
        return self.config_root / agent / "channel.env"

    def label(self, agent: str) -> str:
        return self.labels.get(agent, agent)


def load(path: Path | None = None) -> Conf:
    raw = read_raw(path)
    home = Path(raw.get("AGENT_HOME") or f"/home/{raw.get('AGENT_USER', 'neurootdel')}")
    labels: dict[str, str] = {}
    for pair in raw.get("AGENT_LABELS", "").split(","):
        if "=" in pair:
            k, v = pair.split("=", 1)
            if k.strip():
                labels[k.strip()] = v.strip()
    agents = [a for a in raw.get("CHANNEL_AGENTS", "jarvis").split() if re.fullmatch(r"[a-z0-9-]+", a)]
    return Conf(
        agent_user=raw.get("AGENT_USER", "neurootdel"),
        agent_home=home,
        lib_dir=Path(raw.get("LIB_DIR") or Path(__file__).resolve().parent),
        config_root=Path(raw.get("CONFIG_ROOT", "/etc/vladimir-plugin")),
        channel_agents=agents,
        main_agent=raw.get("MAIN_AGENT") or (agents[0] if agents else "jarvis"),
        owner_name=raw.get("OWNER_NAME", ""),
        owner_tg_id=raw.get("OWNER_TG_ID", ""),
        owner_timezone=raw.get("OWNER_TIMEZONE") or "Europe/Moscow",
        richard_unit=raw.get("RICHARD_UNIT", ""),
        richard_env=raw.get("RICHARD_ENV", ""),
        alert_mode=raw.get("ALERT_MODE") or "outbox",
        alert_tg_chat_id=raw.get("ALERT_TG_CHAT_ID", ""),
        labels=labels,
    )
