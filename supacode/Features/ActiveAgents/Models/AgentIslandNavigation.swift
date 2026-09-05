import IdentifiedCollections

struct AgentIslandNavigation: Equatable {
  static let pageSize = 9

  var selectedEntryID: ActiveAgentEntry.ID?
  var pageIndex = 0

  mutating func start(
    entries: IdentifiedArrayOf<ActiveAgentEntry>,
    preferredEntryID: ActiveAgentEntry.ID?,
    preferredSurfaceID: ActiveAgentEntry.ID?
  ) {
    guard !entries.isEmpty else {
      self = .init()
      return
    }
    let preferredIndex =
      preferredEntryID.flatMap { entries.index(id: $0) }
      ?? preferredSurfaceID.flatMap { surfaceID in
        entries.firstIndex { $0.surfaceID == surfaceID }
      }
    let selectedIndex = preferredIndex ?? 0
    selectedEntryID = entries[selectedIndex].id
    pageIndex = selectedIndex / Self.pageSize
  }

  mutating func reconcile(entries: IdentifiedArrayOf<ActiveAgentEntry>) {
    guard !entries.isEmpty else {
      self = .init()
      return
    }
    if let selectedIndex = selectedEntryID.flatMap({ entries.index(id: $0) }) {
      pageIndex = selectedIndex / Self.pageSize
      return
    }
    let pageCount = (entries.count + Self.pageSize - 1) / Self.pageSize
    pageIndex = min(max(0, pageIndex), pageCount - 1)
    let selectedIndex = min(pageIndex * Self.pageSize, entries.count - 1)
    selectedEntryID = entries[selectedIndex].id
  }

  mutating func moveSelection(
    _ direction: ActiveAgentsFeature.NavigationDirection,
    entries: IdentifiedArrayOf<ActiveAgentEntry>
  ) {
    guard !entries.isEmpty else { return }
    let currentIndex = selectedEntryID.flatMap { entries.index(id: $0) } ?? 0
    let selectedIndex: Int
    switch direction {
    case .next:
      selectedIndex = min(currentIndex + 1, entries.count - 1)
    case .previous:
      selectedIndex = max(currentIndex - 1, 0)
    }
    selectedEntryID = entries[selectedIndex].id
    pageIndex = selectedIndex / Self.pageSize
  }

  mutating func movePage(
    _ direction: ActiveAgentsFeature.NavigationDirection,
    entries: IdentifiedArrayOf<ActiveAgentEntry>
  ) {
    guard !entries.isEmpty else { return }
    let pageCount = (entries.count + Self.pageSize - 1) / Self.pageSize
    let currentPage = min(max(0, pageIndex), pageCount - 1)
    let targetPage: Int
    switch direction {
    case .next:
      targetPage = min(currentPage + 1, pageCount - 1)
    case .previous:
      targetPage = max(currentPage - 1, 0)
    }
    guard targetPage != currentPage else { return }

    let selectedIndex = selectedEntryID.flatMap { entries.index(id: $0) }
    let row = selectedIndex.map { $0 % Self.pageSize } ?? 0
    let targetIndex = min(targetPage * Self.pageSize + row, entries.count - 1)
    selectedEntryID = entries[targetIndex].id
    pageIndex = targetPage
  }

  func visibleEntryID(
    at index: Int,
    entries: IdentifiedArrayOf<ActiveAgentEntry>
  ) -> ActiveAgentEntry.ID? {
    guard (0..<Self.pageSize).contains(index) else { return nil }
    let absoluteIndex = pageIndex * Self.pageSize + index
    guard entries.indices.contains(absoluteIndex) else { return nil }
    return entries[absoluteIndex].id
  }
}
