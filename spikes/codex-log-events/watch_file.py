#!/usr/bin/env python3
"""Measure macOS vnode notifications for one already-bound rollout file."""

import argparse
from contextlib import closing
import datetime
import json
import os
import select
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path")
    parser.add_argument("--seconds", type=float, default=30)
    args = parser.parse_args()
    with open(args.path, "rb") as stream, closing(select.kqueue()) as queue:
        stream.seek(0, os.SEEK_END)
        event = select.kevent(stream.fileno(), filter=select.KQ_FILTER_VNODE,
                             flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
                             fflags=select.KQ_NOTE_WRITE | select.KQ_NOTE_EXTEND
                             | select.KQ_NOTE_RENAME | select.KQ_NOTE_DELETE)
        queue.control([event], 0)
        print(json.dumps({"kind": "ready", "wall": time.time()}), flush=True)
        deadline = time.monotonic() + args.seconds
        pending = b""
        while time.monotonic() < deadline:
            notifications = queue.control(None, 8, min(1, deadline - time.monotonic()))
            if not notifications:
                continue
            seen = time.time()
            chunk = stream.read()
            print(json.dumps({"kind": "vnode", "wall": seen, "bytes": len(chunk),
                              "flags": [item.fflags for item in notifications]}), flush=True)
            lines = (pending + chunk).split(b"\n")
            pending = lines.pop()
            for line in lines:
                record = json.loads(line)
                payload = record.get("payload", {})
                stamp = datetime.datetime.fromisoformat(record["timestamp"].replace("Z", "+00:00")).timestamp()
                print(json.dumps({"kind": "record", "wall": seen,
                                  "record_type": record["type"], "event": payload.get("type"),
                                  "turn_id": payload.get("turn_id"), "timestamp": record["timestamp"],
                                  "visibility_lag_ms": (seen - stamp) * 1000}), flush=True)


if __name__ == "__main__":
    main()
