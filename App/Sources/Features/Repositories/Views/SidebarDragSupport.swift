import SwiftUI
import UniformTypeIdentifiers

extension UTType {
  nonisolated static let prowlSidebarDragPayload = UTType.plainText
}

enum SidebarDragProvider {
  private nonisolated static let repositoryPrefix = "prowl-sidebar-repository:"
  private nonisolated static let groupPrefix = "prowl-sidebar-group:"
  private nonisolated static let worktreePrefix = "prowl-sidebar-worktree:"

  nonisolated static func sidebarItem(_ item: SidebarDragItem) -> NSItemProvider {
    switch item {
    case .repository(let id): itemProvider(payload: repositoryPrefix + id)
    case .group(let id): itemProvider(payload: groupPrefix + id.uuidString)
    }
  }

  nonisolated static func worktree(id: Worktree.ID) -> NSItemProvider {
    itemProvider(payload: worktreePrefix + id)
  }

  nonisolated static func worktreeID(from data: Data) -> Worktree.ID? {
    payload(from: data, prefix: worktreePrefix)
  }

  private nonisolated static func itemProvider(payload: String) -> NSItemProvider {
    let provider = NSItemProvider()
    let loadHandler: @Sendable (@escaping @Sendable (Data?, (any Error)?) -> Void) -> Progress? = { completion in
      completion(Data(payload.utf8), nil)
      return nil
    }
    provider.registerDataRepresentation(
      forTypeIdentifier: UTType.prowlSidebarDragPayload.identifier,
      visibility: .all,
      loadHandler: loadHandler
    )
    return provider
  }

  private nonisolated static func payload(from data: Data, prefix: String) -> String? {
    guard let payload = String(data: data, encoding: .utf8),
      payload.hasPrefix(prefix)
    else {
      return nil
    }
    return String(payload.dropFirst(prefix.count))
  }
}

/// A row of the sidebar layout as a drop target (docs-ai 086 S2). It maps the drop
/// location in the row to a layout destination for the dragged item.
enum SidebarDropRow: Equatable {
  /// An ungrouped repository row at the top level. `nextKey` is the key of the
  /// next shown top-level entry, or nil for the last one.
  case repository(key: String, nextKey: String?)
  case groupHeader(RepositoryGroup.ID, nextKey: String?)
  /// A member row. `nextKey` is the top-level entry after the group.
  case groupMember(
    RepositoryGroup.ID,
    repositoryID: Repository.ID,
    nextMemberID: Repository.ID?,
    nextKey: String?
  )
  /// The placeholder of an open group without members.
  case emptyGroup(RepositoryGroup.ID, nextKey: String?)
  /// The drop area after the last entry.
  case listEnd

  /// The top part of a repository row that means "before this row".
  static let repositoryHeaderHeight = 24.0
  /// The top strip of a group header that puts a repository before the group.
  /// Below it, a repository goes to the end of the group.
  static let groupHeaderInsertionHeight = 8.0
  /// A group dragged over a group header goes before it above this line.
  static let groupHeaderMidline = 12.0

  func destination(for item: SidebarDragItem, locationY: Double) -> SidebarDropDestination {
    switch self {
    case .repository(let key, let nextKey):
      return .topLevel(before: locationY < Self.repositoryHeaderHeight ? key : nextKey)

    case .groupHeader(let groupID, let nextKey):
      let key = SidebarLayoutItem.groupKey(groupID)
      switch item {
      case .repository:
        return locationY < Self.groupHeaderInsertionHeight ? .topLevel(before: key) : .group(groupID, before: nil)
      case .group:
        return .topLevel(before: locationY < Self.groupHeaderMidline ? key : nextKey)
      }

    case .groupMember(let groupID, let repositoryID, let nextMemberID, let nextKey):
      switch item {
      case .repository:
        return .group(groupID, before: locationY < Self.repositoryHeaderHeight ? repositoryID : nextMemberID)
      case .group:
        // A group cannot go into a group, so it goes after the containing group.
        return .topLevel(before: nextKey)
      }

    case .emptyGroup(let groupID, let nextKey):
      switch item {
      case .repository: return .group(groupID, before: nil)
      case .group: return .topLevel(before: nextKey)
      }

    case .listEnd:
      return .topLevel(before: nil)
    }
  }
}

