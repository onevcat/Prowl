import ComposableArchitecture
import Foundation
import IdentifiedCollections
import Sharing

@Reducer
struct ActiveAgentsFeature {
  static let minimumPanelHeight = 120.0
  static let maximumPanelHeight = 560.0
  static let reservedSidebarListHeight = 200.0

  /// Direction for keyboard navigation across the agent list.
  enum NavigationDirection: Equatable {
    case next
    case previous
  }

  @ObservableState
  struct State: Equatable {
    var entries: IdentifiedArrayOf<ActiveAgentEntry> = []
    /// Surface that currently has terminal focus, mirrored from `focusChanged` events.
    /// Used as the anchor for keyboard list navigation; not persisted.
    var focusedSurfaceID: UUID?
    var isIslandEnabled = false
    var isIslandRosterExpanded = false
    var islandNavigation = AgentIslandNavigation()
    /// Global shortcut bindings that macOS refused to register, keyed by command ID.
    var islandHotKeyRegistrationFailures: [String: Keybinding] = [:]
    @Shared(.appStorage("activeAgentsPanelHidden")) var isPanelHidden: Bool = false
    @Shared(.appStorage("activeAgentsPanelHeight")) var panelHeight: Double = 200
    /// Mirrored from `GlobalSettings.activeAgentsSortOrder` (docs-ai 092).
    var sortOrder: ActiveAgentsSortOrder = .startTime
    /// The project of each entry and the project order, kept current by `RepositoriesFeature`
    /// while `sortOrder` is `.project`; empty otherwise. This feature cannot see the sidebar
    /// layout or resolve a working directory to a repository by itself.
    var projectIDsByEntryID: [ActiveAgentEntry.ID: Repository.ID] = [:]
    var projectOrder: [Repository.ID] = []

    /// The rows of the panel, in display order.
    var sections: [ActiveAgentSection] {
      ActiveAgentsOrdering.sections(
        entries: entries,
        sortOrder: sortOrder,
        projectIDs: projectIDsByEntryID,
        projectOrder: projectOrder
      )
    }

    /// `entries` in display order. Keyboard navigation and the Agent Island roster use it, so
    /// they step through the rows in the order the panel shows them.
    var orderedEntries: IdentifiedArrayOf<ActiveAgentEntry> {
      sortOrder == .startTime
        ? entries
        : ActiveAgentsOrdering.orderedEntries(entries: entries, sections: sections)
    }
  }

  enum Action: Equatable {
    case agentEntryChanged(ActiveAgentEntry, autoShowPanel: Bool)
    case agentEntryRemoved(ActiveAgentEntry.ID)
    case entryTapped(ActiveAgentEntry.ID)
    /// Context-menu "Run Workflow ▸": parents select the entry (Repositories) and open the
    /// start sheet with this entry's pane fixed as the source (App, docs-ai 063 C2).
    case runWorkflowTapped(ActiveAgentEntry.ID, workflowKey: String)
    /// Context-menu "Mark as Read": handled by RepositoriesFeature.
    case markAsReadTapped(ActiveAgentEntry.ID)
    case focusedSurfaceChanged(UUID?)
    case islandEnabledChanged(Bool)
    case islandToggleRoster
    case islandCollapseRoster
    case islandMoveSelection(NavigationDirection)
    case islandMovePage(NavigationDirection)
    case islandActivateSelection
    case islandActivateVisibleEntry(Int)
    case setIslandHotKeyRegistrationFailure(commandID: String, binding: Keybinding?)
    /// A sidebar action raised from the island roster or attention cells. The reducer forwards
    /// the wrapped action unchanged; when it presents Prowl UI (`surfacesProwl`) the roster
    /// collapses first and `AppFeature` surfaces the main window before the action runs.
    indirect case island(Action)
    case islandToggleEnabledTapped
    case islandSettingsTapped
    case islandOpenProwlTapped
    case selectNextEntry
    case selectPreviousEntry
    case togglePanelVisibility
    case panelHeightChanged(Double)
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .agentEntryChanged(let entry, let autoShowPanel):
        state.entries[id: entry.id] = entry
        if state.isIslandRosterExpanded {
          state.islandNavigation.reconcile(entries: state.orderedEntries)
        }
        if autoShowPanel, state.isPanelHidden {
          state.$isPanelHidden.withLock { $0 = false }
        }
        return .none

      case .agentEntryRemoved(let id):
        state.entries.remove(id: id)
        if state.entries.isEmpty {
          state.isIslandRosterExpanded = false
          state.islandNavigation = .init()
        } else if state.isIslandRosterExpanded {
          state.islandNavigation.reconcile(entries: state.orderedEntries)
        }
        return .none

      case .entryTapped(let id), .runWorkflowTapped(let id, _):
        // Mirror the tapped surface into the focus anchor so the panel highlight and
        // keyboard navigation step from the just-selected agent immediately. The async
        // `focusChanged` event can't be relied on here: it is deduplicated per worktree
        // (`emitFocusChangedIfNeeded`), so re-focusing a worktree's previously focused
        // surface emits nothing and would leave the anchor stale.
        state.focusedSurfaceID = state.entries[id: id]?.surfaceID
        return .none

      case .island(let action):
        if action.surfacesProwl {
          state.isIslandRosterExpanded = false
          state.islandNavigation = .init()
        }
        return .send(action)

      case .markAsReadTapped, .islandToggleEnabledTapped:
        return .none

