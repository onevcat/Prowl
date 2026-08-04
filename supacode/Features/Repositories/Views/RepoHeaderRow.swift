import SwiftUI

struct RepoHeaderRow: View {
  private static let debugHeaderLayers = false
  let name: String
  /// User-defined display title resolved by the parent reducer. When
  /// non-nil, takes precedence over `name` for display.
  var customTitle: String?
  let isRemoving: Bool
  /// User-pinned icon, when set. Renders before the repo name.
  /// `nil` keeps the historical text-only layout intact.
  let icon: RepositoryIconSource?
  /// Resolved tint applied to tintable icons (SF Symbols / SVGs).
  /// PNGs and bundled assets ignore this and render their own colors.
  let iconTint: Color?
  /// Repo root URL — needed by `RepositoryIconImage` to resolve
  /// user-imported image filenames into absolute file URLs.
  let repositoryRootURL: URL?
  var nameTooltip: String?

  var body: some View {
    HStack {
      if let icon, let repositoryRootURL {
        RepositoryIconImage(
          icon: icon,
          repositoryRootURL: repositoryRootURL,
          tintColor: iconTint,
          size: 14
        )
      }
      RepoDisplayName(
        fallbackName: name,
        customTitle: customTitle,
        tooltip: nameTooltip
      )
      .interfaceFont(.body)
      .foregroundStyle(.secondary)
      if isRemoving {
        Text("Removing...")
          .interfaceFont(.caption)
          .foregroundStyle(.tertiary)
      }
    }
    .background {
      if Self.debugHeaderLayers {
        Rectangle()
          .fill(.cyan.opacity(0.18))
          .overlay {
            Rectangle()
              .stroke(.cyan, lineWidth: 1)
          }
      }
    }
  }
}

/// Leaf view that renders the open-tab count badge for a repository.
///
/// Lives in its own `View` so the read of `terminalManager` (an
/// `@Observable` whose `states` dictionary churns whenever terminal
/// activity happens) is isolated to this subtree. Without this split,
/// `RepositorySectionView.body` would subscribe to every change in
/// `terminalManager.states` on every re-evaluation — which under heavy
/// terminal activity caused tens of thousands of body invocations per
/// second across the sidebar.
struct RepoHeaderTabCountBadge: View {
  let repository: Repository
  let terminalManager: WorktreeTerminalManager

  var body: some View {
    TabCountBadge(
      count: RepositorySectionView.openTabCount(
        for: repository,
        terminalManager: terminalManager
      )
    )
  }
}

/// Leaf view that renders the open-tab count badge for a single worktree
/// row. Isolated for the same reason as `RepoHeaderTabCountBadge`: only
/// this subtree subscribes to terminal state churn.
struct WorktreeTabCountBadge: View {
  let worktreeID: Worktree.ID
  let terminalManager: WorktreeTerminalManager

  var body: some View {
    TabCountBadge(
      count: terminalManager.stateIfExists(for: worktreeID)?.tabManager.tabs.count ?? 0
    )
  }
}

/// Capsule open-tab count badge shared by the repository header and
/// worktree rows. Hidden at count 0.
struct TabCountBadge: View {
  let count: Int

  var body: some View {
    if count > 0 {
      Text("\(count)")
        .interfaceFont(.caption2)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(.quaternary, in: .capsule)
        // Keep natural size when the row is width-starved; the sibling
        // name text (higher layout priority) truncates instead.
        .fixedSize()
        .help("\(count) active \(count == 1 ? "tab" : "tabs")")
    }
  }
}

// MARK: - Previews

#Preview("RepoHeaderRow") {
  VStack(alignment: .leading, spacing: 12) {
    RepoHeaderRow(
      name: "supacode",
      isRemoving: false,
      icon: nil,
      iconTint: nil,
      repositoryRootURL: nil
    )
    RepoHeaderRow(
      name: "ghostty",
      isRemoving: false,
      icon: .sfSymbol("folder.fill"),
      iconTint: .blue,
      repositoryRootURL: URL(fileURLWithPath: "/tmp/ghostty")
    )
    RepoHeaderRow(
      name: "removing-repo",
      isRemoving: true,
      icon: .sfSymbol("hammer.fill"),
      iconTint: .orange,
      repositoryRootURL: URL(fileURLWithPath: "/tmp/removing")
    )
  }
  .padding()
}
