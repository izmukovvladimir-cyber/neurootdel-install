#!/usr/bin/env python3
"""Hard numbers gate: an unverified number never reaches the owner.

PreToolUse hook, matcher mcp__dashi-channel__reply|mcp__dashi-channel__edit_message.

A text to the owner's chat (--owner <telegram id>; without it every private chat counts as the owner's) and,
with --groups, to any group, is "hard" when it contains
  * a digit that is not a list marker («1.», «2)»), not part of a time (14:05, 14:05:33), a FULL date
    (29.10.2026, 2026-10-29, «29 октября»; a bare «29.10» only next to a time or МСК: «29.10 в 14:05»; otherwise
    it can not be told from 3.10 or «до 29.10 кг»), a link, a file path or a mention; or
  * a retelling marker: «со слов», «по данным», «по словам», «по отчёту», «по сведениям»,
    «как пишет / как сообщил / как доложил».
Time and date are exempt because every message carries them («в 14:00 МСК»); a count, a sum, a limit, a
percentage is not exempt.

A hard text goes out only if the CURRENT turn (the transcript's last promptId) has at least one successful
verification call: Read, Grep, Glob, WebFetch, WebSearch, Agent/Task, a Bash command that runs a program
(not only echo/printf/sleep/touch/mkdir/cp/mv/rm...), or an MCP read (not a write, not dashi-channel).
NOT a verification:
  * anything touching swarm (mcp__gbrain-swarm__*, a command or path with «swarm», gbrain-call): a report of
    another agent is what we are verifying, it is not the source;
  * the incoming prompt itself (a swarm letter arrives as a prompt, not as a call);
  * a call that failed (is_error) or returned nothing, or a background run.
No grace window and no "second attempt passes": the same text is denied every time until a check is made in
the turn or the number is removed. No transcript -> deny (there is nothing that proves a check).
A bug inside the gate lets the call through (exit 0) and is logged as «error», so it never wedges an agent.

Usage (settings.json, installed by install.sh into ~/.claude/hooks/):
  python3 ~/.claude/hooks/fact-number-gate.py <agent> [--groups] [--owner <chat_id>]
Log: ~/.claude/state/factgate/<agent>.log (one JSON line per call, hash of the text, no text).
Stop: delete the PreToolUse entry with this script from ~/.claude/settings.json.
"""
from __future__ import annotations

import hashlib
import json
import re
import shlex
import sys
import time
from pathlib import Path

OWNER_CHAT = ""  # empty: every private chat (positive chat_id) is the owner's
LOG_DIR = Path.home() / ".claude" / "state" / "factgate"
TAIL_BYTES = 16 * 1024 * 1024
MARK = "[факт-гейт-цифры]"
REASON = (MARK + " В тексте цифра (не время и не дата) или пересказ «со слов / по данным», а в ЭТОМ ходе нет ни "
          "одного проверочного вызова (Bash, Read, Grep, WebFetch, MCP-чтение). Письмо другого агента через swarm "
          "проверкой не считается. Сверь каждую цифру с источником сейчас или убери её из текста; непроверенное "
          "пиши словами «не проверено» без цифры. Повтор того же текста без проверки не пройдёт.")

