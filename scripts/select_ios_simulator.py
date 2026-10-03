#!/usr/bin/env python3
import json
import re
import subprocess
import sys


def runtime_version(runtime: str) -> tuple[int, ...]:
    match = re.search(r"iOS-(\d+)-(\d+)(?:-(\d+))?$", runtime)
    if match is None:
        return ()
    return tuple(int(component) for component in match.groups(default="0"))


def destination_for(devices_by_runtime: dict[str, list[dict[str, object]]], name: str) -> str:
    candidates: list[tuple[tuple[int, ...], str]] = []
    for runtime, devices in devices_by_runtime.items():
        version = runtime_version(runtime)
        if not version:
            continue
        for device in devices:
            if device.get("name") == name and device.get("isAvailable"):
                candidates.append((version, str(device["udid"])))

    if not candidates:
        raise ValueError(f"no available iOS simulator named {name!r}")

    _, identifier = max(candidates)
    return f"platform=iOS Simulator,id={identifier}"


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <simulator-name>", file=sys.stderr)
        return 2

    result = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "available", "--json"],
        check=True,
        capture_output=True,
        text=True,
    )
    try:
        print(destination_for(json.loads(result.stdout)["devices"], sys.argv[1]))
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