      case .focusedSurfaceChanged(let surfaceID):
        state.focusedSurfaceID = surfaceID
        return .none

      case .islandEnabledChanged(let isEnabled):
        state.isIslandEnabled = isEnabled
        if !isEnabled {
          state.isIslandRosterExpanded = false
          state.islandNavigation = .init()
          // The visibility shortcut stays registered while the island is hidden.
          state.islandHotKeyRegistrationFailures[AppShortcuts.CommandID.toggleAgentIsland] = nil
        }
        return .none

      case .islandToggleRoster:
        if state.isIslandRosterExpanded {
          state.isIslandRosterExpanded = false
          state.islandNavigation = .init()
        } else {
          state.isIslandRosterExpanded = true
          state.islandNavigation.start(
            entries: state.orderedEntries,
            preferredEntryID: state.islandAttentionEntries.first?.id,
            preferredSurfaceID: state.focusedSurfaceID
          )
        }
        return .none

      case .islandCollapseRoster, .islandOpenProwlTapped, .islandSettingsTapped:
        state.isIslandRosterExpanded = false
        state.islandNavigation = .init()
        return .none

      case .islandMoveSelection(let direction):
        guard state.isIslandRosterExpanded else { return .none }
        state.islandNavigation.moveSelection(direction, entries: state.orderedEntries)
        return .none

      case .islandMovePage(let direction):
        guard state.isIslandRosterExpanded else { return .none }
        state.islandNavigation.movePage(direction, entries: state.orderedEntries)
        return .none

      case .islandActivateSelection:
        guard state.isIslandRosterExpanded, let id = state.islandNavigation.selectedEntryID else {
          return .none
        }
        return .send(.island(.entryTapped(id)))

      case .islandActivateVisibleEntry(let index):
        guard state.isIslandRosterExpanded,
          let id = state.islandNavigation.visibleEntryID(at: index, entries: state.orderedEntries)
        else {
          return .none
        }
        return .send(.island(.entryTapped(id)))

      case .setIslandHotKeyRegistrationFailure(let commandID, let binding):
        state.islandHotKeyRegistrationFailures[commandID] = binding
        return .none

      case .selectNextEntry:
        return navigate(&state, direction: .next)

      case .selectPreviousEntry:
        return navigate(&state, direction: .previous)

      case .togglePanelVisibility:
        state.$isPanelHidden.withLock { $0.toggle() }
        return .none

      case .panelHeightChanged(let height):
        state.$panelHeight.withLock { $0 = Self.clampedPanelHeight(height) }
        return .none
      }
    }
  }

  /// Moves the keyboard anchor to the neighbouring entry and reuses `entryTapped`
  /// so the parent reducer performs the actual worktree selection + surface focus.
  private func navigate(_ state: inout State, direction: NavigationDirection) -> Effect<Action> {
    guard
      let targetID = Self.entryID(
        navigatingFrom: state.focusedSurfaceID,
        direction: direction,
        in: state.orderedEntries
      )
    else {
      return .none
    }
    state.focusedSurfaceID = state.entries[id: targetID]?.surfaceID
    return .send(.entryTapped(targetID))
  }

  /// Resolves the entry to navigate to, anchored on the focused surface.
  ///
  /// When no entry matches the focused surface the list wraps from an edge:
  /// `.next` starts at the first entry and `.previous` at the last. With a known
  /// anchor it steps one position and wraps around the ends.
  static func entryID(
    navigatingFrom focusedSurfaceID: UUID?,
    direction: NavigationDirection,
    in entries: IdentifiedArrayOf<ActiveAgentEntry>
  ) -> ActiveAgentEntry.ID? {
    guard !entries.isEmpty else { return nil }
    let anchorIndex = focusedSurfaceID.flatMap { surfaceID in
      entries.firstIndex { $0.surfaceID == surfaceID }
    }
    switch direction {
    case .next:
      guard let anchorIndex else { return entries.first?.id }
      return entries[(anchorIndex + 1) % entries.count].id
    case .previous:
      guard let anchorIndex else { return entries.last?.id }
      return entries[(anchorIndex - 1 + entries.count) % entries.count].id
    }
  }

  static func clampedPanelHeight(_ height: Double) -> Double {
    min(maximumPanelHeight, max(minimumPanelHeight, height))
  }

  static func maximumPanelHeight(forContainerHeight height: Double) -> Double {
    max(minimumPanelHeight, min(maximumPanelHeight, height - reservedSidebarListHeight))
  }
}

extension ActiveAgentsFeature.Action {
  /// Actions that end in Prowl-owned UI: pane focus or the workflow start sheet. Raised from
  /// the island, these collapse the roster and surface the main window first.
  var surfacesProwl: Bool {
    switch self {
    case .entryTapped, .runWorkflowTapped:
      return true
    default:
      return false
    }
  }
}

extension ActiveAgentsFeature.State {
  var islandAttentionEntries: [ActiveAgentEntry] {
    entries.filter { $0.displayState == .blocked || $0.displayState == .done }
      .sorted { lhs, rhs in
        let lhsPriority = lhs.displayState == .blocked ? 0 : 1
        let rhsPriority = rhs.displayState == .blocked ? 0 : 1
        if lhsPriority != rhsPriority {
          return lhsPriority < rhsPriority
        }
        return lhs.lastChangedAt > rhs.lastChangedAt
      }
  }
}
