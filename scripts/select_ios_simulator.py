#!/usr/bin/env python3
"""Print the xcodebuild destination of the iOS simulator to test on.

Simulator model names change with each Xcode release, so the caller gives a regular
expression for the full name (for example `iPhone [0-9]+ Pro`). The newest matching
model on the newest runtime that the selected Xcode supports is used.
"""
import json
import re
import subprocess
import sys
from typing import NamedTuple


class Simulator(NamedTuple):
    runtime: tuple[int, ...]
    name: str
    udid: str

    @property
    def destination(self) -> str:
        return f"platform=iOS Simulator,id={self.udid}"


def parse_version(text: str) -> tuple[int, ...]:
    components = [int(component) for component in text.split(".")]
    return tuple((components + [0, 0])[:3])


def runtime_version(runtime: str) -> tuple[int, ...]:
    match = re.search(r"iOS-(\d+)-(\d+)(?:-(\d+))?$", runtime)
    if match is None:
        return ()
    return tuple(int(component) for component in match.groups(default="0"))


def model_order(name: str) -> tuple[object, ...]:
    # Compare digit runs as numbers, so that "iPhone 17 Pro" sorts after "iPhone 9 Pro".
    return tuple(int(part) if part.isdigit() else part for part in re.split(r"(\d+)", name))


def select_simulator(
    devices_by_runtime: dict[str, list[dict[str, object]]],
    pattern: str,
    max_runtime: tuple[int, ...] | None = None,
) -> Simulator:
    name_pattern = re.compile(pattern)
    candidates: list[tuple[tuple[int, ...], tuple[object, ...], Simulator]] = []
    for runtime, devices in devices_by_runtime.items():
        version = runtime_version(runtime)
        if not version or (max_runtime is not None and version > max_runtime):
            continue
        for device in devices:
            name = str(device.get("name", ""))
            if device.get("isAvailable") and name_pattern.fullmatch(name):
                simulator = Simulator(version, name, str(device["udid"]))
                candidates.append((version, model_order(name), simulator))

    if not candidates:
        raise ValueError(f"no available iOS simulator matches {pattern!r}")
    return max(candidates, key=lambda candidate: candidate[:2])[2]


def run(arguments: list[str]) -> str:
    return subprocess.run(arguments, check=True, capture_output=True, text=True).stdout


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <simulator-name-pattern>", file=sys.stderr)
        return 2

    sdk_version = parse_version(run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"]).strip())
    devices = json.loads(run(["xcrun", "simctl", "list", "devices", "available", "--json"]))["devices"]
    try:
        simulator = select_simulator(devices, sys.argv[1], max_runtime=sdk_version)
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    runtime = ".".join(str(component) for component in simulator.runtime)
    print(f"Selected {simulator.name} (iOS {runtime}, {simulator.udid})", file=sys.stderr)
    print(simulator.destination)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
