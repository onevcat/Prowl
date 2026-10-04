#!/usr/bin/env python3
"""Summarize xcresulttool build logs without adding overlapping task times, and test action logs."""

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


def sections(node):
    for child in node.get("subsections", []):
        yield child
        yield from sections(child)


def summarize_test_launch(log, name):
    """Show when the test runner launch and the first test suite start in a test action log.

    A large gap between them is time before any test runs (for example a slow first launch of
    the test host), which the build log and the test results do not show.
    """
    start = log.get("startTime", 0)

    def first(prefix):
        times = [
            section["startTime"] for section in sections(log)
            if section.get("title", "").startswith(prefix) and "startTime" in section
        ]
        return min(times) - start if times else None

    lines = [f"### {name}", "", f"Test action: **{log.get('duration', 0):.1f} s**", ""]
    for label, offset in (
        ("Test runner launch", first("Launching ")),
        ("First test suite", first("Run test suite ")),
    ):
        lines.append(f"- {label}: not recorded" if offset is None else f"- {label} starts at **{offset:.1f} s**")
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    for argument in sys.argv[1:]:
        path = Path(argument)
        try:
            log = json.loads(path.read_text())
            if path.name.endswith(".action.json"):
                print(summarize_test_launch(log, path.name))
            else:
                print(summarize(log, path.name))
        except (OSError, ValueError, KeyError, TypeError) as error:
            # Build diagnostics must not replace the build or test exit status.
            print(f"Build metrics unavailable for {path.name}: {error}", file=sys.stderr)
