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
  enum NavigationDirection {
    case next
    case previous
  }

  @ObservableState
  struct State: Equatable {
    var entries: IdentifiedArrayOf<ActiveAgentEntry> = []
    /// Surface that currently has terminal focus, mirrored from `focusChanged` events.
    /// Used as the anchor for keyboard list navigation; not persisted.
    var focusedSurfaceID: UUID?
    @Shared(.appStorage("activeAgentsPanelHidden")) var isPanelHidden: Bool = false
    @Shared(.appStorage("activeAgentsPanelHeight")) var panelHeight: Double = 200
  }

  enum Action: Equatable {
    case agentEntryChanged(ActiveAgentEntry)
    case agentEntryRemoved(ActiveAgentEntry.ID)
    case entryTapped(ActiveAgentEntry.ID)
    case focusedSurfaceChanged(UUID?)
    case selectNextEntry
    case selectPreviousEntry
    case togglePanelVisibility
    case panelHeightChanged(Double)
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .agentEntryChanged(let entry):
        state.entries[id: entry.id] = entry
        return .none

      case .agentEntryRemoved(let id):
        state.entries.remove(id: id)
        return .none

      case .entryTapped(let id):
        // Mirror the tapped surface into the focus anchor so the panel highlight and
        // keyboard navigation step from the just-selected agent immediately. The async
        // `focusChanged` event can't be relied on here: it is deduplicated per worktree
        // (`emitFocusChangedIfNeeded`), so re-focusing a worktree's previously focused
        // surface emits nothing and would leave the anchor stale.
        state.focusedSurfaceID = state.entries[id: id]?.surfaceID
        return .none

      case .focusedSurfaceChanged(let surfaceID):
        state.focusedSurfaceID = surfaceID
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
        in: state.entries
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

  static func detectionEnabled(
    isPanelHidden: Bool,
    autoShowPanel: Bool
  ) -> Bool {
    !isPanelHidden || autoShowPanel
  }

}
