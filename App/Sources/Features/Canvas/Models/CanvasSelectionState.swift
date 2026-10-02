import Foundation

struct CanvasSelectionState: Equatable {
  enum Mode: Equatable {
    case idle
    case selecting
  }

  private(set) var mode: Mode = .idle
  private(set) var selectedTabIDs: Set<TerminalTabID> = []
  private(set) var primaryTabID: TerminalTabID?
  private(set) var selectionOrder: [TerminalTabID] = []

  var isSelecting: Bool {
    mode == .selecting
  }

  var isBroadcasting: Bool {
    selectedTabIDs.count > 1
  }

  mutating func focusSingle(_ tabID: TerminalTabID) {
    mode = .idle
    selectedTabIDs = [tabID]
    primaryTabID = tabID
    selectionOrder = [tabID]
  }

  mutating func toggleSelection(_ tabID: TerminalTabID) {
    mode = .selecting
    if selectedTabIDs.contains(tabID) {
      selectedTabIDs.remove(tabID)
      selectionOrder.removeAll { $0 == tabID }
      if selectedTabIDs.isEmpty {
        mode = .idle
        primaryTabID = nil
        selectionOrder = []
      } else if primaryTabID == tabID {
        primaryTabID = selectionOrder.last ?? selectedTabIDs.first
      }
      return
    }

    selectedTabIDs.insert(tabID)
    selectionOrder.removeAll { $0 == tabID }
    selectionOrder.append(tabID)
    primaryTabID = tabID
  }

  mutating func setPrimary(_ tabID: TerminalTabID) {
    guard selectedTabIDs.contains(tabID) else { return }
    primaryTabID = tabID
    selectionOrder.removeAll { $0 == tabID }
    selectionOrder.append(tabID)
  }

  mutating func selectAll(_ tabIDs: [TerminalTabID]) {
    guard !tabIDs.isEmpty else { return }
    mode = .idle
    selectedTabIDs = Set(tabIDs)
    selectionOrder = tabIDs
    if let primaryTabID, selectedTabIDs.contains(primaryTabID) {
      // Keep current primary if it's still in the set.
      selectionOrder.removeAll { $0 == primaryTabID }
      selectionOrder.append(primaryTabID)
    } else {
      primaryTabID = tabIDs.last
    }
  }

  mutating func beginBroadcastInteractionIfNeeded() {
    guard isSelecting, selectedTabIDs.count > 1 else { return }
    mode = .idle
  }

  mutating func clear() {
    mode = .idle
    selectedTabIDs = []
    primaryTabID = nil
    selectionOrder = []
  }

  mutating func prune(to visibleTabIDs: Set<TerminalTabID>) {
    selectedTabIDs.formIntersection(visibleTabIDs)
    selectionOrder.removeAll { !visibleTabIDs.contains($0) }
    if let primaryTabID, !visibleTabIDs.contains(primaryTabID) {
      self.primaryTabID = selectionOrder.last ?? selectedTabIDs.first
    }
    if selectedTabIDs.isEmpty {
      clear()
    }
  }

  /// Prune against `currentOrder` and, if the primary was removed while cards
  /// remain visible, auto-focus the nearest surviving neighbor in
  /// `previousOrder` (searching forward first, then backward). This keeps a
  /// card highlighted after the primary is closed so users never lose the
  /// selection indicator for the "next" focused card.
  mutating func pruneAutoAdvancingPrimary(
    previousOrder: [TerminalTabID],
    currentOrder: [TerminalTabID]
  ) {
    let previousPrimary = primaryTabID
    let currentSet = Set(currentOrder)
    prune(to: currentSet)

    guard primaryTabID == nil,
      let previousPrimary,
      !currentSet.contains(previousPrimary),
      !currentOrder.isEmpty
    else {
      return
    }

    let replacement =
      Self.nearestSurvivor(
        of: previousPrimary,
        previousOrder: previousOrder,
        currentSet: currentSet
      ) ?? currentOrder[0]
    focusSingle(replacement)
  }

  private static func nearestSurvivor(
    of removedID: TerminalTabID,
    previousOrder: [TerminalTabID],
    currentSet: Set<TerminalTabID>
  ) -> TerminalTabID? {
    guard let removedIndex = previousOrder.firstIndex(of: removedID) else {
      return nil
    }
    var offset = 1
    while offset < previousOrder.count {
      let forward = removedIndex + offset
      if forward < previousOrder.count, currentSet.contains(previousOrder[forward]) {
        return previousOrder[forward]
      }
      let backward = removedIndex - offset
      if backward >= 0, currentSet.contains(previousOrder[backward]) {
        return previousOrder[backward]
      }
      offset += 1
    }
    return nil
  }
}
