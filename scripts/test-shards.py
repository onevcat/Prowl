#!/usr/bin/env python3
"""Split the tests of an `xcodebuild -enumerate-tests` result into shards of whole suites.

Most suites run on the main actor, so one test process runs them nearly one at a time. Each
shard runs in its own process, with its own main thread. The list comes from the built test
bundle, so a new suite always runs. The costs file only balances the shards.
"""

import argparse
import json
from pathlib import Path
import sys

# The cost of a test in a suite that the costs file does not list. Most tests take about this.
DEFAULT_TEST_COST = 0.01


def is_excluded(identifier, excluded):
    return any(identifier == entry or identifier.startswith(f"{entry}/") for entry in excluded)


def suites_from(enumeration, excluded=()):
    """Return the number of selected tests of each suite, by suite path without the test target."""
    if enumeration.get("errors"):
        raise ValueError(f"test enumeration reported errors: {enumeration['errors']}")
    suites = {}
    for value in enumeration.get("values", []):
        for test in value.get("enabledTests", []):
            identifier = test["identifier"]
            if is_excluded(identifier, excluded):
                continue
            path = identifier.split("/")[1:]
            # A test outside a suite has a path of one part, and it is its own selection.
            suite = "/".join(path[:-1]) or path[0]
            suites[suite] = suites.get(suite, 0) + 1
    if not suites:
        raise ValueError("test enumeration selected no tests")
    return suites


def partition(suites, costs, shard_count):
    """Assign the most expensive suite first, always to the shard with the least cost so far."""

    def cost(suite):
        return costs.get(suite, suites[suite] * DEFAULT_TEST_COST)

    shards = [{"cost": 0.0, "suites": []} for _ in range(shard_count)]
    for suite in sorted(suites, key=lambda name: (-cost(name), name)):
        lightest = min(shards, key=lambda shard: shard["cost"])
        lightest["cost"] += cost(suite)
        lightest["suites"].append(suite)
    return [shard["suites"] for shard in shards if shard["suites"]]


def main(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--enumeration", type=Path, required=True)
    parser.add_argument("--costs", type=Path, required=True)
    parser.add_argument("--excluded", type=Path, required=True, help="one test or suite identifier in each line")
    parser.add_argument("--shards", type=int, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--target", default="ProwlTests")
    options = parser.parse_args(arguments)
    if options.shards < 1:
        parser.error("--shards must be positive")

    excluded = [line for line in options.excluded.read_text().splitlines() if line]
    suites = suites_from(json.loads(options.enumeration.read_text()), excluded)
    shards = partition(suites, json.loads(options.costs.read_text()), options.shards)

    options.out.mkdir(parents=True, exist_ok=True)
    for index, shard in enumerate(shards):
        arguments_text = "".join(f"-only-testing:{options.target}/{suite}\n" for suite in shard)
        (options.out / f"shard{index}.args").write_text(arguments_text)
        (options.out / f"shard{index}.count").write_text(f"{sum(suites[suite] for suite in shard)}\n")
    print(f"{sum(suites.values())} test(s) in {len(suites)} suite(s), {len(shards)} shard(s).", file=sys.stderr)
    return len(shards)


if __name__ == "__main__":
    print(main())
