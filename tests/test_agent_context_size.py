#!/usr/bin/env python3
"""Tests for agent_context_size.py (agents-reset loop fix, 29.10.2026)."""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
HELPER = HERE.parent / "lib" / "agent_context_size.py"
SCRIPT = HERE.parent / "lib" / "agents-reset.sh"
AGENT = "jarvis"
PREFIX = f"-home-agent--claude-lab-{AGENT}--claude"
SUB = f"{PREFIX}-dashi-plugin-claude-code-plugin"


def iso(ts: float) -> str:
    return datetime.fromtimestamp(ts, tz=timezone.utc).isoformat().replace("+00:00", "Z")


class ContextSizeTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.projects = self.root / "projects"
        (self.projects / SUB).mkdir(parents=True)
        self.state = self.root / "last-reset"
        self.now = time.time()
        self.start = self.now - 600  # service (re)started 10 min ago

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def transcript(self, name: str, turns: list[tuple[float, int]], tail_untimed: bool = False,
                   mtime: float | None = None) -> Path:
        p = self.projects / SUB / f"{name}.jsonl"
        with p.open("w", encoding="utf-8") as fh:
            for ts, cr in turns:
                fh.write(json.dumps({"type": "user", "timestamp": iso(ts)}) + "\n")
                fh.write(json.dumps({"type": "assistant", "timestamp": iso(ts + 1),
                                     "message": {"usage": {"cache_read_input_tokens": cr}}}) + "\n")
            if tail_untimed:  # the dying CLI appends these without "timestamp"
                for t in ("mode", "permission-mode", "cost-state"):
                    fh.write(json.dumps({"type": t}) + "\n")
        if mtime is not None:
            os.utime(p, (mtime, mtime))
        return p

    def run_helper(self, start: float | str | None = None, with_state: bool = True) -> str:
        args = [sys.executable, str(HELPER), PREFIX, str(self.projects),
                str(self.start if start is None else start)]
        if with_state:
            args.append(str(self.state))
        out = subprocess.run(args, capture_output=True, text=True, check=True)
        return out.stdout.strip()

    def test_ordinary_current_session_is_measured(self) -> None:
        self.transcript("old", [(self.now - 7200, 287583)], mtime=self.now - 7000)
        cur = self.transcript("cur", [(self.now - 300, 120000), (self.now - 60, 260000)])
        self.assertEqual(self.run_helper(), f"260000\t{cur}")

    def test_new_session_without_jsonl_is_skipped(self) -> None:
        # the loop case: old transcript, mtime even bumped AFTER start by untimed records
        self.transcript("old", [(self.now - 7200, 287583)], tail_untimed=True, mtime=self.now - 30)
        self.assertEqual(self.run_helper(), "NOSESSION")

    def test_new_session_grown_over_threshold_is_measured(self) -> None:
        self.transcript("old", [(self.now - 7200, 287583)], tail_untimed=True, mtime=self.now - 590)
        cur = self.transcript("new", [(self.now - 200, 150000), (self.now - 30, 300000)])
        self.assertEqual(self.run_helper(), f"300000\t{cur}")

    def test_same_transcript_after_reset_is_not_reset_again(self) -> None:
        cur = self.transcript("cur", [(self.now - 60, 287583)])
        self.state.write_text(f"{cur}\t287583\n", encoding="utf-8")
        self.assertEqual(self.run_helper(), f"SAME\t287583\t{cur}")

    def test_same_path_grown_after_reset_is_measured(self) -> None:
        cur = self.transcript("cur", [(self.now - 60, 300000)])
        self.state.write_text(f"{cur}\t287583\n", encoding="utf-8")
        self.assertEqual(self.run_helper(), f"300000\t{cur}")

    def test_old_session_before_start_never_counts(self) -> None:
        self.transcript("old", [(self.now - 7200, 287583)], mtime=self.now - 7000)
        self.assertEqual(self.run_helper(), "NOSESSION")

    def test_no_transcripts(self) -> None:
        self.assertEqual(self.run_helper(), "NODATA")

    def test_bad_start_is_error(self) -> None:
        self.transcript("cur", [(self.now - 60, 300000)])
        self.assertEqual(self.run_helper(start="x"), "ERR")
        self.assertEqual(self.run_helper(start=0), "ERR")

    def test_damaged_state_file_is_error(self) -> None:
        self.transcript("cur", [(self.now - 60, 300000)])
        for bad in ("garbage", "", "\t300000"):
            self.state.write_text(bad, encoding="utf-8")
            self.assertEqual(self.run_helper(), "ERR", repr(bad))

    def test_unreadable_state_file_is_error(self) -> None:
        self.transcript("cur", [(self.now - 60, 300000)])
        self.state.mkdir()  # a directory: unreadable for root too
        self.assertEqual(self.run_helper(), "ERR")

    def test_bad_prefix_is_error(self) -> None:
        self.transcript("cur", [(self.now - 60, 300000)])
        out = subprocess.run([sys.executable, str(HELPER), "a/b", str(self.projects),
                              str(self.start)], capture_output=True, text=True, check=True)
        self.assertEqual(out.stdout.strip(), "ERR")

    def test_other_agent_dirs_are_ignored(self) -> None:
        other = self.projects / (PREFIX.replace(AGENT, "jarvis2") + "-x")
        other.mkdir(parents=True)
        (other / "o.jsonl").write_text(json.dumps({"timestamp": iso(self.now - 10),
            "message": {"usage": {"cache_read_input_tokens": 999999}}}) + "\n", encoding="utf-8")
        cur = self.transcript("cur", [(self.now - 60, 200000)])
        self.assertEqual(self.run_helper(), f"200000\t{cur}")

    def test_newest_of_two_current_sessions_wins(self) -> None:
        self.transcript("a", [(self.now - 300, 100000)])
        b = self.transcript("b", [(self.now - 30, 180000)])
        self.assertEqual(self.run_helper(), f"180000\t{b}")


class ScriptWiringTest(unittest.TestCase):
    """agents-reset.sh must use the helper and record the last reset."""

    def test_script_wiring(self) -> None:
        s = SCRIPT.read_text(encoding="utf-8")
        self.assertIn('"$LIB/agent_context_size.py" "$(project_prefix "$1")"', s)
        self.assertIn("NOSESSION)", s)
        self.assertIn("SAME$'\\t'*)", s)
        self.assertIn('mv -f "$LAST_RESET_DIR/.$agent.tmp" "$LAST_RESET_DIR/$agent"', s)
        self.assertIn('[ "$DRY" = 1 ] || mkdir -p "$LAST_RESET_DIR"', s)
        self.assertIn("echo $(( raw + 1 ))", s)
        self.assertNotIn("sorted(glob.glob(pat), key=os.path.getmtime)", s)
        subprocess.run(["bash", "-n", str(SCRIPT)], check=True)


if __name__ == "__main__":
    unittest.main(verbosity=1)