MONTHS = r"(?:январ|феврал|март|апрел|ма[яй]|июн|июл|август|сентябр|октябр|ноябр|декабр)\w*"
NOT_QTY = r"(?!\s*(?:%|₽|\$|€|руб|р\.|тыс|млн|млрд|шт|раз|x\b|×|гб|мб|кб|gb|mb|kb))"
EXEMPT_RE = re.compile(
    r"https?://\S+|t\.me/\S+|www\.\S+"                         # links
    r"|(?<![\w@])@\w+"                                         # mentions
    r"|(?m:^[ \t]*\d{1,3}[.)](?=[ \t]))"                    # list markers «1.», «2)», «100.»
    r"|(?:~|\.{0,2})/[\w./~-]*\w"                               # file paths
    r"|[\w.-]*[A-Za-z][\w.-]*/[\w./-]*\.[A-Za-z]{1,5}\b"        # relative paths v2/report.txt
    # time only in a time context («в 14:05», «к 9:30», «14:05 МСК», «14:05:33»): «1:10», «счёт 2:15» are numbers
    r"|(?<![\w.])(?:в|во|к|ко|до|с|со|после|около|от|на|за|по)\s+(?:[01]?\d|2[0-3]):[0-5]\d\b(?!:\d)"
    r"|\b(?:[01]?\d|2[0-3]):[0-5]\d(?=\s*(?:мск|utc)\b)"
    r"|\b(?:[01]?\d|2[0-3]):[0-5]\d:[0-5]\d\b"
    r"|\b\d{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12]\d|3[01])\b"   # ISO date
    r"|\b(?:0?[1-9]|[12]\d|3[01])\.(?:0[1-9]|1[0-2])\.\d{4}\b" + NOT_QTY +  # 29.10.2026
    # a bare 29.10 only next to a time or МСК («29.10 в 14:05», «29.10 МСК»): «до 29.10» may be «до 29.10 кг»
    r"|\b(?:0[1-9]|[12]\d|3[01])\.(?:0[1-9]|1[0-2])(?=\s+(?:в\s+)?(?:[01]?\d|2[0-3]):[0-5]\d\b|\s+мск\b)"
    r"|\b(?:0?[1-9]|[12]\d|3[01])\s+" + MONTHS + r"(?:\s+\d{4}(?:\s*г(?:ода|\.)?)?)?",     # 29 октября 2026
    re.IGNORECASE,
)
ATTRIB_RE = re.compile(
    r"(?<![\w-])(со\s+слов\w*|по\s+данным|по\s+словам|по\s+отч[её]т\w*|по\s+сведениям|"
    r"как\s+(?:пишет|пишут|сообщ\w+|доложил\w*|отчитал\w*))(?![\w-])",
    re.IGNORECASE,
)

READ_TOOLS = {"Read", "Grep", "Glob", "WebFetch", "WebSearch", "Agent", "Task", "NotebookRead",
              "mcp__dashi-channel__download_attachment"}
# Where another agent's letters live or are fetched from (not the word «swarm» as such: docker swarm docs are a source)
SWARM_RE = re.compile(r"neurootdel-swarm|swarm-prompts|swarm[-_]?(?:inbox|outbox|reply|bridge|task|spool|letter)|"
                      r"gbrain[-_]swarm|gbrain-call|list_my_pending|/swarm/(?:inbox|outbox|delivered|sent|failed|pending)",
                      re.IGNORECASE)
MCP_WRITE_WORDS = {"create", "update", "append", "notify", "send", "delete", "remove", "set", "write", "replace", "done",
                   "start", "review", "block", "reopen", "heartbeat", "react", "edit", "reply", "ack", "forget", "store",
                   "add", "supersede", "publish", "post", "upload", "share", "trash", "label", "mark", "move", "copy",
                   "respond", "apply", "untrash", "unlabel", "unmark", "insert", "put", "patch", "save", "run", "exec"}
# The shell's own error lines (a failed read), not the content of a log that happens to say ERROR
ERROR_LINE_RE = re.compile(r"^(?:[\w./-]+: )+.*(?:No such file or directory|Permission denied|command not found|"
                           r"Is a directory|cannot access|cannot open)|^Traceback \(most recent call last\)|^curl: \(\d+\)")
# Commands that can print any number on their own: their output proves nothing
SYNTH_RE = re.compile(r"(?:^|[\s;&|(`$])(?:\S*/)?(?:(?:echo|printf)\s+[^;&|\n]*[\d$`]|yes|seq|expr|bc|awk\s+'BEGIN)")
BASH_NONREAD = {"echo", "printf", "true", "false", "sleep", ":", "touch", "mkdir", "cd", "export", "set", "unset",
                "rm", "cp", "mv", "chmod", "chown", "ln", "kill", "pkill", "exit", "sync", "trap", "wait", "read"}
BASH_WRAPPERS = {"sudo", "timeout", "env", "nice", "command", "time", "nohup"}
BACKGROUND_RE = re.compile(r"running in background|moved to the background|Output is being written to", re.I)


def is_hard(text: str) -> bool:
    """A number (not time/date/link/path/mention) or a retelling marker."""
    if ATTRIB_RE.search(text):
        return True
    return bool(re.search(r"\d", EXEMPT_RE.sub(" ", text)))


def text_hash(chat: str, text: str) -> str:
    return hashlib.sha256((chat + "\n" + re.sub(r"\s+", " ", text).strip()).encode()).hexdigest()


def read_tail(path: Path) -> list[dict]:
    size = path.stat().st_size
    with path.open("rb") as fh:
        if size > TAIL_BYTES:
            fh.seek(size - TAIL_BYTES)
            fh.readline()
        raw = fh.read()
    out = []
    for line in raw.decode("utf-8", "replace").splitlines():
        try:
            d = json.loads(line)
        except ValueError:
            continue
        if isinstance(d, dict) and d.get("type") in ("user", "assistant") and not d.get("isSidechain"):
            out.append(d)
    return out


