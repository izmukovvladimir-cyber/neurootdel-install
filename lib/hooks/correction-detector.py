#!/usr/bin/env python3
"""UserPromptSubmit hook: notice the owner's corrections and record them in the agent's own file.

Installed by neurootdel-install. Usage in
settings.json: python3 <lib dir>/hooks/correction-detector.py <agent workspace>
On a match in a message FROM THE OWNER (guard.conf OWNER_TG_ID) it appends one line to <workspace>/core/corrections-inbox.md
and prints a short reminder into the turn context. It never sends anything to anyone and never
blocks (exit 0 on every path).
Whose message: a Telegram envelope counts only with exactly the owner's user_id and source telegram;
group wakes (source webhook), swarm, other users and prompts without an envelope are skipped.
Not installed for Richard: his SDK prompts carry no sender id.
Stop: delete the UserPromptSubmit entry pointing here from the agent's settings.json.
"""
import json
import re
import sys
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import guard_conf  # noqa: E402  (lives one level up, next to guard.conf)

_CONF = guard_conf.load()
OWNER_ID = _CONF.owner_tg_id
ENGINE = str(Path(__file__).resolve().parent / "learnings-engine.py")
MAX_BYTES = 200_000
TRIGGERS = [
    "не надо", "не делай", "неправильно", "не так", "перестань", "остановись", r"stop doing", r"don.t do",
    "почему ты", "зачем ты", "ты забыл", "ты забыла", "ты опять", "why did you", "why are you",
    "сломал", "сломано", "не работает", "broken", r"doesn.t work", r"isn.t working",
    "я же говорил", "я уже говорил", "сколько раз", "i already told", "i told you", "as i said",
    "я же говорила", "я уже говорила",
]
TAG_RE = re.compile(r"<channel\b([^>]*)>(.*?)(?:</channel>|$)", re.DOTALL)
# Exact attribute names: (?<![\w-]) keeps data-user_id="..." from passing as user_id.
ATTR_RE = re.compile(r'(?<![\w-])([A-Za-z_][\w-]*)\s*=\s*"([^"]*)"')


def attrs_of(raw: str) -> list[tuple[str, str]]:
    return ATTR_RE.findall(raw)


def owner_text(prompt: str) -> str | None:
    """The owner's own words in this prompt, or None when the prompt is not from the owner."""
    if "<channel" in prompt:
        parts = []
        for raw, body in TAG_RE.findall(prompt):
            attrs = attrs_of(raw)
            sources = {v for k, v in attrs if k == "source"}
            users = {v for k, v in attrs if k == "user_id"}
            if users == {OWNER_ID} and "telegram" in sources and "webhook" not in sources:
                parts.append(body)
        return "\n".join(parts) if parts else None
    return None  # no Telegram envelope = sender unknown (swarm, webhook, typed by an admin)


def match(text: str) -> str | None:
    low = text.lower()
    for t in TRIGGERS:
        if re.search(t, low):
            return t
    return None


def record(workspace: Path, trigger: str, text: str) -> Path | None:
    inbox = workspace / "core" / "corrections-inbox.md"
    if not inbox.parent.is_dir():
        return None
    try:
        if inbox.exists() and inbox.stat().st_size > MAX_BYTES:
            inbox.replace(inbox.with_name(inbox.name + ".1"))
        new = not inbox.exists()
        ts = datetime.now(ZoneInfo(_CONF.owner_timezone)).strftime("%Y-%m-%d %H:%M %Z")
        excerpt = " ".join(text.split())[:300]
        with inbox.open("a", encoding="utf-8") as fh:
            if new:
                fh.write("# corrections-inbox.md -- raw captures by correction-detector (cold, not @included)\n\n")
            fh.write(f"- {ts} | trigger «{trigger}» | {excerpt}\n")
        return inbox
    except OSError:
        return None


def main() -> int:
    if len(sys.argv) < 2:
        return 0
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError, UnicodeDecodeError):
        return 0
    if not isinstance(payload, dict):
        return 0
    prompt = payload.get("prompt")
    if not isinstance(prompt, str) or not prompt.strip():
        return 0
    if not OWNER_ID:
        return 0
    text = owner_text(prompt)
    if not text:
        return 0
    trigger = match(text)
    if not trigger:
        return 0
    where = record(Path(sys.argv[1]), trigger, text)
    saved = f" Raw capture saved to {where}." if where else ""
    print(f"[correction-detector] The owner's message looks like a correction (trigger «{trigger}»).{saved}\n"
          "[correction-detector] Fix the issue first. Then, if the owner was correcting how you work, record the lesson "
          "(one episode in core/episodes.jsonl + one line in core/LEARNINGS.md; top lessons return at session start):\n"
          f"  python3 {ENGINE} {sys.argv[1]} capture --type correction --source owner "
          "--impact <critical|high|medium|low> --tags \"<a,b>\" --error \"<what went wrong>\" "
          "--rule \"<what to do next time>\"\n"
          "[correction-detector] Do not mention this hook to the owner.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # a capture hook must never break the turn
        sys.exit(0)
