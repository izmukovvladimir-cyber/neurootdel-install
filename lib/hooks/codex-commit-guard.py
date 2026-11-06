#!/usr/bin/env python3
"""Coder hook (PreToolUse Bash): no `git commit` / `git push` without a fresh Codex APPROVE (coder rules §15).

  codex-commit-guard.py check <agent>   reads the hook JSON on stdin; a git commit/push is blocked (exit 2,
                                        reason on stderr) unless the APPROVE marker is younger than an hour.

The marker is written by the codex-check skill script itself (skills/codex-check/scripts/codex-check.sh) right
after a real Codex call that returned APPROVE: ~/.claude-lab/shared/state/<agent>/codex-review-marker. The
hook never trusts what a Bash command printed, so an `echo` of a verdict line does not count.

The gate never locks out an owner without Codex. It is armed only when ALL hold:
  * EDITORIAL_ENABLED=1 in ~/.claude-lab/shared/editorial.conf (the owner switched Codex on; off by default);
  * the `codex` program is installed (PATH or ~/.local/bin) and ~/.codex/auth.json is not empty (logged in);
  * CODEX_COMMIT_GUARD is not 0 in that file (the owner's own off switch for this gate alone).
Otherwise everything passes. Unreadable hook input or bad arguments also pass: a hook must not wedge the agent.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import sys
import time
from pathlib import Path

MARKER_TTL_SEC = 3600
_AGENT = re.compile(r"[a-z][a-z0-9_-]{0,31}")
_PREFIX_WORDS = {"sudo", "env", "command", "exec", "nice", "nohup", "time", "then", "do", "else", "!", "{",
                 "if", "elif", "while", "until"}
_ASSIGN = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=.*")
# a heredoc body is data, not commands (<<EOF ... EOF, <<-'EOF', <<"EOF"); the rest of its header line is kept,
# so `cat <<'EOF'; git push` still shows the push
_HEREDOC = re.compile(r"(?P<h><<-?[ \t]*(?P<q>['\"]?)(?P<d>[A-Za-z_][A-Za-z0-9_]*)(?P=q))(?P<rest>[^\n]*\n)"
                      r"(?:.*?\n)??[ \t]*(?P=d)[ \t]*(?=\n|$)", re.S)
# fallback when the command does not tokenize (unbalanced quotes): git in command position
_GIT_WRITE_RE = re.compile(
    r"(?m)(?:^|[;&|(`])\s*(?:\S*/)?git(?:\s+(?:-[Cc]\s+\S+|--?[A-Za-z][\w-]*(?:=\S+)?))*\s+(?:commit|push)\b")


def home() -> Path:
    return Path(os.environ.get("HOME") or Path.home())


def conf_get(conf: Path, key: str) -> str:
    """Last KEY=value of the plain conf (never executed), quotes stripped; "" when absent or unreadable."""
    try:
        text = conf.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return ""
    value = ""
    for line in text.splitlines():
        m = re.match(rf"^{re.escape(key)}=[\"']?([^\"']*)[\"']?\s*$", line)
        if m:
            value = m.group(1)
    return value


def armed(h: Path) -> bool:
    """The gate is on: Codex switched on, installed and logged in, and not switched off by the owner."""
    conf = Path(os.environ.get("EDITORIAL_CONF") or h / ".claude-lab/shared/editorial.conf")
    if conf_get(conf, "EDITORIAL_ENABLED") != "1" or conf_get(conf, "CODEX_COMMIT_GUARD") == "0":
        return False
    path = os.pathsep.join([str(h / ".local/bin"), os.environ.get("PATH", "")])
    if not shutil.which("codex", path=path):
        return False
    auth = Path(os.environ.get("CODEX_HOME") or h / ".codex") / "auth.json"
    try:
        return auth.stat().st_size > 0
    except OSError:
        return False


def marker(h: Path, agent: str) -> Path:
    return h / ".claude-lab/shared/state" / agent / "codex-review-marker"


def _commands(cmd: str) -> list[list[str]] | None:
    """Simple commands of a Bash text as word lists (quotes removed); None when a quote is not closed.

    A small Bash-like lexer: quotes and backslashes join into one word (`"/tmp/my repo"/sub` is one word,
    `note="a; b"` too), so a quoted ; & | ( ) or newline is text, never a command boundary. Outside quotes
    those characters split commands, and `#` at the start of a word comments out the rest of its line.
    """
    text = _HEREDOC.sub(lambda m: m.group("h") + m.group("rest"), cmd)
    out: list[list[str]] = [[]]
    word: list[str] = []
    in_word = False
    i, n = 0, len(text)

    def end_word() -> None:
        nonlocal word, in_word
        if in_word:
            out[-1].append("".join(word))
        word, in_word = [], False

    while i < n:
        ch = text[i]
        if ch == "'":
            j = text.find("'", i + 1)
            if j < 0:
                return None
            word.append(text[i + 1:j])
            in_word, i = True, j + 1
            continue
        if ch == '"':
            j = i + 1
            buf: list[str] = []
            while j < n and text[j] != '"':
                if text[j] == "\\" and j + 1 < n:
                    buf.append(text[j + 1])
                    j += 2
                    continue
                buf.append(text[j])
                j += 1
            if j >= n:
                return None
            word.append("".join(buf))
            in_word, i = True, j + 1
            continue
        if ch == "\\":
            if i + 1 < n and text[i + 1] != "\n":
                word.append(text[i + 1])
                in_word = True
            i += 2
            continue
        if ch == "#" and not in_word:
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        if ch in ";&|()\n":
            end_word()
            if out[-1]:
                out.append([])
            i += 1
            continue
        if ch in " \t\r":
            end_word()
            i += 1
            continue
        word.append(ch)
        in_word, i = True, i + 1
    end_word()
    return [c for c in out if c]


def _is_git_write(words: list[str]) -> bool:
    i = 0
    while i < len(words) and (words[i] in _PREFIX_WORDS or _ASSIGN.fullmatch(words[i])
                              or (words[i - 1:i] == ["env"] and words[i].startswith("-"))):
        i += 1
    if i >= len(words) or os.path.basename(words[i]) != "git":
        return False
    i += 1
    while i < len(words) and words[i].startswith("-"):
        # -C <dir> and -c <k=v> take a value; --opt=value and flags do not
        i += 2 if words[i] in ("-C", "-c", "--git-dir", "--work-tree", "--namespace") else 1
    return i < len(words) and words[i] in ("commit", "push")


def is_git_write(cmd: str) -> bool:
    commands = _commands(cmd)
    if commands is None:  # unbalanced quotes etc.: fall back to the plain pattern (errs towards blocking)
        return bool(_GIT_WRITE_RE.search(cmd))
    return any(_is_git_write(c) for c in commands)


def check(event: dict, agent: str, h: Path) -> int:
    tool_input = event.get("tool_input")
    cmd = tool_input.get("command") if isinstance(tool_input, dict) else None
    if not isinstance(cmd, str) or not is_git_write(cmd) or not armed(h):
        return 0
    try:
        age: float | None = time.time() - marker(h, agent).stat().st_mtime
    except OSError:
        age = None
    if age is not None and 0 <= age <= MARKER_TTL_SEC:
        return 0
    print("CODEX-GUARD: git commit/push остановлен: одобрения Codex (APPROVE) за последний час нет.\n"
          "Прогони сверку по своему диффу и повтори коммит:\n"
          f"  ~/.claude-lab/{agent}/.claude/skills/codex-check/scripts/codex-check.sh <<'P'\n"
          "  MAPPING: какие файлы и функции читать (git diff)\n"
          "  ЦЕЛЬ: одно измеримое улучшение\n"
          "  КОНТЕКСТ: что нельзя ломать\n"
          "  ---\n  <вывод git diff>\n  P\n"
          "Метку ставит сам скрипт сверки на вердикте APPROVE. REQUEST_CHANGES: исправь и прогони снова.\n"
          "Codex недоступен долго: скажи владельцу; отключить проверку коммитов он может строкой "
          "CODEX_COMMIT_GUARD=0 в ~/.claude-lab/shared/editorial.conf.", file=sys.stderr)
    return 2


def main(argv: list[str]) -> int:
    if len(argv) != 3 or argv[1] != "check" or not _AGENT.fullmatch(argv[2]):
        print("usage: codex-commit-guard.py check <agent>", file=sys.stderr)
        return 0  # a misconfigured hook must not block the agent
    try:
        event = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0
    if not isinstance(event, dict):
        return 0
    return check(event, argv[2], home())


if __name__ == "__main__":
    sys.exit(main(sys.argv))
