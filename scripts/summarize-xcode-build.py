#!/usr/bin/env python3
"""Summarize xcresulttool build logs without adding overlapping task times."""

import json
from pathlib import Path
import sys


def summarize(log, name):
    lines = [f"### {name}", "", f"Build wall time: **{log['duration']:.1f} s**", ""]
    counters = {}
    for attachment in log.get("attachments", []):
        if attachment.get("uniformTypeIdentifier", "").endswith(".BuildOperationMetrics"):
            counters.update(json.loads(attachment["data"]).get("counters", {}))
    if counters:
        lines.extend(f"- {key}: {value}" for key, value in sorted(counters.items()))
    else:
        lines.append("Cache counters unavailable for this build.")
    lines.extend(["", "Slowest build tasks (times overlap):", "", "| Task | Seconds |", "| --- | ---: |"])
    tasks = sorted(log.get("subsections", []), key=lambda task: task.get("duration", 0), reverse=True)
    for task in tasks[:10]:
        title = " ".join(task.get("title", "Unknown").split()).replace("|", "\\|")
        if len(title) > 180:
            title = title[:177] + "..."
        lines.append(f"| {title} | {task.get('duration', 0):.1f} |")
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    for argument in sys.argv[1:]:
        path = Path(argument)
        try:
            print(summarize(json.loads(path.read_text()), path.name))
        except (OSError, ValueError, KeyError, TypeError) as error:
            # Build diagnostics must not replace the build or test exit status.
            print(f"Build metrics unavailable for {path.name}: {error}", file=sys.stderr)
