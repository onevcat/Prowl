# 053.008 — Profile-aware handoff implementation

| | |
| --- | --- |
| **Date** | 2026-08-01 |
| **Status** | Implemented |
| **Primary PRs** | [#651](https://github.com/onevcat/Prowl/pull/651) |
| **Design** | [053.007](007-profile-aware-handoff.md) |

## Result

Hand Off now accepts either a Runtime Default receiver or an enabled Prowl Agent Profile. The HUD
orders the recommended and remaining enabled Profiles before Runtime Defaults, injects only the
Profile UUID and exact source pane, and correlates completion back to the exact launched surface.
The direct CLI form is:

```bash
prowl handoff to --agent-profile-id <uuid> --brief -
```

Native Codex config profiles remain ordinary Profile Extra Arguments such as `-p work`; no
Codex-specific persistence field was added.

## Implementation

- `HandoffReceivingTarget` and the HUD request registry bind one request UUID to the exact source
  pane plus checkpoint, Runtime Default, or Profile operation. A mismatch stays pending; a claimed
  or superseded UUID cannot be reopened.
- The CLI and socket payload accept `to_profile_id`; successful output adds frozen
  `to_profile_id` / `to_profile_name` while retaining `to_agent` as the resolved runtime.
- Profile resolution intentionally happens after briefing collection. The latest enabled Profile is
  frozen into a prompted `AgentProfileLaunchPlan` before artifact commit. Runtime Default alone keeps
  the previous portable source-configuration inheritance.
- `WorktreeTerminalState` is the shared Profile executor for manual and handoff launches. Handoff
  context forces a background tab at the source root, ignores Profile split placement, and returns
  the exact tab/surface identity. Surface success remains the only path that updates launch memory.
- Inline CLI completion and HUD fallback both report the frozen Profile identity. A waiting HUD
  focuses the exact receiver; a later Profile rename is reflected from completion rather than stale
  chooser state.

## Failure and privacy boundaries

- Invalid requests, invalid briefing, missing/disabled Profiles, and launch-plan failures stop before
  artifact mutation. `--no-launch` resolves identity but does not plan, provision, launch, or update
  launch memory.
- A Dedicated Home or surface failure after artifact commit retains the saved progress, records
  `launch=failed`, and reports that the receiver was not launched.
- Requests, payloads, artifacts, and transition logs never contain Extra Arguments, environment
  values, carrier values, home paths, or credentials. Logs contain only sanitized Profile name/UUID
  and resolved runtime metadata.

## Verification

- `make check`: passed.
- Focused Xcode suites for handler, HUD, request ownership, app wiring, planner, terminal state, and
  terminal manager: passed.
- `swift test --filter HandoffCommandParsingTests`: 14 passed.
- `make build-cli`, `make test-cli-smoke`, `make test-cli-integration`: passed; integration suite 68
  passed.
- `make test`: 2,173 passed, 0 failed.
- `make build-app`: passed with 0 errors and 0 warnings.

The repository's real-GUI `self-verify-prowl` workflow was not run because that skill is explicitly
opt-in and this implementation request did not separately authorize it.
