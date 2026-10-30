# 079.008 — Amp, Antigravity, Devin, Droid, and Grok Build verified

## Context

A survey of the fourteen agents still marked unverified found five current releases that
report OSC 7501 with their own `app`. This amendment repeats the producer flip for them. The
survey and every observation are in [producer-baseline.md](producer-baseline.md).

## Change

| Layer | Files | What |
| --- | --- | --- |
| Support table | `App/Sources/Domain/AgentDetection/ProgramStatusEvidence.swift` | `level(for:)` returns `.verified` for `.amp`, `.antigravity`, `.devin`, `.droid`, `.grok`; `programStatusApp` maps them to `amp`, `antigravity`, `devin`, `droid`, `grok-build` |
| Devin composer | `App/Sources/Infrastructure/AgentDetection/DevinScreenProfile.swift` | the top rule may embed the session title, which Devin 3000.11.234 draws after the first turn |
| Tests | `App/Tests/AgentCoordinatorProgramStatusTests.swift`, `App/Tests/WorktreeTerminalStateProgramStatusTests.swift`, `App/Tests/DevinSupportTests.swift` | table, attribution fence, terminal publication, and title-in-rule cases |
| Docs | `docs/components/agent-detection.md`, `docs/components/terminal.md`, `docs-ai/068-agent-state-providers/architecture.md`, [producer-baseline.md](producer-baseline.md) | producer list and replay tables |

The push path, delegated schedule, settle window, release paths, readiness, and CLI surface are
unchanged. Screen rules stay as the fallback for versions that do not report.

## Decisions

- **No version gate.** As for earlier producers, a report is the only signal. Local older
  versions (Antigravity 1.3.2, Devin 3000.11.3, Droid 0.210.0, Grok Build 0.2.118) sent nothing.
  The first version with support is not known for these five.
- **The Devin fix ships here.** Without it `agents dispatch` refuses every Devin pane after the
  first turn (`DISPATCH_TARGET_BUSY`), and the screen rules miss the idle composer.
- **OpenCode v2 stays unverified.** Prowl supports the v1 line, and v1 has no reports. See the
  baseline for what v2 sends.

## Boundaries

| Boundary | Handling |
| --- | --- |
| Amp reports nothing until the first prompt is entered | `legacy.detector` until then |
| Amp reports a cancelled turn as `done` | Done badge on the cancelled turn; follows the producer |
| Amp `blocked` has no kind | `osc.blocked.unspecified` |
| Antigravity `blocked:kind=auth` for about 0.03 s at launch | not visible in the 250 ms poll; `idle` replaces it |
| Grok Build child records | the root decides; a child `blocked` would make the pane Blocked (not replayed) |
| Grok Build and Amp `/new` | the session stays the old id, the same as the control build |
| Devin `/exit` and `kill -9` | released by misses in 1.7–3.0 s, not by the command-finished path; cause not investigated |
| `msg` | not logged or published; Antigravity puts reply text there |

## Verification

`make measure-cpu`, one run each, 20 s, the same five agents idle in background tabs:

| Build | Process mean | `detectAgentState` |
| --- | --- | --- |
| 079.008 (four under OSC, Amp on the screen until its first report) | 3.3 % | 2.23 % of a core |
| Control (the table before this change, otherwise the same) | 4.4 % | 3.85 % of a core |

Other gates are listed in the PR. Red run: the five new table cases and
`defaultTableVerifiesKnownProducers()` failed before the source change.

## Refs

Survey and replay tables: [producer-baseline.md](producer-baseline.md). Previous flip:
[007-codex-verified.md](007-codex-verified.md).
