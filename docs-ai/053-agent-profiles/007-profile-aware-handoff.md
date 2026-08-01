# 053.007 — Profile-aware handoff

| | |
| --- | --- |
| **Date** | 2026-08-01 |
| **Status** | Implemented (see [053.008](008-profile-aware-handoff-action.md)) |
| **Primary PRs** | [#651](https://github.com/onevcat/Prowl/pull/651) |
| **Related** | [053 plan](000-plan.md), [053.006](006-launch-scoped-environment.md), [047.004](../047-cross-agent-handoff/004-inline-handoff-redesign.md), [047.005](../047-cross-agent-handoff/005-hud-request-ownership.md), [049 Agents HUD](../049-agents-toolbar-entry/000-plan.md), [048 runtime adapters](../048-agent-runtime-adapters/000-plan.md), [handoff manual](../../docs/components/handoff.md) |

## Context

Hand Off currently identifies a receiver only by runtime token. The CLI handler rebuilds an inherited
`AgentLaunchConfiguration`, while HUD fallback separately renders an invocation and creates a tab.
Both routes therefore lose a Prowl Agent Profile's effort, Extra Arguments, launch-scoped environment,
Dedicated Home, account, and surface identity.

This follow-up closes the seam reserved by 053 without changing the `AgentProfile` persistence schema.
A native Codex Config Profile remains ordinary Extra Arguments such as `-p work`.

## Scope

- Let HUD and CLI select an enabled Prowl Agent Profile by stable UUID.
- Keep Runtime Default Claude Code/Codex targets and their current inheritance behavior.
- Make inline CLI and HUD fallback use the same complete Profile launch path.
- Keep preflight, artifact, launch-memory, background/focus, and privacy boundaries explicit.

Non-goals: a Codex-specific field; outgoing Profile/Home/environment propagation into source
resume/fork; more runtimes; Profile import/export; automatic HUD timeout; receiver process-health
checks; or honoring a Receiving Profile's manual-launch `Open In` placement.

## Alternatives & decisions

| Area | Decision |
| --- | --- |
| Receiver identity | `HandoffReceivingTarget` is either `.runtimeDefault(DetectedAgent)` or `.profile(AgentProfile.ID)`. Names are presentation only. |
| HUD order | Recommended Profile first and selected by default, remaining enabled Profiles in Settings order, Runtime Defaults, then Brief Only. No enabled Profiles preserves today's list. |
| Native Codex profile | Keep `-p <name>` in Prowl Profile Extra Arguments; do not add a Codex-only field. |
| CLI grammar | Accept exactly one of runtime positional or `--agent-profile-id <UUID>`. Runtime keeps optional positional source; Profile rejects positional source but may use `--pane`/`--tab`/`--worktree`. No selector still means caller pane. |
| Resolution | Bind UUID in the request; after briefing collection, resolve the latest persisted enabled Profile and freeze it before artifact commit. Missing, disabled, or unplannable fails before artifact mutation. |
| Launch authority | Receiving Profile exclusively supplies model, effort, execution mode, Extra Arguments, environment, Dedicated Home, account, and identity. Runtime Default alone retains source model/unrestricted inheritance. |
| Placement | Handoff always creates a new background tab and ignores Profile `Open In`. Only a still-waiting HUD focuses the exact returned pane after success. |
| `--no-launch` | Resolve and record an enabled Profile, but do not plan/provision a launch, create a surface, or update Last Launched Profile. |
| Request ownership | Bind HUD request UUID to source pane plus checkpoint/runtime/Profile operation with launch enabled. Mismatch returns `INVALID_ARGUMENT` before briefing/artifacts and leaves the request pending for correction; fallback atomically supersedes it. |
| Completion | Keep `HandoffCLICompletion` and `launched` optional. Add optional Profile identity plus `failureMessage` and `artifactsReady`; after a matching claim, publish exactly one terminal completion. |
| Output | Add optional `to_profile_id` and frozen `to_profile_name` while keeping `to_agent` as resolved runtime in `prowl.cli.handoff.v2`. Sanitize the name to one log line; archive filenames remain runtime-based. |
| Privacy | Never place Extra Arguments, environment, carrier values, home paths, or credentials in requests, payloads, artifacts, or logs. |

## Execution design

```text
claim matching HUD request, if any
→ collect/validate briefing without artifact writes
→ resolve enabled Profile and compile prompted launch plan
→ commit transition artifacts
→ launch through the shared Profile terminal boundary
→ log and publish response/completion
```

- Add `intent: AgentStartIntent = .interactive` to `AgentProfileLaunchPlanner.plan`; handoff passes
  `.prompt(kickoffPrompt)`, so adapters remain the sole argv ordering and quoting authority.
- Add a handoff-background context and a result containing exact tab/surface identity to the existing
  Profile launcher. `WorktreeTerminalState` and `WorktreeTerminalManager` remain synchronous on
  `@MainActor`; `TerminalClient` exposes that result-returning closure for CLI and fallback.
- `WorktreeTerminalManager` remains the sole Profile executor and emits existing success/failure events.
  Only surface success updates Last Launched Profile through `AppFeature+TerminalEvents`.
- Build `HandoffLaunchedPane` directly from the launch result; do not create a surface and then perform
  a fallible `TargetResolver` lookup.

| Failure point | Outcome |
| --- | --- |
| Invalid target, invalid briefing, missing/disabled Profile, or plan failure | Fail before artifact mutation; no launch-memory update |
| Artifact commit failure | Error and no receiver launch; do not claim a complete artifact set |
| Dedicated Home or surface failure after commit | Retain artifacts/archive, log `launch=failed`, report progress saved but receiver not launched, no launch-memory update |
| Surface created | Record exact pane, notify, and emit Profile launch success |

## Implementation slices

1. CLI/wire: `ProwlCLI/Commands/HandoffCommand.swift`, `ProwlCLI/Output/OutputRenderer.swift`,
   `supacode/CLIService/Shared/InputModels.swift`, and
   `supacode/CLIService/Shared/HandoffCommandPayload.swift`.
2. Request/HUD: `supacode/Domain/Handoff/HandoffRequestRegistry.swift`,
   `supacode/Clients/Handoff/HandoffRequestClient.swift`,
   `supacode/Domain/Handoff/HandoffInjection.swift`,
   `supacode/Features/HandoffHud/Reducer/HandoffHudFeature.swift`, and
   `supacode/Features/App/Reducer/AppFeature+Handoff.swift`. Registry claim results are only
   `claimed`, `mismatch`, and `unavailable`.
3. Handler/logging: `supacode/CLIService/HandoffCommandHandler.swift` and
   `supacode/Domain/Handoff/HandoffCoordinator.swift`.
4. Shared launch: `supacode/Domain/AgentProfile/AgentProfileLaunchPlan.swift`,
   `supacode/Clients/Terminal/TerminalClient.swift`,
   `supacode/Features/Terminal/Models/WorktreeTerminalState.swift`,
   `supacode/Features/Terminal/BusinessLogic/WorktreeTerminalManager.swift`, and
   `supacode/App/supacodeApp.swift`.
5. After implementation, update `docs/components/handoff.md`, `docs/components/cli.md`,
   `docs/components/agent-profiles.md`, and `skills/prowl-cli/SKILL.md`, then record actual results in
   the next 053 amendment.

## Verification

- Parser/socket: Profile/runtime exclusivity, malformed UUID, source selectors, additive payload/text,
  `--no-launch`, and runtime compatibility.
- Registry/handler: exact claim, retryable mismatch, supersession, latest Profile resolution,
  authoritative Profile versus Runtime Default inheritance, zero-side-effect preflight, sanitized
  no-secret output, and post-commit launch failure.
- Planner/terminal/HUD: prompted `-p work` plan retains environment/Home; handoff ignores split and
  stays background; manager emits one result event; inline and fallback correlate/focus the exact pane.
- Run focused Xcode suites, `swift test --filter HandoffCommandParsingTests`, `make build-cli`,
  `make test-cli-smoke`, `make test-cli-integration`, `make check`, `make test`, and `make build-app`.
- Manually exercise inline and fallback with a Codex Profile using `-p work`, environment overrides,
  and Dedicated Home; also cover deleted/disabled Profile, launch failure, Runtime Default, and secret
  absence from preview, JSON, artifacts, and logs.
