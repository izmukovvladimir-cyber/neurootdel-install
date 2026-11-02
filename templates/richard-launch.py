"""Richard launcher: start claude-code-telegram with the bot token kept out of the log.

python-telegram-bot talks to https://api.telegram.org/bot<TOKEN>/..., and httpx logs
every request URL at INFO. claude-code-telegram sends all logging to stdout, which the
systemd unit forwards to journald, so without this launcher the bot token lands in
the system journal in clear text (thousands of lines a day from getUpdates polling).
The package's setup_logging() only calls logging.basicConfig(level=INFO) on the root
logger, so lowering the httpx/httpcore levels here, before the package starts, holds
for the whole run.

Quiet httpx is not enough: a rejected token ends the run with
telegram.error.InvalidToken("The token `<TOKEN>` was rejected by the server."), and that
error reaches the journal as structlog JSON and as the final traceback, with no "bot"
prefix in front of the token. So the token is filtered where the process meets the
journal, at the file descriptors: the launcher forks, the bot runs in the child with
fd 1 and fd 2 on a pipe, and this process (the unit's main PID) copies the pipe to the
journal with every token replaced by a mask. Every writer is covered the same way:
logging, structlog, print, sys.__stderr__, os.write, faulthandler, the uncaught
traceback and any subprocess that inherits the descriptors.

A token cut over two writes is still masked: whole lines are filtered, and an
unfinished line is held back from its trailing run of token characters on.

The parent ignores SIGTERM/SIGINT/SIGHUP (systemd signals the whole cgroup, the child
gets them directly), drains the pipe, and ends the way the child ended: its exit code,
or the same signal. The fix lives outside the package's site-packages, so a pip
upgrade of claude-code-telegram does not undo it.
"""

from __future__ import annotations

import errno
import os
import re
import select
import signal
import sys
import time

MASK = b"<bot-token>"
# <bot id>:<secret>; real ids are ~10 digits, secrets 35 chars of [A-Za-z0-9_-]. Both parts are
# bounded: every try costs at most ~100 bytes (linear on any input), and a match never grows
# with the text around it, so a held tail stays small. A longer secret-like run is masked from
# its start, the bytes past 64 stay as they are.
_TOKEN_SHAPE = re.compile(rb"[0-9]{5,32}:[A-Za-z0-9_-]{30,64}")
# Characters a token is made of: an unfinished line is held from its trailing run of these.
_TOKEN_CHARS = frozenset(b"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-:")
_MIN_SECRET_PART = 6  # the part after ":" alone is masked only when it is at least this long
_HOLD_MAX = 4096  # longer trailing runs are not held whole (only their last _HOLD_TAIL bytes)
_HOLD_TAIL = 128
_DRAIN_AFTER_EXIT = 2.0  # seconds the pipe is still read once the bot has exited


def secrets_from_env(env: dict[str, str]) -> list[bytes]:
    """The configured token (any non-empty value) and its secret part, longest first."""
    value = env.get("TELEGRAM_BOT_TOKEN", "").strip()
    out = set()
    if value:
        out.add(value.encode())
    secret = value.partition(":")[2]
    if len(secret) >= _MIN_SECRET_PART:
        out.add(secret.encode())
    return sorted(out, key=len, reverse=True)


def mask(data: bytes, secrets: list[bytes]) -> bytes:
    """Return data with the configured token and every token-shaped string replaced by MASK."""
    for s in secrets:
        data = data.replace(s, MASK)
    return _TOKEN_SHAPE.sub(MASK, data)


def _spans(buf: bytes, secrets: list[bytes]) -> list[tuple[int, int]]:
    spans = [m.span() for m in _TOKEN_SHAPE.finditer(buf)]
    for s in secrets:
        i = buf.find(s)
        while i != -1:
            spans.append((i, i + len(s)))
            i = buf.find(s, i + 1)
    return spans