/// The drag state of the sidebar layout that each drop target and drag source reads.
struct SidebarLayoutDragContext {
  /// The item that this sidebar drags, or nil when no layout drag is active.
  var draggedItem: SidebarDragItem?
  var targetedDestination: Binding<SidebarDropDestination?>
  let beginDrag: (SidebarDragItem) -> Void
  let onDrop: (SidebarDragItem, SidebarDropDestination) -> Void
  let onDragEnded: () -> Void

  var isActive: Bool { draggedItem != nil }
}

struct SidebarLayoutDropDelegate: DropDelegate {
  let row: SidebarDropRow
  let context: SidebarLayoutDragContext

  func dropEntered(info: DropInfo) {
    updateTarget(info: info)
  }

  func dropExited(info: DropInfo) {
    context.targetedDestination.wrappedValue = nil
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    guard updateTarget(info: info) else { return nil }
    return DropProposal(operation: .move)
  }

  func performDrop(info: DropInfo) -> Bool {
    context.targetedDestination.wrappedValue = nil
    // Another drag, such as a worktree row, is not a layout drop.
    guard let item = context.draggedItem else { return false }
    let destination = row.destination(for: item, locationY: info.location.y)
    context.onDragEnded()
    context.onDrop(item, destination)
    return true
  }

  @discardableResult
  private func updateTarget(info: DropInfo) -> Bool {
    guard let item = context.draggedItem else {
      context.targetedDestination.wrappedValue = nil
      return false
    }
    context.targetedDestination.wrappedValue = row.destination(for: item, locationY: info.location.y)
    return true
  }
}

struct SidebarWorktreeDropDelegate: DropDelegate {
  let isEnabled: Bool
  let destination: (DropInfo) -> Int
  let sectionIDs: [Worktree.ID]
  @Binding var targetedDestination: Int?
  let actions: SidebarDropTargetActions

  func dropEntered(info: DropInfo) {
    guard isEnabled else {
      targetedDestination = nil
      return
    }
    targetedDestination = destination(info)
  }

  func dropExited(info: DropInfo) {
    targetedDestination = nil
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    guard isEnabled else {
      targetedDestination = nil
      return nil
    }
    targetedDestination = destination(info)
    return DropProposal(operation: .move)
  }

  func performDrop(info: DropInfo) -> Bool {
    guard isEnabled else {
      targetedDestination = nil
      return false
    }
    let dropDestination = destination(info)
    targetedDestination = nil
    if let worktreeID = actions.draggedItemID {
      return performDrop(worktreeID: worktreeID, dropDestination: dropDestination)
    }
    guard let provider = info.itemProviders(for: [.prowlSidebarDragPayload]).first else {
      actions.onDragEnded()
      return false
    }
    provider.loadDataRepresentation(forTypeIdentifier: UTType.prowlSidebarDragPayload.identifier) { data, _ in
      guard let data,
        let worktreeID = SidebarDragProvider.worktreeID(from: data)
      else {
        Task { @MainActor in actions.onDragEnded() }
        return
      }
      Task { @MainActor in
        _ = performDrop(worktreeID: worktreeID, dropDestination: dropDestination)
      }
    }
    return true
  }

  @MainActor
  private func performDrop(worktreeID: Worktree.ID, dropDestination: Int) -> Bool {
    guard let source = sectionIDs.firstIndex(of: worktreeID),
      source != dropDestination,
      source + 1 != dropDestination
    else {
      actions.onDragEnded()
      return false
    }
    actions.onDragEnded()
    actions.onDrop(IndexSet(integer: source), dropDestination)
    return true
  }
}

struct SidebarDropIndicator: View {
  let isVisible: Bool
  var horizontalPadding: CGFloat = 12

  var body: some View {
    ZStack {
      if isVisible {
        Capsule()
          .fill(Color.accentColor)
          .frame(height: 2)
          .padding(.horizontal, horizontalPadding)
          .transition(.opacity)
      }
    }
    .frame(maxWidth: .infinity)
    .frame(height: 6)
    .accessibilityHidden(true)
  }
}

enum SidebarDropIndicatorEdge: Equatable {
  case none
  case top
  case bottom

