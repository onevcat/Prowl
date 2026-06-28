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
  /// Remote avatar URL fetched from the code host (e.g. GitHub owner
  /// avatar). Only used when `icon` is `nil`.
  let remoteAvatarURL: URL?
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
      } else if let remoteAvatarURL {
        RemoteAvatarView(url: remoteAvatarURL, size: 14)
      }
      RepoDisplayName(
        fallbackName: name,
        customTitle: customTitle,
        tooltip: nameTooltip
      )
      .foregroundStyle(.secondary)
      if isRemoving {
        Text("Removing...")
          .font(.caption)
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

/// Renders a remote avatar URL as a small circular image. Shows a
/// placeholder initials badge while loading or on failure.
struct RemoteAvatarView: View {
  let url: URL
  let size: CGFloat

  var body: some View {
    AsyncImage(url: url) { phase in
      switch phase {
      case .empty:
        placeholder
      case .success(let image):
        image
          .resizable()
          .aspectRatio(contentMode: .fill)
          .clipShape(Circle())
      case .failure:
        placeholder
      @unknown default:
        placeholder
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }

  @ViewBuilder
  private var placeholder: some View {
    Circle()
      .fill(.quaternary)
      .overlay(
        Image(systemName: "person.circle.fill")
          .resizable()
          .aspectRatio(contentMode: .fit)
          .foregroundStyle(.tertiary)
          .padding(size * 0.2)
          .accessibilityHidden(true)
      )
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
    let count = RepositorySectionView.openTabCount(
      for: repository,
      terminalManager: terminalManager
    )
    if count > 0 {
      Text("\(count)")
        .font(.caption2)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(.quaternary, in: .capsule)
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
      repositoryRootURL: nil,
      remoteAvatarURL: nil
    )
    RepoHeaderRow(
      name: "ghostty",
      isRemoving: false,
      icon: .sfSymbol("folder.fill"),
      iconTint: .blue,
      repositoryRootURL: URL(fileURLWithPath: "/tmp/ghostty"),
      remoteAvatarURL: nil
    )
    RepoHeaderRow(
      name: "removing-repo",
      isRemoving: true,
      icon: .sfSymbol("hammer.fill"),
      iconTint: .orange,
      repositoryRootURL: URL(fileURLWithPath: "/tmp/removing"),
      remoteAvatarURL: nil
    )
  }
  .padding()
}
