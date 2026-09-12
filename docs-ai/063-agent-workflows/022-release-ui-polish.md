# 063.022 — Workflow UI Release Polish

| | |
| --- | --- |
| **Status** | Implemented; automated verification and scoped live Debug UI checks passed |
| **Anchor date** | 2026-09-11 |
| **Related** | [start sheet](011-c2-start-sheet.md), [status center](010-c1-workflow-status-center.md), [history storage](018-history-storage-plan.md), [step history UI](021-step-history-ui.md), [release gate](016-workflow-ui-release-gate.md) |

## Context

The last pass over the workflow UI before it ships by default. The owner's review of the
opted-in build found seven rough edges: the Settings Run button named only a branch; the
detail's run targets froze when the main window changed selection; the start sheet still
used the pre-history "You / Receiver / next" layout with inert skip rows; a finished run
vanished from the toolbar the moment it ended; the Settings Execution History sheet
duplicated the toolbar's Workflow History with a budget readout nobody needed; runs were
retained for 30 days with a Keep Run pin; and "New Workflow…" wrote an unnamed
two-role starter without asking anything.

## Decisions

1. **Run target reads `repository · worktree`** everywhere the detail names a target
   (button, menu, tooltip). The detail sends `.appeared` on `.task` and whenever the
   Settings window becomes key; the parent re-reads run targets from the live snapshot and
   synchronizes the pushed detail. The button's target and the run's target were already
   the same explicit worktree id (`runTapped(worktreeID:)` → `openWorkflowStart`), so the
   refresh is a courtesy, not a correctness fix.
2. **The start sheet explains before it asks.** A pure `WorkflowStartPlan` derives, from
   the definition alone, each role's kind (`This pane` / `New agent` / `Existing agent`),
   the numbered steps that address it, and its launch placement, plus the ordered step list
   with `if`/`while` context. The card is arranged like the history panel: header with
   icon and worktree, then **Roles** (one row per role with its picker on the right),
   **Options** (inputs labeled by `prompt`, enum inputs as menus), **Steps**, and
   **Optional Steps**. A launch role the current inputs never reach is listed dimmed as
   *Not started with the current options* and takes no picker. Skips that would end the
   run are not offered at all (`visibleSkipOptions`); admission refuses them anyway.
   "Don't ask again" moved to the footer.
3. **A finished run lingers in the status item for eight seconds.** `WorkflowRunsFeature`
   records `recentlyFinishedRunIDs` on every non-terminal → terminal transition and clears
   each id after `finishedNoticeDuration` on the injected continuous clock.
   `WorkflowStatusCenterPresentation` lists active runs first, then held finished ones;
   `WorkflowRunPresentation.Status.finished(outcome)` and `summaryText` give the item its
   checkmark and "<workflow> completed" line. Hovering opens the same history panel with
   that run selected, which already holds terminal runs. The completion/skipped/limit
   toasts in `AppFeature` were removed because a toast outranks the workflow item in
   `ToolbarStatusSelection` and would have covered it; notifications are unchanged.
4. **Settings history is a summary, not a browser.** The Execution History sheet,
   `WorkflowHistoryView`, and the 5 GiB readout are gone. Settings › Workflows shows
   **Run History** with `<n> runs · <size> on disk` and **Clear History…** (confirmed),
   which removes every finished run that is not in use, ignoring the diagnostic grace.
   Inspecting runs is the toolbar's Workflow History only.
5. **Retention is three days and not a setting.** `WorkflowHistoryPreview.retention` is
   `3 * 86400`; the 24-hour grace and the soft budget stay. Keep Run is removed end to end
   (`keep.json` is no longer read or written; a stale marker is ignored). The run's More
   menu is now **Export…** and **Delete Run…** (confirmed; finished runs only).
   `WorkflowHistoryEntry.removable` separates "an explicit delete may remove it" from
   `protection`, which still describes automatic cleanup. `WorkflowHistory.delete` and
   `clear` hold coordination and occupancy like `cleanup` and reuse its failed-unit marker.
   The step-history reducer drops a deleted run from entries, live runs, and directories,
   adds it to `removedIDs` so a later `liveRuns` refresh cannot resurrect it, and selects
   the next entry.
6. **New Workflow asks first.** `NewWorkflowSheet` collects a name, an id (suggested from
   the name via `WorkflowStarterTemplate.suggestedID`, editable, refused when it is not a
   schema slug, reserved `prowl.*`, or already used on that page), an optional SF Symbol
   through the shared `TabIconPickerView`, and a starter kind. **Single agent** asks the
   current agent for today's date (one `current` role, an enum input, a `text` delivery);
   **Multi-agent** plays rock-paper-scissors (`current` picks a verdict move, a launched
   `challenger` answers with the winning one). Both templates are validated by tests and
   carry comments that explain each field and name the bundled manual and skill paths on
   disk (`WorkflowStarterTemplate.Documentation`, resolved from the app bundle in the
   composition). "Ask an Agent…" became **Create with Agent…**, offered on the index and
   inside the form (the prompt sheet nests under the form so no two root sheets compete).

## Verification

- `make check` passed (format, strict lint, 153 script tests).
- `make build-app` passed.
- CLI: `WorkflowHistoryRetentionTests` (11 tests: three-day expiry, occupancy recheck,
  explicit delete ignoring grace but not live/occupied runs, clear keeping live runs);
  `make test-cli-unit`, smoke, and integration — see the PR for the final run.
- App: the workflow reducer/model suites (history summary and clear, step-history delete,
  status-center hold and ordering, runs-feature hold/expiry on a `TestClock`, notice tests
  without toasts, start plan, start-sheet skip visibility and unreached roles, starter
  templates, settings draft validation and run-target refresh) — 150 tests passed; the
  full `make test` result is recorded in the PR.
- The September 12 follow-up checked the current Debug app in Normal, Shelf, and Canvas,
  including a constrained window. Creation, Settings detail, required enum selection,
  missing-profile guidance, completed status, and history step/output inspection were exercised.
  Two deterministic built-in-action runs completed. This does not replace live multi-agent
  inference or script-approval acceptance; those paths were not changed in this follow-up.


## September 12: First-use follow-up

- The Agents popover includes **Manage Workflows…** whenever workflow UI is enabled,
  including when its workflow list is empty. It uses the existing Settings navigation path.
- The creation form shows the actual date or rock-paper-scissors example and explains that
  Create opens the YAML editor. An untouched form shows a neutral path placeholder.
- User-provided names, IDs, and icons are quoted as YAML strings. Punctuation, numeric names,
  non-English text, quotes, backslashes, and line breaks cannot change the document structure.
- **Create with Agent…** includes a valid draft, with localized instructions to retain its
  identity and replace the example steps after asking about the user's task.
- Required enum inputs show **Choose…** until selected. Workflows without roles do not show
  an empty Roles section. Missing profiles point to role requirements and profile Settings.
- The run-options menu has an explicit accessibility label.

Validation: 76 focused app tests passed, including observed failing-to-passing regressions
for YAML generation, Settings routing, and draft prompts. `make check` and `make build-app`
passed. A workflow named `UI Review: #2` was created through the form and validated with the
CLI without losing its name. Temporary bundles and completed test runs were archived outside
the workflow catalog after verification.