def strip_heredoc_bodies(cmd: str) -> str:
    """Heredoc bodies are data fed to a command, not commands."""
    out: list[str] = []
    lines = cmd.split("\n")
    i = 0
    while i < len(lines):
        out.append(lines[i])
        delims = re.findall(r"<<-?\s*(['\"]?)([A-Za-z_]\w*)\1", lines[i])
        i += 1
        for _q, delim in delims:
            while i < len(lines) and lines[i].strip() != delim:
                i += 1
            i += 1
    return "\n".join(out)


def _dequote(w: str) -> str:
    return w.replace('"', "").replace("'", "").replace("\\", "")


def bash_checks(cmd: str) -> bool:
    """True if some command of the line (not after «||») runs a program beyond echo/sleep/file shuffling.
    Quotes are kept while splitting (a quoted «|» is an argument, not a pipe) and removed before matching
    (cat /tmp/swa""rm/inbox is still a swarm read)."""
    cmd = strip_heredoc_bodies(cmd)
    try:
        lex = shlex.shlex(cmd.replace("\n", " ; "), posix=False, punctuation_chars=";&|()<>")
        lex.whitespace_split = True
        raw = list(lex)
    except ValueError:
        return False
    if SWARM_RE.search(cmd) or SWARM_RE.search(_dequote(cmd)):
        return False  # quotes removed in place: "/var/lib/neurootdel-"swarm/x is still the swarm store
    seps = {";", "&&", "||", "|", "&", "(", ")", ";;", "|&"}
    redirs = {">", ">>", "<", "<<", ">&", "<&"}
    segments: list[tuple[str, list[str]]] = []
    cur: list[str] = []
    prev = ";"
    for tok in raw:  # an operator is an UNQUOTED raw token; a quoted «"|"» stays an argument
        if tok in seps:
            segments.append((prev, cur))
            cur, prev = [], tok
        elif tok in redirs:
            cur.append(tok)
        else:
            cur.append("\x00" + _dequote(tok))
    segments.append((prev, cur))
    prev_prog = ""
    dead = False  # inside a «false && ... && ...» chain: nothing of it runs
    for sep, words in segments:
        if sep == "&&" and (dead or prev_prog in ("false", "!", "exit")):
            dead = True
            continue
        if sep in (";", "&", "|", "|&"):
            dead = False
        if sep == "||":
            prev_prog = ""
            continue
        # drop redirection targets: `> file` is not a program
        clean: list[str] = []
        skip = False
        for w in words:
            if skip:
                skip = False
                continue
            if w in redirs:
                skip = True
                continue
            clean.append(w[1:])
        while clean and (re.fullmatch(r"\w+=\S*", clean[0]) or clean[0] in BASH_WRAPPERS
                         or (clean[0].startswith("-") and len(clean) > 1) or re.fullmatch(r"\d+[smh]?", clean[0])):
            clean = clean[1:]
        if not clean:
            continue
        prog = clean[0].rsplit("/", 1)[-1]
        prev_prog = prog
        if prog and prog not in BASH_NONREAD and not re.fullmatch(r"[\d>&<-]+", prog):
            return True
    return False


def echoed_words(cmd: str) -> set[str]:
    """Words printed by echo/printf in the command: their output proves nothing."""
    out: set[str] = set()
    for m in re.finditer(r"(?:^|[;&|(\s])(?:\S*/)?(?:echo|printf)\s+([^;&|\n]*)", strip_heredoc_bodies(cmd)):
        out.update(w for w in re.findall(r"\w+", m.group(1)))
    return out


def output_proves(name: str, args: dict, out: str) -> bool:
    """A Bash result must carry real output: not only error lines and not only what echo/printf printed."""
    if name != "Bash":
        return bool(out.strip())
    cmd = str(args.get("command", ""))
    if SYNTH_RE.search(strip_heredoc_bodies(cmd)) and not any(
            w not in echoed_words(cmd) and not re.fullmatch(r"\d+", w)
            for line in out.splitlines() if not ERROR_LINE_RE.search(line) for w in re.findall(r"\w+", line)):
        return False  # printf "%d" 0x33 / /bin/echo 51: only numbers came back, and the command can print them itself
    echoed = echoed_words(cmd)
    for line in out.splitlines():
        if ERROR_LINE_RE.search(line):
            continue
        if any(w not in echoed for w in re.findall(r"\w+", line)):
            return True
    return False


