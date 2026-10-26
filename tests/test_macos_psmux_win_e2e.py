#!/usr/bin/env python3
"""Real macOS PTY -> psmux-win -> OpenSSH -T -> Windows psmux E2E."""

import fcntl
import os
import select
import signal
import struct
import subprocess
import sys
import termios
import time
from pathlib import Path


def required_env(name):
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"required environment variable is unset: {name}")
    return value


SESSION = required_env("PSMUX_E2E_SESSION")
SOCKET = os.environ.get("PSMUX_E2E_SOCKET")
WINDOWS = required_env("PSMUX_E2E_WINDOWS_HOST")
REMOTE_PSMUX = required_env("PSMUX_E2E_REMOTE_EXE")
WRAPPER = os.environ.get(
    "PSMUX_E2E_WRAPPER",
    str(Path(__file__).resolve().parent.parent / "scripts" / "psmux-ssh.sh"),
)


def remote(*args):
    command = ["ssh", "-T", "-o", "BatchMode=yes", WINDOWS, REMOTE_PSMUX]
    if SOCKET:
        command.extend(["-L", SOCKET])
    command.extend(args)
    return subprocess.check_output(command, text=True, timeout=15).strip()


def state():
    output = remote(
        "list-panes",
        "-t",
        SESSION,
        "-F",
        "#{pane_in_mode}:#{scroll_position}:#{history_size}",
    )
    mode, offset, history = output.split(":")
    return int(mode), int(offset), int(history)


def drain(master, seconds, captured):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        ready, _, _ = select.select([master], [], [], 0.1)
        if not ready:
            continue
        try:
            chunk = os.read(master, 65536)
        except OSError:
            return False
        if not chunk:
            return False
        captured.extend(chunk)
        # Answer psmux's XTWINOPS terminal-size query on the real Mac PTY.
        if b"\x1b[18t" in chunk:
            os.write(master, b"\x1b[8;30;100t")
    return True


def main():
    # Make the starting state deterministic if a previous manual attach left
    # the test pane in copy mode.
    remote("send-keys", "-X", "cancel", "-t", SESSION)
    before = state()
    if before[2] <= 0:
        raise AssertionError(f"test session has no scrollback: {before}")

    pid, master = os.forkpty()
    if pid == 0:
        command = ["sh", WRAPPER]
        if SOCKET:
            command.extend(["--socket", SOCKET])
        command.extend(
            ["--session", SESSION, "--psmux", REMOTE_PSMUX, "--", WINDOWS]
        )
        os.execvp("sh", command)

    captured = bytearray()
    stage = "startup"
    try:
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
        drain(master, 4.0, captured)
        stage = "mouse-enable check"
        required_on = (b"\x1b[?1000h", b"\x1b[?1002h", b"\x1b[?1006h")
        if not all(sequence in captured for sequence in required_on):
            raise AssertionError("Mac PTY did not receive all mouse-enable sequences")

        stage = "first WheelUp"
        os.write(master, b"\x1b[<64;10;5M")
        drain(master, 1.5, captured)
        first = state()
        if first[0] != 1 or first[1] <= 0:
            raise AssertionError(f"WheelUp did not enter/scroll copy mode: {before} -> {first}")

        stage = "second WheelUp"
        os.write(master, b"\x1b[<64;10;5M")
        drain(master, 1.0, captured)
        second = state()
        if second[1] <= first[1]:
            raise AssertionError(f"repeated WheelUp did not advance: {first} -> {second}")

        # Default prefix Ctrl+B followed by d detaches, allowing the wrapper's
        # EXIT trap to restore the Mac terminal state and disable mouse mode.
        stage = "detach"
        os.write(master, b"\x02d")
        drain(master, 5.0, captured)
        waited, status = os.waitpid(pid, os.WNOHANG)
        if waited == 0:
            raise AssertionError("wrapper did not exit after psmux detach")
        pid = 0
        exit_code = os.waitstatus_to_exitcode(status)
        if exit_code != 0:
            raise AssertionError(f"wrapper exited with status {exit_code} after detach")

        required_off = (b"\x1b[?1006l", b"\x1b[?1002l", b"\x1b[?1000l")
        if not all(sequence in captured for sequence in required_off):
            raise AssertionError("Mac PTY did not receive all mouse-disable cleanup sequences")

        print("PASS: macOS PTY received DECSET 1000/1002/1006")
        print(f"PASS: SGR WheelUp entered copy mode (offset={first[1]})")
        print(f"PASS: repeated WheelUp advanced offset ({first[1]} -> {second[1]})")
        print("PASS: detach emitted DEC reset cleanup for 1006/1002/1000")
        return 0
    except Exception:
        print(f"PTY failure stage: {stage}", file=sys.stderr)
        print(repr(bytes(captured[-4000:])), file=sys.stderr)
        raise
    finally:
        if pid:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                os.waitpid(pid, 0)
            except ChildProcessError:
                pass
        os.close(master)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
