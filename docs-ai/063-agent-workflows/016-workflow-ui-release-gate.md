# 063.016 — Workflow UI Release Gate

Status: implemented and verified; release preparation, 2026-09-05.

The owner approved shipping the merged Agent Island, detection fixes, and other changes
before action bundles, handoff migration, or adversarial review are ready. Hide workflow UI
by default for this release; retain the existing CLI, engine, bundled resources, and skill
installation capability. #770 and #771 are merged; the action proposal is documentation only.

Introduce a small process-environment `FeatureFlags` dependency. `PROWL_WORKFLOW_UI=1` opts
into workflow UI; missing, empty, and other values leave it off. Read once per process;
there is no persistent setting or runtime toggle. Tests can inject both configurations.

Hide the Agents popover workflow section, workflow status control, Active Agents/Island
workflow menus and role labels, command-palette launch rows, global/repository Workflow
Settings, authoring UI, workflow start overlays, and the bundled workflow skill's Settings
row. Guard GUI navigation entry points as well as presentation. Keep agent profiles,
legacy handoff, Island behavior, CLI & Skills, and non-workflow skill rows available.
Runtime status remains queryable through CLI; suppress workflow-specific UI notices while
hidden, without suppressing the engine's explicit workflow steps or CLI behavior.

Verify default and opted-in presentation in Debug, focused flag/navigation tests, existing
workflow UI/reducer tests, strict formatting/lint, and build. Release checklist must confirm
the default-off UI and CLI reachability; future workflow/action acceptance is not a gate for
this maintenance release. Do not publish a release as part of this implementation PR.

## Implementation and verification

`FeatureFlags` is a process-scoped, injectable dependency shared by views and reducers.
The release default is off; existing workflow tests explicitly use the dependency's enabled
test default, while release-gate tests inject the disabled configuration. GUI admission,
catalog presentation, role badges, and automatic UI notices are gated. CLI admission and
explicit workflow steps remain independent of UI visibility.

- Focused flag, Settings, workflow notice, role badge, runtime harness, and toolbar suites:
  52 tests passed. The new tests cover exact opt-in parsing, hidden Settings selection,
  skill filtering, and blocked GUI navigation/notices with a valid selected worktree.
- `make check`: passed, including 131 script tests and strict Swift formatting/lint.
- `make build-app`: passed without warnings; release skill metadata validation also passed.
- Live Debug checks with an isolated socket and a temporary repository: Agents workflow
  rows, global/repository Settings, workflow skill, and command-palette rows were absent
  without the variable and present after relaunch with `PROWL_WORKFLOW_UI=1`. The Agents
  popover was visually inspected in both configurations; ordinary profile controls remained.
- With the variable absent, CLI catalog listing succeeded, a local notification-only
  workflow reached `completed`, and `skills list` still exposed `prowl-workflow`. No model
  calls or credential/configuration changes were required.

This is targeted pre-PR validation, not the release-time contract sweep or notarization.
Those remain required by the release runbook when publishing the candidate.
