# 016.009 — Test Hang Watchdog

## Context

In run 37164745593 (#851), the `build` job finished the App build with 93% compilation cache
hits, then the first `make test-app` pass printed nothing for 39 minutes until the 45-minute
job timeout cancelled it. The same code had passed one hour earlier. The run kept no evidence
of the hung test:

- xcodebuild sends test results in bursts, so a hang shows no test lines at all.
  `NSUnbufferedIO=YES` does not change this: in a local comparison, the result lines arrived
  at the same times with and without it.
- The xcresult upload ran only on `failure()`, and a job that reaches its timeout is
  cancelled.
- Nothing sampled the processes while they hung.

## Change

- `scripts/ci-test-watchdog.py` runs beside the tasks in the `build` job. When an xcodebuild
  that writes to `build/test-results/` runs and no `build/test-results/*.xcresult.log` has
  changed for 10 minutes, it:
  1. Prints a GitHub error annotation.
  2. Writes the process table and a 5-second `sample` of xcodebuild, `xctest` and every
     process started from `$PROWL_DERIVED_DATA_PATH/Build/Products` (the test host) to
     `build/ci-logs/hang/` (it uses `sudo -n` when `sample` alone fails).
  3. Sends SIGINT to xcodebuild, and SIGKILL if it has not stopped after 3 minutes.
- An interrupted xcodebuild prints `** TEST INTERRUPTED **` and still writes the result
  bundle. The bundle marks the running test as failed with "Testing was canceled", and
  `print-xcresult-failures.sh` prints that test. `make test-app` stops at that pass, so the
  step fails about 10 minutes after the last output, not at the job timeout.
- The xcresult upload also runs when the job is cancelled. The step summary says when the
  watchdog stopped the run.

10 minutes is far above the normal gaps: the build prints continuously, and the gaps in
test output are about 2 minutes on a slow runner.

## Verification (local, iOS 27 simulator)

A temporary test with `while true { sleep(1) }`, run under the watchdog with a 30-second
limit: the watchdog sampled xcodebuild and the test host, whose stack contains
`WatchdogHangProbeTests.testHangs()`. xcodebuild stopped about 30 seconds after SIGINT, and
the result bundle reported `WatchdogHangProbeTests/testHangs()` with "Testing was canceled".

## Refs

PR #851 (the hang), this change.
