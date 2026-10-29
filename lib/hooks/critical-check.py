#!/usr/bin/env python3
"""UserPromptSubmit hook (critical thinking): when the owner sends an idea, plan or text (typed or voice)
and not a short «ок/да/Б», put ONE line into the context so the agent does not agree right away.
Installed by neurootdel-install; the owner id is guard.conf OWNER_TG_ID.
Only the owner's own Telegram message counts (source="telegram", user_id=owner); webhooks, swarm and others skip.
Never blocks: any error or unknown input prints nothing and exits 0.
Stop: delete the UserPromptSubmit entry pointing here from the agent's settings.json."""
from __future__ import annotations

import html
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import guard_conf  # noqa: E402  (lives one level up, next to guard.conf)

_CONF = guard_conf.load()
OWNER_ID = _CONF.owner_tg_id
RULE = ("ПРАВИЛО (критическое мышление): не соглашайся сразу. До ответа: своя оценка, лучший вариант, "
        "аргумент фактами. Согласие только с причиной.")
# A missed idea is the failure that matters; an extra line costs nothing, so the bias is toward firing (Codex r2).
MIN_CHARS = 25                      # shorter than this is an ack, a choice or a quick question...
IDEA_MIN_CHARS = 8                  # ...unless it reads as a proposal («Убери меню»)
ACK_RE = re.compile(r"(?iu)^\W*(да|ок|окей|ok|хорошо|согласен|согласна|принято|ага|угу|го|закрывай|закрываем|"
                    r"спасибо|отлично|супер)\b")
ACK_MAX_CHARS = 35                  # «Да, давай так и оставим» confirms a choice already made...
ACK_BREAK_RE = re.compile(r"(?iu)\b(но|предлагаю|предлагаем|лучше|вместо|а если|зато|кроме)\b")  # ...these add a new idea
IDEA_WORD_RE = re.compile(r"(?iu)\b(давай|давайте|сделай|сделаем|предлагаю|надо|нужно|хочу|может|убери|уберём|добавь|"
                          r"поменяй|замени|запусти|попробуй|идея|план)\b")
SHORT_QUESTION_MAX = 120            # a short question is not an idea
# a real message tag always carries source=; a bare «<channel>» typed in a text is a mention, not a block (Codex r6)
TOKEN_RE = re.compile(r'<channel\b([^>]*\bsource="[^>]*)>|</channel>')
# attributes are parsed in sequence with their quoting, full names compared (Codex svw2a r1-r2):
# x-user_id, x:source or source="..." inside another attribute's value never count
ATTR_TOKEN_RE = re.compile(r"""\s*([A-Za-z_][\w:.-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))""")


def parse_attrs(raw: str) -> list[tuple[str, str]] | None:
    """All name=value pairs of a tag, or None when the attribute text does not parse cleanly."""
    pairs, pos, raw = [], 0, raw.rstrip().rstrip("/")
    while pos < len(raw):
        m = ATTR_TOKEN_RE.match(raw, pos)
        if not m:
            return None if raw[pos:].strip() else pairs
        value = next(v for v in (m.group(2), m.group(3), m.group(4)) if v is not None)
        pairs.append((m.group(1), value))
        pos = m.end()
    return pairs
TRANSCRIPT_RE = re.compile(r'\btranscript="([^"]*)"')
META_RE = re.compile(r"<untrusted_metadata\b.*?</untrusted_metadata>", re.S)
MARKUP_RE = re.compile(r"<[^>]+>")


def outer_messages(prompt: str) -> list[tuple[str, str]]:
    """(attrs, own text) of each top-level <channel> message. A channel tag quoted inside a message is dropped whole,
    the outer text before and after it is kept (Codex r4 #2, r5 #1-2)."""
    out: list[tuple[str, str]] = []
    depth, attrs, parts, pos = 0, "", [], 0
    for m in TOKEN_RE.finditer(prompt):
        if depth == 1:
            parts.append(prompt[pos:m.start()])
        if m.group(0).startswith("</"):
            if depth == 1:
                out.append((attrs, "".join(parts)))
            depth = max(0, depth - 1)
        else:
            if depth == 0:
                attrs, parts = m.group(1), []
            depth += 1
        pos = m.end()
    return out


def owner_texts(prompt: str) -> list[str]:
    """What the owner said in each of his channel messages: the typed body plus voice transcripts."""
    out = []
    # quoted replies may hold a whole earlier message, tags and transcripts included: gone before parsing (r1 #1)
    for attrs, body in outer_messages(META_RE.sub(" ", prompt)):
        pairs = parse_attrs(attrs)
        if pairs is None:
            continue
        sources = {v for k, v in pairs if k == "source"}
        users = {v for k, v in pairs if k == "user_id"}
        if sources != {"telegram"} or users != {OWNER_ID}:
            continue                    # only the owner's own Telegram message, never an inter-agent webhook
        voice = " ".join(html.unescape(t) for t in TRANSCRIPT_RE.findall(body))
        typed = MARKUP_RE.sub(" ", body)
        out.append(" ".join(f"{typed} {voice}".split()))
    return out


def is_idea(text: str) -> bool:
    t = text.strip()
    if t.endswith("?") and len(t) <= SHORT_QUESTION_MAX:
        # «Давай уберём меню. Что думаешь?»: the sentences before the closing question are judged on their own (r7)
        parts = re.split(r"(?<=[.!…])\s+", t)
        return len(parts) > 1 and is_idea(" ".join(parts[:-1]))
    if ACK_RE.match(t) and len(t) <= ACK_MAX_CHARS and not ACK_BREAK_RE.search(t):
        return False
    if len(t) < MIN_CHARS:
        return len(t) >= IDEA_MIN_CHARS and bool(IDEA_WORD_RE.search(t) or ACK_BREAK_RE.search(t))
    return True


def main() -> int:
    try:
        prompt = str(json.load(sys.stdin).get("prompt") or "")
    except (ValueError, AttributeError):
        return 0
    if OWNER_ID and any(is_idea(t) for t in owner_texts(prompt)):
        print(RULE)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # a context hook must never break the turn
        sys.exit(0)
