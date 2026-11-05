# 089.005 — S3: New Session

## Context

The 088 launch was a Settings-style form. Its keyboard covered Create (D5), and a long flat
list of workspaces had no grouping. S3 makes starting a session feel like sending a first
message.

## Change

| Area | Change |
| --- | --- |
| Sheet | `MirrorLaunchView` is a medium / large sheet (`AgentsView`) with one glass composer card: the first message (`launch-prompt`, autocorrect off) on top; under it a project menu (`launch-project`) and a Profile menu (`launch-profile`) on their own lines, and a round Start button (`create-and-mirror`) at the corner. A Done key hides the keyboard; Refresh reloads the catalog. |
| Where | The project menu groups the `list` worktrees by `root_path` in the Host's order, with worktrees in a submenu and their paths as subtitles. A launch from a project's `…` menu keeps S1's pane-identity restriction (`MirrorLaunchModel.focusProject(paneIDs:)`). |
| Who | The Profile menu shows the name, the agent with model and effort as the subtitle, and the Profile's SF Symbol. Unavailable Profiles are disabled and show their reason. The last started Profile (`mirror.lastProfileID`) is selected again when it is available. |
| Host and CLI | `ProfilesCommandProfile` gets optional `model`, `reasoning_effort` and `icon`, filled from `AgentProfile` when not blank. `cli-output-schema.json` and `docs-ai/013-prowl-cli/contracts/profiles.md` list them. `MirrorLaunchProfile` decodes them as `model`, `effort` and `icon`. |
| Fixtures | `--mirror-ui-roster-fixture` also serves a launch catalog for its projects (with pane IDs) and three Profiles (one unavailable). |

Tests: `listCarriesModelEffortAndIconWhenSet` (Mac handler, JSON key) and
`profilesCarryModelEffortAndIcon` (iOS decode). The existing launch UI tests keep their
identifiers.

## Decisions

- Menus, not a second screen: a launch takes two choices that usually stay the same, so they
  sit next to the message instead of in a form.
- No sidebar groups in the project menu yet: `list` has no group data, and the Host's order
  already follows the sidebar.

## Refs

#1049
