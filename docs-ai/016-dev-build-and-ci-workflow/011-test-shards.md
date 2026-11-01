# 016.011 — Test Shards

## Context

After [010](010-stable-incremental-state.md), the main test pass took 133 s or more in CI. Most
test suites run on the main actor, and the TCA main-serial executor also moves detached tasks
to the main thread. One test process is therefore almost serial, and more cores do not help:
a serial local run took 164 s and a parallel run took about 105 s.

Each test process has its own main thread. The limit moves when the tests run in more than one
process.

## Change

- `make test-app` runs `build-for-testing` once, and then runs `test-without-building` in
  `PROWL_TEST_SHARDS` processes at the same time. The default is 2/3 of the cores, from 2 to 8.
  CI uses 3.
- `xcodebuild -enumerate-tests` (about 5 s) gives the test list. A new suite therefore runs with
  no manual step.
- `scripts/test-shards.py` assigns suites to shards, longest first, with costs from
  `scripts/test-suite-costs.json`. A suite that is not in that file costs 0.01 s per test.
  A stale file makes the shards uneven. It cannot make a test not run.
- Each shard asserts its own test count, so a shard that matches no tests fails.
- The event-monitor, mirror and process-cancellation passes stay separate and sequential.

## Measurements

Local bulk pass, 4694 tests, M2 Pro with 12 cores:

| Shards | 1 | 2 | 3 | 4 | 6 | 8 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Seconds | 126 | 70 | 65 | 57 | 54 | 39 |

`make test-app` with no source change went from 165 s to 92 s locally. In CI, three attempts
with no source change took 458, 370 and 323 s for the `build` job, and each shard took about
95 to 108 s.

## Open questions

Stress runs on one Mac, with the CLI tests and the checks at the same time, found failures that
sharding does not explain:

- With 8 shards and a load average of 14 to 39, 3 of 8 rounds failed in
  `MirrorTerminalIntegrationTests` with `Timed out: mirrored READY`. The replica's text had
  `READY`, but its VT snapshot did not have the row. The cursor stayed at the end of that text.
  The failure has the same form each time, so it is not only a slow run. It looks like a replica
  that has an incorrect screen until the next frame. The cause is not confirmed.
- With 1 shard, 2 of 8 rounds failed: one `RemoteLauncherTests` timeout, and one crash in
  `ghostty_app_tick`. A queued wakeup used the pointer of a test `GhosttyRuntime` that was
  already released.

## Refs

PR #1022.