def split_ready(buf: bytes, final: bool, secrets: list[bytes] = ()) -> tuple[bytes, bytes]:
    """Split buf into (ready to filter and emit, held back until more data arrives).

    The cut never goes through a token: whole lines go out, an unfinished line is held from
    its trailing run of token characters on, a buffer ending in the beginning of a configured
    token is held from there, and a complete token is never split between the two parts.
    """
    if final:
        return buf, b""
    n = len(buf)
    cut = buf.rfind(b"\n") + 1
    run = 0
    while run < n - cut and buf[n - 1 - run] in _TOKEN_CHARS:
        run += 1
    if run > _HOLD_MAX:
        run = max(_HOLD_TAIL, 2 * max((len(s) for s in secrets), default=0))
    at = n - run
    for s in secrets:
        for k in range(min(len(s) - 1, n), 0, -1):
            if buf.endswith(s[:k]):
                at = min(at, n - k)
                break
    for start, end in _spans(buf, secrets):
        if start < at < end:
            at = start
    return buf[:at], buf[at:]


def _write_all(fd: int, data: bytes) -> None:
    while data:
        try:
            n = os.write(fd, data)
        except InterruptedError:
            continue
        except OSError as exc:
            if exc.errno == errno.EPIPE:
                return
            raise
        data = data[n:]


def _child(read_end: int, write_end: int) -> None:
    os.close(read_end)
    os.dup2(write_end, 1)
    os.dup2(write_end, 2)
    os.close(write_end)

    import logging

    for _name in ("httpx", "httpcore"):
        logging.getLogger(_name).setLevel(logging.WARNING)

    from src.main import run

    run()


def _exit_like(status: int) -> None:
    if os.WIFSIGNALED(status):
        sig = os.WTERMSIG(status)
        try:
            signal.signal(sig, signal.SIG_DFL)
        except (OSError, ValueError):
            pass  # SIGKILL/SIGSTOP: no handler to reset, the kill below still works
        os.kill(os.getpid(), sig)
    os._exit(os.waitstatus_to_exitcode(status) if os.WIFEXITED(status) else 1)


def _pump(read_end: int, pid: int, secrets: list[bytes], out_fd: int) -> int:
    """Copy read_end to out_fd masked until EOF; once the child is gone, at most _DRAIN_AFTER_EXIT more.

    A subprocess that inherited the pipe and keeps writing must not keep the main PID alive:
    systemd would never see the bot die, and Restart=on-failure would never fire.
    """
    buf = b""
    status = None
    deadline = 0.0
    while True:
        if status is None:
            done, st = os.waitpid(pid, os.WNOHANG)
            if done:
                status = st
                deadline = time.monotonic() + _DRAIN_AFTER_EXIT
                os.set_blocking(read_end, False)
        try:
            ready, _, _ = select.select([read_end], [], [], 1.0)
        except InterruptedError:
            continue
        chunk = b""
        eof = False
        if ready:
            try:
                chunk = os.read(read_end, 65536)
                eof = chunk == b""
            except BlockingIOError:
                eof = True  # child gone, nothing left right now
        elif status is not None:
            eof = True  # child gone and the pipe is quiet (a lingering grandchild keeps it open)
        if status is not None and time.monotonic() >= deadline:
            eof = True  # child gone, a writer still holds the pipe: stop reading
        buf += chunk
        emit, buf = split_ready(buf, eof, secrets)
        if emit:
            _write_all(out_fd, mask(emit, secrets))
        if eof:
            break
    os.close(read_end)
    if status is None:
        _, status = os.waitpid(pid, 0)
    return status


def main() -> None:
    secrets = secrets_from_env(dict(os.environ))
    sys.stdout.flush()
    sys.stderr.flush()
    read_end, write_end = os.pipe()
    pid = os.fork()
    if pid == 0:
        # The bot's own exit: return code, uncaught traceback and buffer flush as usual.
        _child(read_end, write_end)
        return
    os.close(write_end)
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, signal.SIG_IGN)
    _exit_like(_pump(read_end, pid, secrets, 1))


if __name__ == "__main__":
    main()