def is_check_call(name: str, args: dict) -> bool:
    if "swarm" in name.lower():
        return False
    if name == "Bash":
        return bash_checks(str(args.get("command", "")))
    if name in READ_TOOLS:
        return not SWARM_RE.search(json.dumps(args, ensure_ascii=False))
    if name.startswith("mcp__"):
        if name.startswith("mcp__dashi-channel__"):
            return False
        tool = name.rsplit("__", 1)[-1]
        if set(re.split(r"[_\-]+", tool.lower())) & MCP_WRITE_WORDS:
            return False
        return not SWARM_RE.search(json.dumps(args, ensure_ascii=False))
    return False


def _content_text(c: object) -> str:
    if isinstance(c, list):
        return " ".join(str(x.get("text", "")) for x in c if isinstance(x, dict))
    return str(c or "")


def turn_checked(entries: list[dict]) -> tuple[bool, str]:
    """(a verification call succeeded in the current turn, why). The turn = last promptId."""
    prompt_id = None
    for d in reversed(entries):
        if d.get("type") == "user" and d.get("promptId"):
            prompt_id = d["promptId"]
            break
    if prompt_id is None:
        return False, "no-turn"
    uses: dict[str, tuple[str, dict]] = {}
    for d in entries:
        content = (d.get("message") or {}).get("content")
        if not isinstance(content, list):
            continue
        for b in content:
            if not isinstance(b, dict):
                continue
            if b.get("type") == "tool_use":
                uses[str(b.get("id"))] = (str(b.get("name", "")), b.get("input") or {})
            elif (b.get("type") == "tool_result" and d.get("promptId") == prompt_id and not b.get("is_error")):
                u = uses.get(str(b.get("tool_use_id")))
                if not u:
                    continue
                name, args = u
                out = _content_text(b.get("content")).strip()
                if not out or args.get("run_in_background") or BACKGROUND_RE.search(out):
                    continue
                if is_check_call(name, args) and output_proves(name, args, out):
                    return True, "checked:" + name
    return False, "unchecked"


def decide(payload: dict, owner: str = OWNER_CHAT, groups: bool = False,
           entries: list[dict] | None = None) -> tuple[str | None, str]:
    """(deny reason or None, verdict)."""
    args = payload.get("tool_input")
    if not isinstance(args, dict):
        return None, "skip"
    chat = str(args.get("chat_id", ""))
    is_owner = chat == owner if owner else bool(re.fullmatch(r"\d+", chat))
    if not (is_owner or (groups and re.fullmatch(r"-\d+", chat))):
        return None, "skip-chat"
    text = str(args.get("text", ""))
    if not is_hard(text):
        return None, "no-number"
    if entries is None:
        tp = payload.get("transcript_path")
        if not tp:
            return REASON, "deny-no-transcript"
        try:
            entries = read_tail(Path(str(tp)))
        except OSError:
            return REASON, "deny-no-transcript"
    ok, why = turn_checked(entries)
    if ok:
        return None, "pass-" + why
    return REASON, "deny-" + why


def log(agent: str, payload: dict, verdict: str) -> None:
    args = payload.get("tool_input") if isinstance(payload.get("tool_input"), dict) else {}
    chat = str(args.get("chat_id", ""))
    rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(time.time() + 3 * 3600)) + "+03:00",
           "agent": agent, "session": str(payload.get("session_id", ""))[:8],
           "tool": str(payload.get("tool_name", "")).rsplit("__", 1)[-1], "chat": chat,
           "hash": text_hash(chat, str(args.get("text", "")))[:12], "verdict": verdict}
    name = re.sub(r"[^\w-]", "", agent) or "agent"
    try:
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        with (LOG_DIR / f"{name}.log").open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except OSError:
        pass


def main(argv: list[str]) -> int:
    agent = argv[1] if len(argv) > 1 and not argv[1].startswith("-") else "agent"
    groups = "--groups" in argv
    owner = OWNER_CHAT
    if "--owner" in argv:
        i = argv.index("--owner")
        if i + 1 < len(argv):
            owner = argv[i + 1]
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError, UnicodeDecodeError):
        return 0
    if not isinstance(payload, dict):
        return 0
    try:
        reason, verdict = decide(payload, owner, groups)
    except Exception:  # noqa: BLE001 - a gate bug must never wedge the reply
        reason, verdict = None, "error"
    log(agent, payload, verdict)
    if reason:
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                                 "permissionDecision": "deny",
                                                 "permissionDecisionReason": reason}}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except SystemExit:
        raise
    except Exception:  # noqa: BLE001
        sys.exit(0)
