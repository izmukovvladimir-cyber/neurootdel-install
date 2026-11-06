#!/usr/bin/env python3
"""Tests for templates/secret-outbound-guard.py: the owner's personal chat is let through.

The owner's own word lifts the RED secrets ban (AGENT-RULES-STARTER section 7), so with
--owner <id> a channel reply/edit to exactly that chat passes; everything else stays guarded.

Run: python3 tests/test_secret_guard_owner.py   (no network, no root)
"""
from __future__ import annotations

import json
import subprocess
import sys
import unittest
from pathlib import Path

GUARD = Path(__file__).resolve().parent.parent / "templates" / "secret-outbound-guard.py"
OWNER = "5550001"
SECRET = "пароль: Xk9#mm2pQ"
REPLY = "mcp__dashi-channel__reply"
EDIT = "mcp__dashi-channel__edit_message"
NOTIFY = "mcp__gbrain-swarm__notify"


def run(tool_input: object, tool_name: str = REPLY, args: tuple[str, ...] = ("--owner", OWNER)) -> int:
    event = {"tool_name": tool_name, "tool_input": tool_input}
    return subprocess.run([sys.executable, str(GUARD), *args], input=json.dumps(event), text=True,
                          capture_output=True).returncode


def raw(stdin: str, args: tuple[str, ...] = ("--owner", OWNER)) -> int:
    return subprocess.run([sys.executable, str(GUARD), *args], input=stdin, text=True,
                          capture_output=True).returncode


class OwnerChat(unittest.TestCase):
    def test_owner_reply_passes(self) -> None:
        self.assertEqual(run({"chat_id": OWNER, "text": SECRET}), 0)

    def test_owner_int_id_passes(self) -> None:
        self.assertEqual(run({"chat_id": int(OWNER), "text": SECRET}), 0)

    def test_owner_edit_passes(self) -> None:
        self.assertEqual(run({"chat_id": OWNER, "message_id": "5", "text": SECRET}, EDIT), 0)


class StillBlocked(unittest.TestCase):
    def test_other_chat(self) -> None:
        self.assertEqual(run({"chat_id": "123456789", "text": SECRET}), 2)

    def test_group_with_owner_digits(self) -> None:
        self.assertEqual(run({"chat_id": f"-100{OWNER}", "text": SECRET}), 2)

    def test_lookalike_id(self) -> None:
        self.assertEqual(run({"chat_id": f"{OWNER}0", "text": SECRET}), 2)

    def test_padded_id(self) -> None:
        self.assertEqual(run({"chat_id": f" {OWNER}", "text": SECRET}), 2)

    def test_id_with_newline(self) -> None:
        self.assertEqual(run({"chat_id": f"{OWNER}\n", "text": SECRET}), 2)

    def test_missing_chat_id(self) -> None:
        self.assertEqual(run({"text": SECRET}), 2)

    def test_bool_chat_id(self) -> None:
        self.assertEqual(run({"chat_id": True, "text": SECRET}), 2)

    def test_swarm_notify_with_owner_id(self) -> None:
        self.assertEqual(run({"to_agent": "coder", "chat_id": OWNER, "payload": {"body": SECRET}}, NOTIFY), 2)

    def test_owner_id_only_nested(self) -> None:
        self.assertEqual(run({"chat_id": "1", "payload": {"chat_id": OWNER}, "text": SECRET}), 2)

    def test_owner_id_in_text_other_chat(self) -> None:
        self.assertEqual(run({"chat_id": "1", "text": f"для {OWNER}: {SECRET}"}), 2)


class NoOrBadOwner(unittest.TestCase):
    """Without a valid --owner nothing is let through: the guard is as strict as before."""

    def test_no_owner_arg(self) -> None:
        self.assertEqual(run({"chat_id": OWNER, "text": SECRET}, args=()), 2)

    def test_owner_flag_without_value(self) -> None:
        self.assertEqual(run({"chat_id": OWNER, "text": SECRET}, args=("--owner",)), 2)

    def test_empty_owner(self) -> None:
        self.assertEqual(run({"chat_id": "", "text": SECRET}, args=("--owner", "")), 2)

    def test_negative_owner(self) -> None:
        self.assertEqual(run({"chat_id": "-100123", "text": SECRET}, args=("--owner", "-100123")), 2)

    def test_garbage_owner(self) -> None:
        self.assertEqual(run({"chat_id": "abc", "text": SECRET}, args=("--owner", "abc")), 2)


class Unchanged(unittest.TestCase):
    """The patterns and the fail-open on unreadable input stay as they were."""

    def test_plain_talk_other_chat_passes(self) -> None:
        self.assertEqual(run({"chat_id": "1", "text": "пароли передаём только решением владельца"}), 0)

    def test_token_other_chat_blocked(self) -> None:
        self.assertEqual(run({"chat_id": "1", "text": "1234567890:AAH-abcdefghijklmnopqrstuvwxyz01234"}), 2)

    def test_non_object_json_passes(self) -> None:
        for stdin in ("null", "[]", "42", "not json"):
            with self.subTest(stdin=stdin):
                self.assertEqual(raw(stdin), 0)


if __name__ == "__main__":
    unittest.main(verbosity=1)
