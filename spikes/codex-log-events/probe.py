#!/usr/bin/env python3
"""Observe an isolated Codex TUI and its JSONL writes. Not a production detector."""

import argparse
import datetime
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import termios
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("run")
    parser.add_argument("--resume")
    args = parser.parse_args()
    run = args.root / args.run
    run.mkdir()
    control = run / "control.jsonl"
    control.touch()
    events = (run / "observations.jsonl").open("w", buffering=1)
    output = (run / "terminal.bin").open("wb", buffering=0)
    started = time.monotonic()

    def emit(kind, **fields):
        events.write(json.dumps(dict(kind=kind, wall=time.time(), elapsed=time.monotonic() - started, **fields)) + "\n")

    argv = ["codex", "--no-alt-screen", "--disable", "hooks", "-c", "notify=[]",
            "-s", "read-only", "-a", "on-request", "-C", str(args.root / "work")]
    if args.resume:
        argv += ["resume", args.resume]
    pid, master = pty.fork()
    if pid == 0:
        os.environ["CODEX_HOME"] = str(args.root / "home")
        os.environ["TERM"] = "xterm-256color"
        for key in list(os.environ):
            if key.startswith("PROWL_") or key in {"CODEX_THREAD_ID", "CODEX_MANAGED_BY_NPM"}:
                os.environ.pop(key)
        os.execvp(argv[0], argv)
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 140, 0, 0))
    (run / "pid").write_text(str(pid))
    emit("spawn", pid=pid, argv=argv)
    offsets = {}
    pending = {}
    control_offset = 0
    last_scan = last_fd = 0
    paths = []
    last_fds = None
    terminal_tail = b""
    alive = True
    end_at = started + 900
    try:
        while time.monotonic() < end_at:
            now = time.monotonic()
            if alive and select.select([master], [], [], 0)[0]:
                try:
                    data = os.read(master, 65536)
                except OSError:
                    data = b""
                if data:
                    output.write(data)
                    terminal_tail = (terminal_tail + data)[-256:]
                    for query, reply in [(b"\x1b[6n", b"\x1b[1;1R"), (b"\x1b[c", b"\x1b[?1;2c")]:
                        if query in terminal_tail:
                            os.write(master, reply)
                            terminal_tail = terminal_tail.replace(query, b"")
                    emit("terminal_bytes", count=len(data))
            with control.open("rb") as stream:
                stream.seek(control_offset)
                for line in stream:
                    if not line.endswith(b"\n"):
                        break
                    control_offset += len(line)
                    command = json.loads(line)
                    emit("control", command=command)
                    if command["action"] == "send":
                        os.write(master, command["text"].encode())
                    elif command["action"] == "kill":
                        os.kill(pid, signal.SIGKILL)
                    elif command["action"] == "stop":
                        end_at = now
            if now - last_scan >= 0.1:
                paths = list((args.root / "home" / "sessions").rglob("*.jsonl"))
                last_scan = now
            for path in paths:
                key = str(path)
                stat = path.stat()
                previous = offsets.get(key, (stat.st_ino, 0))
                if previous[0] != stat.st_ino or stat.st_size < previous[1]:
                    emit("file_reset", path=key)
                    previous = (stat.st_ino, 0)
                    pending[key] = b""
                with path.open("rb") as stream:
                    stream.seek(previous[1])
                    chunk = stream.read()
                    offsets[key] = (stat.st_ino, stream.tell())
                if not chunk:
                    continue
                seen_at = time.time()
                lines = (pending.get(key, b"") + chunk).split(b"\n")
                pending[key] = lines.pop()
                for line in lines:
                    record = json.loads(line)
                    payload = record.get("payload", {})
                    record_time = datetime.datetime.fromisoformat(record["timestamp"].replace("Z", "+00:00")).timestamp()
                    fields = dict(path=key, record_type=record.get("type"), event=payload.get("type"),
                                  turn_id=payload.get("turn_id"), timestamp=record["timestamp"],
                                  visibility_lag_ms=(seen_at - record_time) * 1000)
                    if record.get("type") == "session_meta":
                        fields["session"] = {k: payload.get(k) for k in ["id", "cli_version", "source", "originator", "cwd"]}
                    emit("record", **fields)
            if alive and now - last_fd >= 1:
                result = subprocess.run(["lsof", "-a", "-p", str(pid), "-Fnfa"], capture_output=True, text=True)
                fd, mode = None, None
                found = []
                for line in result.stdout.splitlines():
                    if line.startswith("f"):
                        fd = line[1:]
                    elif line.startswith("a"):
                        mode = line[1:]
                    elif line.startswith("n") and "/sessions/" in line and line.endswith(".jsonl"):
                        found.append(dict(fd=fd, mode=mode, path=line[1:]))
                if found != last_fds:
                    emit("open_rollouts", pid=pid, files=found)
                    last_fds = found
                last_fd = now
            if alive:
                ended, status = os.waitpid(pid, os.WNOHANG)
                if ended:
                    alive = False
                    emit("process_exit", status=status)
                    end_at = min(end_at, now + 3)
            time.sleep(0.02)
    finally:
        if alive:
            os.kill(pid, signal.SIGTERM)
            os.waitpid(pid, 0)
        os.close(master)
        emit("observer_stop")
        output.close()
        events.close()


if __name__ == "__main__":
    main()
