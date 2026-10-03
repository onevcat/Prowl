import SwiftUI
import UniformTypeIdentifiers

extension UTType {
  nonisolated static let prowlSidebarDragPayload = UTType.plainText
}

enum SidebarDragProvider {
  private nonisolated static let repositoryPrefix = "prowl-sidebar-repository:"
  private nonisolated static let worktreePrefix = "prowl-sidebar-worktree:"

  nonisolated static func repository(id: Repository.ID) -> NSItemProvider {
    itemProvider(payload: repositoryPrefix + id)
  }

  nonisolated static func worktree(id: Worktree.ID) -> NSItemProvider {
    itemProvider(payload: worktreePrefix + id)
  }

  nonisolated static func repositoryID(from data: Data) -> Repository.ID? {
    payload(from: data, prefix: repositoryPrefix)
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

struct SidebarRepositoryDropDelegate: DropDelegate {
  let isEnabled: Bool
  let destination: (DropInfo) -> Int
  let repositoryOrderIDs: [Repository.ID]
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
    if let repositoryID = actions.draggedItemID {
      return performDrop(repositoryID: repositoryID, dropDestination: dropDestination)
    }
    guard let provider = info.itemProviders(for: [.prowlSidebarDragPayload]).first else {
      actions.onDragEnded()
      return false
    }
    provider.loadDataRepresentation(forTypeIdentifier: UTType.prowlSidebarDragPayload.identifier) { data, _ in
      guard let data,
        let repositoryID = SidebarDragProvider.repositoryID(from: data)
      else {
        Task { @MainActor in actions.onDragEnded() }
        return
      }
      Task { @MainActor in
        _ = performDrop(repositoryID: repositoryID, dropDestination: dropDestination)
      }
    }
    return true
  }

  @MainActor
  private func performDrop(repositoryID: Repository.ID, dropDestination: Int) -> Bool {
    guard let source = repositoryOrderIDs.firstIndex(of: repositoryID),
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

struct SidebarDropTargetActions {
  var draggedItemID: String?
  let onDrop: (IndexSet, Int) -> Void
  let onDragEnded: () -> Void
}

extension View {
  func repositoryDropTarget(
    index: Int,
    repositoryOrderIDs: [Repository.ID],
    isEnabled: Bool,
    targetedDestination: Binding<Int?>,
    actions: SidebarDropTargetActions
  ) -> some View {
    let edge = SidebarDropIndicatorEdge.edge(
      targetedDestination: targetedDestination.wrappedValue,
      rowIndex: index,
      rowCount: repositoryOrderIDs.count
    )
    return
      self
      .overlay(alignment: .top) {
        SidebarDropIndicator(isVisible: edge == .top)
      }
      .overlay(alignment: .bottom) {
        SidebarDropIndicator(isVisible: edge == .bottom)
      }
      .modifier(
        SidebarRepositoryDropTargetModifier(
          isEnabled: isEnabled,
          index: index,
          repositoryOrderIDs: repositoryOrderIDs,
          targetedDestination: targetedDestination,
          actions: actions
        )
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
  func draggableRepository(
    id: Repository.ID,
    isEnabled: Bool,
    beginDrag: @escaping () -> Void
  ) -> some View {
    if isEnabled {
      self.onDrag {
        beginDrag()
        return SidebarDragProvider.repository(id: id)
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

private struct SidebarRepositoryDropTargetModifier: ViewModifier {
  let isEnabled: Bool
  let index: Int
  let repositoryOrderIDs: [Repository.ID]
  @Binding var targetedDestination: Int?
  let actions: SidebarDropTargetActions

  @ViewBuilder
  func body(content: Content) -> some View {
    content.onDrop(
      of: [.prowlSidebarDragPayload],
      delegate: SidebarRepositoryDropDelegate(
        isEnabled: isEnabled,
        destination: { info in
          info.location.y < 24 ? index : index + 1
        },
        repositoryOrderIDs: repositoryOrderIDs,
        targetedDestination: $targetedDestination,
        actions: actions
      )
    )
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
