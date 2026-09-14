# 068 — Agent State Providers: Action Log

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-09-14 | Record shared architecture, released provider, and interactive runtime spike | #806 |
| 2026-09-15 | Extend the native contract spike and implement process-scoped snapshots | #808, `5e66c6c2` |
| 2026-09-15 | Preserve fresh blockers across native Busy transitions | #808, `467c12d5` |
| 2026-09-15 | Verify standard mouse-wheel scrollback; exclude separate fullscreen acceptance at onevcat's request | #808 |

## Outcome and current state

Implementation and required acceptance are complete; #808 awaits merge and release.
`ClaudeRuntimeProvider` and `ClaudeRuntimeDecoder` acquire bounded process registry
snapshots. `AgentNativeSnapshot` carries validated private evidence into
`AgentStateMachine`; `AgentDetectionCoordinator` preserves generation, root, and
capture ordering. Outstanding native work also constrains wait, dispatch, and
workflow readiness. Native Idle remains heuristic and cannot create a success receipt.

The [shared architecture](architecture.md), [Codex contract](codex.md), and
[Claude contract](claude.md) are the living references for later providers.
The [implementation record](002-native-runtime-implementation.md) contains the
case matrix, evidence limits, and validation results: 92 selected app tests,
CLI suites, 25 native E2E trace assertions, and standard terminal wheel acceptance.
The final documentation follow-up retains the same runtime implementation.

## Deviations from plan

The extended spike showed native status already aggregates assigned children and
background shell work. Production JSONL reconstruction was removed to avoid a
second work ledger and preserve per-process ownership of a shared session.

Desktop access initially failed, then recovered. Standard terminal scrollback
passed on runtime 2.1.271. Automated scrolling did not move the fullscreen viewer;
onevcat explicitly excluded that separate case from acceptance. It is unverified,
not a passing test or proof of equivalence.

## Open questions

Older runtimes, daemon/remote kinds, and shell-only custom roots outside a launch
profile have no additional support claim. A requested foreground child was
backgrounded by the runtime, so synchronous child execution was not independently
established. These limits remain documented in the living runtime contract.
