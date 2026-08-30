import SwiftUI

struct RepositoryDetailView: View {
  let repository: Repository
  /// Resolved by the parent reducer. When non-nil, takes precedence
  /// over `repository.name` for display.
  var customTitle: String?

  var body: some View {
    if let workspace = repository.workspace {
      WorkspaceDetailView(repository: repository, workspace: workspace)
    } else {
      repositoryDetail
    }
  }

  private var repositoryDetail: some View {
    VStack(spacing: 12) {
      Image(systemName: repository.kind == .git ? "folder.badge.gearshape" : "folder")
        .interfaceFont(.largeTitle)
        .accessibilityHidden(true)
      RepoDisplayName(
        fallbackName: repository.name,
        customTitle: customTitle
      )
      .interfaceFont(.title3, weight: .semibold)
      Text(repository.rootURL.path(percentEncoded: false))
        .interfaceFont(.subheadline, design: .monospaced)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
      Text(descriptionText)
        .interfaceFont(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
    .background(Color(nsColor: .windowBackgroundColor))
    .multilineTextAlignment(.center)
  }

  private var descriptionText: String {
    switch repository.kind {
    case .git:
      "Select a worktree to open its terminal and repository tools."
    case .plain:
      "This folder is available in the sidebar. Git-only actions stay hidden."
    }
  }
}