  static func edge(
    targetedDestination: Int?,
    rowIndex: Int,
    rowCount: Int
  ) -> Self {
    guard let targetedDestination else {
      return .none
    }
    if targetedDestination == rowIndex {
      return .top
    }
    if rowIndex == rowCount - 1, targetedDestination == rowCount {
      return .bottom
    }
    return .none
  }
}

extension SidebarDropIndicatorEdge {
  /// The edge that a layout row draws: `top` is the destination before the row,
  /// `bottom` the destination after it when the row is the last one of its list.
  static func edge(
    targetedDestination: SidebarDropDestination?,
    top: SidebarDropDestination,
    bottom: SidebarDropDestination?
  ) -> Self {
    guard let targetedDestination else { return .none }
    if targetedDestination == top {
      return .top
    }
    if let bottom, targetedDestination == bottom {
      return .bottom
    }
    return .none
  }
}

struct SidebarDropTargetActions {
  var draggedItemID: String?
  let onDrop: (IndexSet, Int) -> Void
  let onDragEnded: () -> Void
}

extension View {
  /// Draws the accent line of a layout drop at the edge that `top` or `bottom`
  /// names, when the targeted destination is one of them (docs-ai 086 S2).
  func sidebarLayoutDropIndicators(
    top: SidebarDropDestination,
    bottom: SidebarDropDestination?,
    targetedDestination: SidebarDropDestination?
  ) -> some View {
    let edge = SidebarDropIndicatorEdge.edge(targetedDestination: targetedDestination, top: top, bottom: bottom)
    return
      self
      .overlay(alignment: .top) {
        SidebarDropIndicator(isVisible: edge == .top)
      }
      .overlay(alignment: .bottom) {
        SidebarDropIndicator(isVisible: edge == .bottom)
      }
  }

  func sidebarLayoutDropTarget(_ row: SidebarDropRow, context: SidebarLayoutDragContext) -> some View {
    onDrop(
      of: [.prowlSidebarDragPayload],
      delegate: SidebarLayoutDropDelegate(row: row, context: context)
    )
  }

  func worktreeDropTarget(
    index: Int,
    rowIDs: [Worktree.ID],
    isEnabled: Bool,
    targetedDestination: Binding<Int?>,
    actions: SidebarDropTargetActions
  ) -> some View {
    let edge = SidebarDropIndicatorEdge.edge(
      targetedDestination: targetedDestination.wrappedValue,
      rowIndex: index,
      rowCount: rowIDs.count
    )
    return
      self
      .overlay(alignment: .top) {
        SidebarDropIndicator(isVisible: edge == .top, horizontalPadding: 28)
      }
      .overlay(alignment: .bottom) {
        SidebarDropIndicator(isVisible: edge == .bottom, horizontalPadding: 28)
      }
      .modifier(
        SidebarWorktreeDropTargetModifier(
          isEnabled: isEnabled,
          index: index,
          rowIDs: rowIDs,
          targetedDestination: targetedDestination,
          actions: actions
        )
      )
  }

  @ViewBuilder
  func draggableSidebarItem(
    _ item: SidebarDragItem,
    isEnabled: Bool,
    context: SidebarLayoutDragContext
  ) -> some View {
    if isEnabled {
      self.onDrag {
        context.beginDrag(item)
        return SidebarDragProvider.sidebarItem(item)
      }
    } else {
      self
    }
  }

  @ViewBuilder
  func draggableWorktree(
    id: Worktree.ID,
    isEnabled: Bool,
    beginDrag: @escaping () -> Void
  ) -> some View {
    if isEnabled {
      self.onDrag {
        beginDrag()
        return SidebarDragProvider.worktree(id: id)
      }
    } else {
      self
    }
  }
}

private struct SidebarWorktreeDropTargetModifier: ViewModifier {
  let isEnabled: Bool
  let index: Int
  let rowIDs: [Worktree.ID]
  @Binding var targetedDestination: Int?
  let actions: SidebarDropTargetActions

  @ViewBuilder
  func body(content: Content) -> some View {
    content.onDrop(
      of: [.prowlSidebarDragPayload],
      delegate: SidebarWorktreeDropDelegate(
        isEnabled: isEnabled,
        destination: { info in
          info.location.y < 18 ? index : index + 1
        },
        sectionIDs: rowIDs,
        targetedDestination: $targetedDestination,
        actions: actions
      )
    )
  }
}
