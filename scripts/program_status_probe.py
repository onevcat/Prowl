#!/usr/bin/env python3
"""Replay harness for the OSC 7501 program status protocol.

Spawns a program in a pty, answers its support query (`OSC 7501 ; ?`, echoed
back with the same terminator), DA1 and the kitty keyboard query, sends
scripted keys, and prints every OSC 7501 report with a timestamp. Use it to
record what a producer actually sends before relying on it in Prowl
(docs-ai/079-program-status-osc-7501).

    scripts/program_status_probe.py --seconds 40 \
      --keys '3:\\x1b[B;3.3:\\r;7:reply with just the word ok\\r' -- claude

`--keys` is `at_seconds:bytes;...`; bytes use Python escapes. `--dump` also
prints the last lines of plain text the program drew.
"""
import argparse
import fcntl
import os
import pty
import re
import select
import signal
import struct
import termios
import time

QUERY = re.compile(rb"\x1b\]7501;\?(\x07|\x1b\\)")
REPORT = re.compile(rb"\x1b\]7501;([^\x07\x1b]*)(\x07|\x1b\\)")
DA1 = re.compile(rb"\x1b\[0?c")
KITTY_KEYBOARD_QUERY = re.compile(rb"\x1b\[\?u")
ESCAPES = re.compile(rb"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)")


def parse_keys(spec):
    keys = []
    for item in filter(None, spec.split(";")):
        at, _, data = item.partition(":")
        keys.append((float(at), data.encode().decode("unicode_escape").encode()))
    return sorted(keys)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--seconds", type=float, default=20, help="time budget")
    parser.add_argument("--keys", default="", help="scripted keys: at_seconds:bytes;...")
    parser.add_argument("--dump", action="store_true", help="print the last plain-text lines")
    parser.add_argument("--keep-env", action="store_true", help="keep CLAUDE* variables (nested session)")
    parser.add_argument("command", nargs="+")
    args = parser.parse_args()
    keys = parse_keys(args.keys)

    pid, fd = pty.fork()
    if pid == 0:
        if not args.keep_env:
            for name in [k for k in os.environ if k.startswith("CLAUDE")]:
                os.environ.pop(name, None)
        os.environ["TERM"] = "xterm-256color"
        os.execvp(args.command[0], args.command)

    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    started = time.time()
    output = b""
    events = []
    answered = set()

    def elapsed():
        return round(time.time() - started, 2)

    def answer(tag, pattern, reply):
        if tag in answered:
            return
        match = pattern.search(output)
        if match:
            os.write(fd, reply(match) if callable(reply) else reply)
            answered.add(tag)
            events.append((elapsed(), f"{tag} -> answered"))

    while time.time() - started < args.seconds:
        while keys and time.time() - started >= keys[0][0]:
            _, data = keys.pop(0)
            os.write(fd, data)
            events.append((elapsed(), f"keys {data!r}"))
        ready, _, _ = select.select([fd], [], [], 0.05)
        if fd not in ready:
            continue
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            events.append((elapsed(), "pty closed"))
            break
        if not chunk:
            break
        output += chunk
        answer("7501 query", QUERY, lambda m: b"\x1b]7501;?" + m.group(1))
        answer("DA1", DA1, b"\x1b[?65;1;9c")
        answer("kitty keyboard query", KITTY_KEYBOARD_QUERY, b"\x1b[?0u")
        for match in REPORT.finditer(chunk):
            body = match.group(1).decode("ascii", "replace")
            if body != "?":
                events.append((elapsed(), "REPORT " + body))

    status = os.waitpid(pid, os.WNOHANG)
    print("alive at end:", status == (0, 0))
    try:
        os.kill(pid, signal.SIGTERM)
        time.sleep(0.3)
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    for at, event in events:
        print(f"{at:6.2f}s  {event}")
    if args.dump:
        text = ESCAPES.sub(b"", output).replace(b"\r", b"")
        lines = [line for line in text.decode("utf-8", "replace").split("\n") if line.strip()]
        print("--- last 25 non-empty text lines ---")
        print("\n".join(lines[-25:]))


if __name__ == "__main__":
    main()
