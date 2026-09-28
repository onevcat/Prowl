#!/usr/bin/env python3
"""Spike: map a daemon-mode Codex TUI to its rollout and derive working/idle.

Codex 0.158 TUIs attach to a shared app-server daemon, which owns every rollout
file. The TUI process holds none, so Prowl cannot find the rollout from the TUI
pid. This prototype restores a per-pane file source:

1. The pane runs Codex with CODEX_TUI_RECORD_SESSION=1 and a per-pane
   CODEX_TUI_SESSION_LOG_PATH. The TUI writes each outgoing UserTurn op, with a
   fresh client_user_message_id, to that file.
2. The daemon pid comes from $CODEX_HOME/app-server-daemon/daemon.pid.
3. The rollout that holds `"client_id":"<id>"` among the daemon's open rollouts
   is the thread this pane last submitted to. Lineage in session_meta maps a
   child thread to its root.
4. The same events the production CodexLogDecoder consumes decide the state.

Usage:
    codex-daemon-map.py --session-log PATH [--codex-home DIR] [--watch SECONDS]
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path


def daemon_pid(codex_home: Path) -> int | None:
    try:
        record = json.loads((codex_home / "app-server-daemon" / "daemon.pid").read_text())
    except (OSError, ValueError):
        return None
    pid = record.get("pid")
    if not isinstance(pid, int):
        return None
    try:
        os.kill(pid, 0)
    except OSError:
        return None
    return pid


def open_rollouts(pid: int) -> list[Path]:
    out = subprocess.run(
        ["lsof", "-Fn", "-p", str(pid)], capture_output=True, text=True, check=False
    ).stdout
    paths = []
    for line in out.splitlines():
        if line.startswith("n") and "/sessions/" in line and line.endswith(".jsonl"):
            paths.append(Path(line[1:]))
    return paths


def session_log_turns(path: Path) -> tuple[str | None, list[str]]:
    """Return the last session_start timestamp and the client ids submitted after it."""
    started, ids = None, []
    try:
        lines = path.read_text(errors="replace").splitlines()
    except OSError:
        return None, []
    for line in lines:
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if record.get("kind") == "session_start":
            started, ids = record.get("ts"), []
        elif record.get("kind") == "op":
            payload = record.get("payload")
            turn = payload.get("UserTurn") if isinstance(payload, dict) else None
            if isinstance(turn, dict) and turn.get("client_user_message_id"):
                ids.append(turn["client_user_message_id"])
    return started, ids


class Rollout:
    def __init__(self, path: Path):
        self.path = path
        self.id = None
        self.parent = None
        self.client_ids: set[str] = set()
        self.open_turns: dict[str, float] = {}
        # Mirrors CodexLogProvider: only the first line is the header, and a
        # forked rollout copies history until its own thread_settings_applied.
        self.live = True
        with path.open(errors="replace") as handle:
            for index, line in enumerate(handle):
                try:
                    record = json.loads(line)
                except ValueError:
                    continue
                if index == 0:
                    self._header(record)
                else:
                    self._consume(record)

    def _header(self, record: dict) -> None:
        payload = record.get("payload") or {}
        if record.get("type") != "session_meta":
            return
        self.id = payload.get("id")
        source = payload.get("source")
        if isinstance(source, dict):
            spawn = (source.get("subagent") or {}).get("thread_spawn") or {}
            self.parent = spawn.get("parent_thread_id")
        self.live = not isinstance(payload.get("forked_from_id"), str)

    def _consume(self, record: dict) -> None:
        kind, payload = record.get("type"), record.get("payload") or {}
        if kind != "event_msg":
            return
        event = payload.get("type")
        if event == "thread_settings_applied" and payload.get("thread_id") == self.id:
            self.live = True
            return
        if not self.live:
            return
        if event == "task_started":
            self.open_turns[payload.get("turn_id")] = time.time()
        elif event in ("task_complete", "turn_aborted"):
            self.open_turns.pop(payload.get("turn_id"), None)
        elif event == "item_completed":
            item = payload.get("item") or {}
            if item.get("type") == "UserMessage" and item.get("client_id"):
                self.client_ids.add(item["client_id"])


def resolve(session_log: Path, codex_home: Path) -> dict:
    pid = daemon_pid(codex_home)
    if pid is None:
        return {"state": "unavailable", "reason": "noDaemon"}
    started, ids = session_log_turns(session_log)
    if started is None:
        return {"state": "unavailable", "reason": "noSessionLog"}
    if not ids:
        return {"state": "unbound", "reason": "noSubmitSinceLaunch", "session_start": started}
    rollouts = [Rollout(p) for p in open_rollouts(pid)]
    by_id = {r.id: r for r in rollouts if r.id}

    def root_of(rollout: Rollout) -> str | None:
        seen, current = set(), rollout
        while current.parent:
            if current.id in seen or current.parent not in by_id:
                return current.parent
            seen.add(current.id)
            current = by_id[current.parent]
        return current.id

    # A new turn writes its user item about a second after task_started, and a
    # steered message waits for the next tool boundary. Keep the newest submit
    # that already reached a rollout, and report the newer one as pending.
    bound, pending = None, 0
    for client_id in reversed(ids):
        hits = [r for r in rollouts if client_id in r.client_ids]
        if len(hits) == 1:
            bound = hits[0]
            break
        if len(hits) > 1:
            return {"state": "unbound", "reason": "ambiguous", "client_id": client_id}
        pending += 1
    if bound is None:
        return {"state": "unbound", "reason": "pending", "pending": pending}
    hits = [bound]
    root = root_of(hits[0])
    family = [r for r in rollouts if r.id == root or root_of(r) == root]
    working = [r.id for r in family if r.open_turns]
    return {
        "state": "working" if working else "idle",
        "pending_submits": pending,
        "root": root,
        "bound_via": hits[0].id,
        "open_work": working,
        "family": sorted(r.id for r in family),
        "daemon_pid": pid,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--session-log", required=True, type=Path)
    parser.add_argument("--codex-home", type=Path, default=Path(os.environ.get("CODEX_HOME", "~/.codex")).expanduser())
    parser.add_argument("--watch", type=float, default=0)
    args = parser.parse_args()
    last = None
    while True:
        result = resolve(args.session_log, args.codex_home)
        line = json.dumps(result, sort_keys=True)
        if line != last:
            print(time.strftime("%H:%M:%S"), line, flush=True)
            last = line
        if not args.watch:
            return 0
        time.sleep(args.watch)


if __name__ == "__main__":
    sys.exit(main())
