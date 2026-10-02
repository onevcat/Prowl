import AppKit
import ComposableArchitecture

struct WorkspaceClient {
  var open:
    @MainActor @Sendable (
      _ action: OpenWorktreeAction,
      _ worktree: Worktree,
      _ onError: @escaping @MainActor @Sendable (OpenActionError) -> Void
    ) -> Void
}

extension WorkspaceClient: DependencyKey {
  static let liveValue = WorkspaceClient { action, worktree, onError in
    action.perform(with: worktree) { error in
      onError(error)
    }
  }

  static let testValue = WorkspaceClient { _, _, _ in }
}

extension DependencyValues {
  var workspaceClient: WorkspaceClient {
    get { self[WorkspaceClient.self] }
    set { self[WorkspaceClient.self] = newValue }
  }
}
