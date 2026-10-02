import Foundation
import ProwlCLIShared

struct ListRuntimeSnapshot: Sendable {
  struct Worktree: Sendable {
    let id: String
    let name: String
    let path: String
    let rootPath: String
    let kind: ListCommandWorktree.Kind
    let taskStatus: ListCommandTask.Status?
    let tabs: [Tab]
  }

  struct Tab: Sendable {
    let id: UUID
    let handle: Int?
    let title: String
    let selected: Bool
    let focusedPaneID: UUID?
    let panes: [Pane]

    init(
      id: UUID,
      handle: Int? = nil,
      title: String,
      selected: Bool,
      focusedPaneID: UUID?,
      panes: [Pane]
    ) {
      self.id = id
      self.handle = handle
      self.title = title
      self.selected = selected
      self.focusedPaneID = focusedPaneID
      self.panes = panes
    }
  }

  struct Pane: Sendable {
    let id: UUID
    let handle: Int?
    let title: String
    let cwd: String?
    let visible: Bool
    let agent: String?

    init(id: UUID, handle: Int? = nil, title: String, cwd: String?, visible: Bool = false, agent: String? = nil) {
      self.id = id
      self.handle = handle
      self.title = title
      self.cwd = cwd
      self.visible = visible
      self.agent = agent
    }
  }

  let worktrees: [Worktree]
  let focusedWorktreeID: String?
}

final class ListCommandHandler: CommandHandler {
  typealias SnapshotProvider = @MainActor () throws -> ListRuntimeSnapshot
  typealias ResolveCaller = @MainActor (CLICommandContext) -> CallerPane?

  private let snapshotProvider: SnapshotProvider
  private let resolveCaller: ResolveCaller

  init(
    resolveCaller: @escaping ResolveCaller = { _ in nil },
    snapshotProvider: @escaping SnapshotProvider
  ) {
    self.resolveCaller = resolveCaller
    self.snapshotProvider = snapshotProvider
  }

  func handle(envelope: CommandEnvelope) async -> CommandResponse {
    await handle(envelope: envelope, context: CLICommandContext())
  }

  // swiftlint:disable:next async_without_await
  func handle(envelope: CommandEnvelope, context: CLICommandContext) async -> CommandResponse {
    do {
      let snapshot = try snapshotProvider()
      let caller = resolveCaller(context).map {
        ListCommandCaller(paneID: $0.surfaceID.uuidString, worktreeID: $0.worktreeID)
      }
      let payload = makePayload(from: snapshot, includeHandles: envelope.output == .text, caller: caller)
      return try CommandResponse(
        ok: true,
        command: "list",
        schemaVersion: "prowl.cli.list.v1",
        data: RawJSON(encoding: payload)
      )
    } catch {
      return CommandResponse(
        ok: false,
        command: "list",
        schemaVersion: "prowl.cli.list.v1",
        error: CommandError(
          code: CLIErrorCode.listFailed,
          message: "Failed to list panes."
        )
      )
    }
  }

  private func makePayload(
    from snapshot: ListRuntimeSnapshot,
    includeHandles: Bool,
    caller: ListCommandCaller?
  ) -> ListCommandPayload {
    var items: [ListCommandItem] = []
    var didAssignFocusedPane = false

    for worktree in snapshot.worktrees {
      for tab in worktree.tabs {
        for pane in tab.panes {
          let isFocused =
            !didAssignFocusedPane
            && worktree.id == snapshot.focusedWorktreeID
            && tab.selected
            && tab.focusedPaneID == pane.id

          if isFocused {
            didAssignFocusedPane = true
          }

          items.append(
            ListCommandItem(
              worktree: ListCommandWorktree(
                id: worktree.id,
                name: worktree.name,
                path: worktree.path,
                rootPath: worktree.rootPath,
                kind: worktree.kind
              ),
              tab: ListCommandTab(
                id: tab.id.uuidString,
                handle: includeHandles ? tab.handle : nil,
                title: tab.title,
                selected: tab.selected
              ),
              pane: ListCommandPane(
                id: pane.id.uuidString,
                handle: includeHandles ? pane.handle : nil,
                title: pane.title,
                cwd: pane.cwd,
                focused: isFocused,
                visible: pane.visible,
                agent: pane.agent
              ),
              task: ListCommandTask(status: worktree.taskStatus)
            )
          )
        }
      }
    }

    let listedCaller = caller.flatMap { caller in items.contains { $0.pane.id == caller.pane.id } ? caller : nil }
    return ListCommandPayload(count: items.count, items: items, caller: listedCaller)
  }
}
