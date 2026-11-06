#!/usr/bin/env python3
"""Tests for lib/hooks/codex-commit-guard.py and the APPROVE marker of the codex-check skill script:
the Coder's git commit/push waits for a Codex APPROVE, and never locks out an owner without Codex.

Run: python3 tests/test_codex_commit_guard.py   (no network, no root, a fake `codex`)
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
GUARD = REPO / "lib" / "hooks" / "codex-commit-guard.py"
SKILL = REPO / "skills" / "codex-check"
# fake codex: writes FAKE_REPLY into the file after -o
FAKE_CODEX = """#!/usr/bin/env bash
cat >/dev/null
while [[ $# -gt 0 ]]; do
    [[ "$1" == "-o" ]] && printf '%s\\n' "$FAKE_REPLY" >"$2"
    shift
done
"""


class Home:
    """A fake agent home: editorial.conf, optional codex program and login, the skill installed for coder."""

    def __init__(self, enabled: bool = True, codex: bool = True, login: bool = True, extra: str = "") -> None:
        self.dir = Path(tempfile.mkdtemp())
        shared = self.dir / ".claude-lab/shared"
        shared.mkdir(parents=True)
        (shared / "editorial.conf").write_text(
            f"EDITORIAL_ENABLED={1 if enabled else 0}\nCODEX_CHECK_MODEL=\n{extra}", encoding="utf-8")
        if codex:
            b = self.dir / ".local/bin"
            b.mkdir(parents=True)
            (b / "codex").write_text(FAKE_CODEX, encoding="utf-8")
            (b / "codex").chmod(0o755)
        if login:
            (self.dir / ".codex").mkdir()
            (self.dir / ".codex/auth.json").write_text('{"tokens": {}}', encoding="utf-8")
        for agent in ("coder", "jarvis"):
            shutil.copytree(SKILL, self.dir / f".claude-lab/{agent}/.claude/skills/codex-check")

    def env(self) -> dict[str, str]:
        return {"HOME": str(self.dir), "PATH": "/usr/bin:/bin"}

    def marker(self, agent: str = "coder") -> Path:
        return self.dir / f".claude-lab/shared/state/{agent}/codex-review-marker"

    def check(self, command: str, agent: str = "coder") -> int:
        event = {"tool_name": "Bash", "tool_input": {"command": command}}
        return subprocess.run([sys.executable, str(GUARD), "check", agent], input=json.dumps(event), text=True,
                              capture_output=True, env=self.env()).returncode

    def review(self, reply: str, agent: str = "coder") -> subprocess.CompletedProcess:
        script = self.dir / f".claude-lab/{agent}/.claude/skills/codex-check/scripts/codex-check.sh"
        return subprocess.run(["bash", str(script)], input="MAPPING: x\nЦЕЛЬ: y\nКОНТЕКСТ: z\n---\ndiff",
                              text=True, capture_output=True, env={**self.env(), "FAKE_REPLY": reply})


class Blocks(unittest.TestCase):
    def test_commit_without_marker_blocked(self) -> None:
        h = Home()
        event = {"tool_name": "Bash", "tool_input": {"command": "git commit -m x"}}
        r = subprocess.run([sys.executable, str(GUARD), "check", "coder"], input=json.dumps(event), text=True,
                           capture_output=True, env=h.env())
        self.assertEqual(r.returncode, 2)
        self.assertIn("CODEX-GUARD", r.stderr)
        self.assertIn("CODEX_COMMIT_GUARD=0", r.stderr)

    def test_git_forms_detected(self) -> None:
        h = Home()
        for cmd in ("git push origin fix/x", "cd /w && git commit -am 'x'", "git -C /w/repo commit -m x",
                    'git -C "/tmp/my repo" commit -m x', "git -c user.name=a commit -m x", "git --no-pager commit",
                    "echo ok; git push", "(git commit -m x)", "git commit", "echo start\n  git commit -m x",
                    "FOO=1 git push", "/usr/bin/git push", "env GIT_DIR=x git commit", "sudo git push",
                    "git --git-dir /r/.git commit", "true || git commit -m 'a; b'",
                    "cat <<'EOF' >f\ntext\nEOF\ngit commit -F f",
                    "# Создать коммит\ngit commit -m x", "git status # проверка\ngit push",
                    "cat <<'EOF'; git push\ntext\nEOF", "cat <<EOF\nEOF\ngit commit",
                    "if git commit -m x; then echo ok; fi", "if true; then :; elif git push; then :; fi",
                    "while git push; do sleep 1; done", "until git push; do :; done",
                    'git -C "/tmp/my repo"/subdir commit', "g\\it push", "git\\\n commit -m x"):
            with self.subTest(cmd=cmd):
                self.assertEqual(h.check(cmd), 2)

    def test_other_commands_pass(self) -> None:
        h = Home()
        for cmd in ("git status", "git diff", "git log --oneline", "echo git commit is blocked",
                    "grep -n commit file", "git commit-tree abc", "python3 tests/x.py", "legit commit",
                    "echo 'пример; git commit -m x'", 'printf "%s" "a && git push"', "# git commit",
                    "cat <<'EOF' >note.md\ngit commit -m x\nEOF", "codex exec - <<P\nдифф: git push\nP",
                    "printf '%s\\n' ';' 'git' 'commit'", "echo '&&' git commit", "echo \"|\" git push",
                    "# git commit -m x\ngit status", 'echo note="example; git push origin"',
                    "echo a\\;git push", "echo 'x\n git push'", "echo 'if git commit'"):
            with self.subTest(cmd=cmd):
                self.assertEqual(h.check(cmd), 0)

    def test_unbalanced_quotes_fall_back_to_pattern(self) -> None:
        h = Home()
        self.assertEqual(h.check("git commit -m 'oops"), 2)
        self.assertEqual(h.check("echo 'oops"), 0)

    def test_stale_marker_blocked(self) -> None:
        h = Home()
        h.marker().parent.mkdir(parents=True)
        h.marker().write_text("1\n")
        old = time.time() - 3700
        os.utime(h.marker(), (old, old))
        self.assertEqual(h.check("git commit -m x"), 2)

    def test_future_marker_blocked(self) -> None:
        h = Home()
        h.marker().parent.mkdir(parents=True)
        h.marker().write_text("1\n")
        fut = time.time() + 7200
        os.utime(h.marker(), (fut, fut))
        self.assertEqual(h.check("git commit -m x"), 2)


class MarkerFromCodexCheck(unittest.TestCase):
    """Only the skill script writes the marker, and only on a real APPROVE from Codex."""

    def test_approve_marks_then_commit_passes(self) -> None:
        h = Home()
        r = h.review("VERDICT: APPROVE\nзамечаний нет")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(r.stdout.startswith("codex: model=default verdict=APPROVE"))
        self.assertTrue(h.marker().exists())
        self.assertEqual(h.check("git commit -m x"), 0)
        self.assertEqual(h.check("git push"), 0)

    def test_request_changes_no_mark(self) -> None:
        h = Home()
        h.review("VERDICT: REQUEST_CHANGES\n1. bug")
        self.assertFalse(h.marker().exists())
        self.assertEqual(h.check("git commit -m x"), 2)

    def test_empty_and_conflict_no_mark(self) -> None:
        h = Home()
        h.review("no verdict here")
        h.review("VERDICT: APPROVE\nVERDICT: REQUEST_CHANGES")
        h.review("```\nVERDICT: APPROVE\n```")
        self.assertFalse(h.marker().exists())

    def test_disabled_no_mark(self) -> None:
        h = Home(enabled=False)
        h.review("VERDICT: APPROVE")
        self.assertFalse(h.marker().exists())

    def test_marker_per_agent(self) -> None:
        h = Home()
        h.review("VERDICT: APPROVE", agent="jarvis")
        self.assertTrue(h.marker("jarvis").exists())
        self.assertFalse(h.marker("coder").exists())
        self.assertEqual(h.check("git commit -m x"), 2)

    def test_printed_verdict_is_not_a_marker(self) -> None:
        """No hook reads Bash output: echoing a verdict line leaves no marker."""
        h = Home()
        subprocess.run(["bash", "-c", "echo 'codex: model=x verdict=APPROVE' # codex-check.sh"], env=h.env(),
                       capture_output=True)
        self.assertFalse(h.marker().exists())
        self.assertEqual(h.check("git commit -m x"), 2)


class NeverLocksOut(unittest.TestCase):
    """Without Codex switched on, installed and logged in, or with the owner's off switch, nothing is blocked."""

    def test_editorial_off(self) -> None:
        self.assertEqual(Home(enabled=False).check("git commit -m x"), 0)

    def test_no_codex_program(self) -> None:
        self.assertEqual(Home(codex=False).check("git commit -m x"), 0)

    def test_no_login(self) -> None:
        self.assertEqual(Home(login=False).check("git commit -m x"), 0)

    def test_empty_login_file(self) -> None:
        h = Home()
        (h.dir / ".codex/auth.json").write_text("")
        self.assertEqual(h.check("git commit -m x"), 0)

    def test_owner_off_switch(self) -> None:
        self.assertEqual(Home(extra="CODEX_COMMIT_GUARD=0\n").check("git commit -m x"), 0)

    def test_off_switch_quoted(self) -> None:
        self.assertEqual(Home(extra='CODEX_COMMIT_GUARD="0"\n').check("git commit -m x"), 0)

    def test_switch_one_keeps_gate(self) -> None:
        self.assertEqual(Home(extra="CODEX_COMMIT_GUARD=1\n").check("git commit -m x"), 2)

    def test_no_conf_at_all(self) -> None:
        h = Home()
        (h.dir / ".claude-lab/shared/editorial.conf").unlink()
        self.assertEqual(h.check("git commit -m x"), 0)

    def test_bad_input_passes(self) -> None:
        h = Home()
        for raw in ("not json", "null", "[]", '{"tool_input": "git commit"}'):
            with self.subTest(raw=raw):
                r = subprocess.run([sys.executable, str(GUARD), "check", "coder"], input=raw, text=True,
                                   capture_output=True, env=h.env())
                self.assertEqual(r.returncode, 0)

    def test_bad_args_pass(self) -> None:
        h = Home()
        for args in ([], ["check"], ["mark", "coder"], ["check", "../x"]):
            with self.subTest(args=args):
                r = subprocess.run([sys.executable, str(GUARD), *args], input='{"tool_input":{"command":"git commit"}}',
                                   text=True, capture_output=True, env=h.env())
                self.assertEqual(r.returncode, 0)


if __name__ == "__main__":
    unittest.main(verbosity=1)
