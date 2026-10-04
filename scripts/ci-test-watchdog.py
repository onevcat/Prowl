#!/usr/bin/env python3
"""Stop a CI test run that hangs, and keep evidence of where it hangs.

A hung `xcodebuild test` prints nothing until the job timeout, and a cancelled job keeps no
result bundle. When the test logs get no output for `--silence` seconds while xcodebuild
runs, this script samples xcodebuild and the test processes, then interrupts xcodebuild.
An interrupted xcodebuild still writes the result bundle, which marks the running test as
"Testing was canceled", and the step fails long before the job timeout.
"""

import argparse
import glob
import os
from pathlib import Path
import re
import signal
import subprocess
import time

XCODEBUILD = re.compile(r"^(?:\S*/)?xcodebuild(?:\s|$)")
XCTEST = re.compile(r"^(?:\S*/)?xctest(?:\s|$)")


def stalled(newest, now, silence):
    return newest is not None and now - newest >= silence


def newest_output(paths):
    times = [os.path.getmtime(path) for path in paths if os.path.exists(path)]
    return max(times, default=None)


def parse_processes(output):
    processes = []
    for line in output.splitlines():
        pid, _, args = line.strip().partition(" ")
        if pid.isdigit():
            processes.append((int(pid), args.strip()))
    return processes


def xcodebuild_pids(processes, results):
    # The results folder keeps an unrelated xcodebuild (another checkout) out.
    return [pid for pid, args in processes if XCODEBUILD.match(args) and results in args]


def sample_targets(processes, results, products, own_pid):
    builds = set(xcodebuild_pids(processes, results))
    return [
        (pid, args)
        for pid, args in processes
        if pid != own_pid
        and (pid in builds or XCTEST.match(args) or any(path in args for path in products))
    ]


def list_processes():
    output = subprocess.run(
        ["ps", "-axo", "pid=,args="], capture_output=True, text=True, check=True
    ).stdout
    return parse_processes(output)


def collect(processes, targets, out, log):
    out.mkdir(parents=True, exist_ok=True)
    table = subprocess.run(
        ["ps", "-axo", "pid,ppid,etime,pcpu,state,args"], capture_output=True, text=True
    ).stdout
    (out / "processes.txt").write_text(table)
    for pid, args in targets:
        name = re.sub(r"[^A-Za-z0-9.-]+", "-", Path(args.split(" -")[0]).name)[:40]
        file = out / f"sample-{pid}-{name}.txt"
        command = ["sample", str(pid), "5", "-file", str(file)]
        # The hosted runner allows sudo without a password; a local run may not need it.
        if subprocess.run(command, capture_output=True).returncode != 0:
            result = subprocess.run(["sudo", "-n", *command], capture_output=True, text=True)
            if result.returncode != 0:
                log(f"could not sample {pid} ({args[:80]}): {result.stderr.strip()}")


def interrupt(pids, grace, log):
    for pid in pids:
        try:
            os.kill(pid, signal.SIGINT)
        except ProcessLookupError:
            pass
    deadline = time.time() + grace
    while time.time() < deadline:
        if not any(alive(pid) for pid in pids):
            return
        time.sleep(2)
    for pid in pids:
        if alive(pid):
            log(f"xcodebuild {pid} did not stop after SIGINT; sending SIGKILL")
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--logs", action="append", required=True, help="glob of the test logs")
    parser.add_argument("--results", required=True, help="result bundle folder in xcodebuild's arguments")
    parser.add_argument("--products", action="append", default=[], help="path in the test processes' arguments")
    parser.add_argument("--out", type=Path, required=True, help="folder for the process list and samples")
    parser.add_argument("--silence", type=float, default=600)
    parser.add_argument("--interval", type=float, default=30)
    parser.add_argument("--grace", type=float, default=180)
    options = parser.parse_args()

    def log(message):
        print(f"[watchdog] {message}", flush=True)

    while True:
        time.sleep(options.interval)
        processes = list_processes()
        builds = xcodebuild_pids(processes, options.results)
        if not builds:
            continue
        logs = [path for pattern in options.logs for path in glob.glob(pattern)]
        newest = newest_output(logs)
        if not stalled(newest, time.time(), options.silence):
            continue
        silent = int(time.time() - newest)
        print(
            f"::error title=Test output stopped::No test output for {silent} s. "
            f"Sampled the test processes into {options.out} and interrupted xcodebuild.",
            flush=True,
        )
        targets = sample_targets(processes, options.results, options.products, os.getpid())
        collect(processes, targets, options.out, log)
        log(f"sampled {len(targets)} processes; interrupting xcodebuild {builds}")
        interrupt(builds, options.grace, log)
        return


if __name__ == "__main__":
    main()
