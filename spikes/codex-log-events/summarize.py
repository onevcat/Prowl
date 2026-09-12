#!/usr/bin/env python3
"""Export content-free evidence from probe.py observations."""

import argparse
from collections import Counter
import datetime
import json
from pathlib import Path
import statistics


def summarize(root):
    result = {"runs": {}}
    for name in ["first", "second", "resumed"]:
        rows = [json.loads(line) for line in (root / name / "observations.jsonl").read_text().splitlines()]
        spawn = next(row for row in rows if row["kind"] == "spawn")
        owners = [row for row in rows if row["kind"] == "open_rollouts"]
        owned = {Path(file["path"]).name for row in owners for file in row["files"]}
        live = [row for row in rows if row["kind"] == "record"
                and Path(row["path"]).name in owned
                and datetime.datetime.fromisoformat(row["timestamp"].replace("Z", "+00:00")).timestamp() >= spawn["wall"]]
        lifecycle = []
        controls = [row for row in rows if row["kind"] == "control"]
        for row in live:
            if row.get("event") not in {"task_started", "task_complete", "turn_aborted"}:
                continue
            value = {key: row[key] for key in ["elapsed", "event", "turn_id", "timestamp", "visibility_lag_ms"]}
            value["file"] = Path(row["path"]).name
            enters = [item for item in controls if item["wall"] <= row["wall"]
                      and item["command"].get("text") == "\r"]
            if row["event"] == "task_started" and enters:
                value["enter_to_visible_ms"] = (row["wall"] - enters[-1]["wall"]) * 1000
            lifecycle.append(value)
        result["runs"][name] = {
            "pid": spawn["pid"],
            "spawn_wall": spawn["wall"],
            "controls": [{"elapsed": row["elapsed"], **row["command"]} for row in controls],
            "open_rollouts": [{"elapsed": row["elapsed"], "files": [
                {"file": Path(file["path"]).name, "mode": file["mode"]} for file in row["files"]
            ]} for row in owners],
            "event_counts": dict(Counter(row.get("event") for row in live if row["record_type"] == "event_msg")),
            "lifecycle": lifecycle,
            "exit": [{"elapsed": row["elapsed"], "status": row["status"]} for row in rows if row["kind"] == "process_exit"],
        }
    all_lifecycle = [row for run in result["runs"].values() for row in run["lifecycle"]]
    result["polling_visibility_ms"] = {}
    for event in ["task_started", "task_complete", "turn_aborted"]:
        values = [row["visibility_lag_ms"] for row in all_lifecycle if row["event"] == event]
        result["polling_visibility_ms"][event] = dict(n=len(values), minimum=min(values),
                                                   median=statistics.median(values), maximum=max(values))
    result["vnode"] = [json.loads(line) for line in (root / "vnode.jsonl").read_text().splitlines()]
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    print(json.dumps(summarize(args.root), indent=2))
