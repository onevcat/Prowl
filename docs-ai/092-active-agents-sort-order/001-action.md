# 092 — Active Agents sort order: Action Log

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-11-15 | Plan written after #1089 triage; onevcat chose a three-value picker over a toggle | `000-plan.md` |
| 2026-11-15 | Sort order setting, ordering function, project sections in the panel, navigation and island roster in display order | this entry's PR |

## Outcome & current state (as of 2026-11-15)

- `ActiveAgentsSortOrder` (`startTime`, `project`, `status`) and the pure ordering function
  `ActiveAgentsOrdering.sections(entries:sortOrder:projectIDs:projectOrder:)` are in
  `App/Sources/Features/ActiveAgents/Models/ActiveAgentsSortOrder.swift`.
- `ActiveAgentsFeature.State` holds `sortOrder`, `projectIDsByEntryID` and `projectOrder`, and
  derives `sections` and `orderedEntries`. Next/previous navigation and every Agent Island
  roster action (`start`, `reconcile`, `moveSelection`, `movePage`, `visibleEntryID`) use
  `orderedEntries`.
- `RepositoriesFeature` keeps the project inputs current with
  `.onChange(of: \.activeAgentOrderInputs)`
  (`App/Sources/Features/Repositories/Reducer/RepositoriesFeature+ActiveAgentOrder.swift`). The
  inputs are `nil` outside the `project` order, so agent updates cost nothing there.
  `activeAgentProjectIDs(entries:repositories:)` resolves the project the same way as
  `SidebarListView.activeAgentRowDisplay`: working directory first, owning worktree only
  without a directory.
- `AppFeature` sets `sortOrder` outside `RepositoriesFeature`, so it calls
  `refreshActiveAgentOrder()` itself when the setting changes.
- `GlobalSettings.activeAgentsSortOrder` decodes an unknown value as `startTime`. The picker is
  in `AgentDisplaySettingsView.swift`.
- `ActiveAgentsPanel.swift` renders a caption title per project section (name and color from the
  section's first row, **Other** for the rest) and indents its rows; `ActiveAgentRow` gained
  `showsRepositoryName`, and moves the subtitle up when both names are hidden.
- `prowl agents`, the island attention cells and the iOS mirror are unchanged.

## Deviations from plan

None known. The plan left open whether the parent sends the order with each navigation request
or keeps it in the child state; the child state won, because the island roster also needs the
order when an entry changes.

## Open questions

- The project resolution runs in the reducer through `WorktreeDirectoryIndexCache`, the same memo
  the panel view uses. Its cost with many agents in `project` order was not measured.
