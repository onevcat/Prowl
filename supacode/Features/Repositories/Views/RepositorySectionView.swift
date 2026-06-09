import ComposableArchitecture
import Sharing
import SwiftUI

struct RepositorySectionView: View {
  private static let debugHeaderLayers = false
  let repository: Repository
  let hasTopSpacing: Bool
  let isDragActive: Bool
  let hotkeyRows: [WorktreeRowModel]
  let selectedWorktreeIDs: Set<Worktree.ID>
  @Binding var expandedRepoIDs: Set<Repository.ID>
  @Bindable var store: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager
  let onRepositorySelected: () -> Void
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.resolvedKeybindings) private var resolvedKeybindings
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovering = false
  @Shared(.repositoryAppearances) private var repositoryAppearances

  var body: some View {
    let state = store.state
    let isExpanded = expandedRepoIDs.contains(repository.id)
    let isRemovingRepository = state.isRemovingRepository(repository)
    let isSelected = state.selection == .repository(repository.id)
    let openRepoSettings = {
      _ = store.send(.repositoryManagement(.openRepositorySettings(repository.id)))
    }
    let toggleExpanded = {
      guard !isRemovingRepository else { return }
      withAnimation(.easeOut(duration: 0.2)) {
        if isExpanded {
          expandedRepoIDs.remove(repository.id)
        } else {
          expandedRepoIDs.insert(repository.id)
        }
      }
    }
    let appearance = repositoryAppearances[repository.id] ?? .empty
    let header = HStack {
      // Inner HStack groups the name row and the tab-count badge so they
      // share the leading-aligned region of the outer header. Crucially
      // the badge is its own leaf view (`RepoHeaderTabCountBadge`) — it
      // owns the `terminalManager` read so this view never subscribes
      // to the manager-wide states dictionary.
      HStack {
        RepoHeaderRow(
          name: repository.name,
          customTitle: store.repositoryCustomTitles[repository.id],
          isRemoving: isRemovingRepository,
          icon: appearance.icon,
          iconTint: appearance.color?.color ?? .accentColor,
          repositoryRootURL: repository.rootURL,
          nameTooltip: repository.capabilities.supportsWorktrees
            ? (isExpanded ? "Collapse" : "Expand")
            : (repository.isWorkspace ? "Open terminal in workspace" : "Open terminal in folder")
        )
        RepoHeaderTabCountBadge(
          repository: repository,
          terminalManager: terminalManager
        )
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .background {
        if Self.debugHeaderLayers {
          Rectangle()
            .fill(.green.opacity(0.18))
            .overlay {
              Rectangle()
                .stroke(.green, lineWidth: 1)
            }
        }
      }
      if isRemovingRepository {
        ProgressView()
          .controlSize(.small)
          .background {
            if Self.debugHeaderLayers {
              Rectangle()
                .fill(.yellow.opacity(0.18))
                .overlay {
                  Rectangle()
                    .stroke(.yellow, lineWidth: 1)
                }
            }
          }
      }
      if isHovering {
        Menu {
          Button("Repo Settings") {
            openRepoSettings()
          }
          .help("Repo Settings ")
          Button("Remove Repository") {
            store.send(.repositoryManagement(.requestRemoveRepository(repository.id)))
          }
          .help("Remove repository ")
          .disabled(isRemovingRepository)
        } label: {
          Label("Repository options", systemImage: "ellipsis")
            .labelStyle(.iconOnly)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .background {
              if Self.debugHeaderLayers {
                Rectangle()
                  .fill(.purple.opacity(0.18))
                  .overlay {
                    Rectangle()
                      .stroke(.purple, lineWidth: 1)
                  }
              }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Repository options ")
        .disabled(isRemovingRepository)
        if repository.capabilities.supportsWorktrees {
          Button {
            store.send(.worktreeCreation(.createRandomWorktreeInRepository(repository.id)))
          } label: {
            Label("New Worktree", systemImage: "plus")
              .labelStyle(.iconOnly)
              .frame(maxHeight: .infinity)
              .contentShape(Rectangle())
              .background {
                if Self.debugHeaderLayers {
                  Rectangle()
                    .fill(.mint.opacity(0.18))
                    .overlay {
                      Rectangle()
                        .stroke(.mint, lineWidth: 1)
                    }
                }
              }
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .help(
            AppShortcuts.helpText(
              title: "New Worktree",
              commandID: AppShortcuts.CommandID.newWorktree,
              in: resolvedKeybindings
            )
          )
          .disabled(isRemovingRepository)
        }
        if repository.capabilities.supportsWorktrees {
          Button {
            toggleExpanded()
          } label: {
            Image(systemName: "chevron.right")
              .rotationEffect(.degrees(isExpanded ? 90 : 0))
              .frame(maxHeight: .infinity)
              .contentShape(Rectangle())
              .accessibilityLabel(isExpanded ? "Collapse" : "Expand")
              .background {
                if Self.debugHeaderLayers {
                  Rectangle()
                    .fill(.orange.opacity(0.18))
                    .overlay {
                      Rectangle()
                        .stroke(.orange, lineWidth: 1)
                    }
                }
              }
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .help(isExpanded ? "Collapse" : "Expand")
        }
      }
      if let color = appearance.color {
        // Solid fill (not .glassEffect): glass/vibrant materials desaturate to
        // gray when the window is not key, but the repo color dot must keep its
        // color regardless of focus.
        Circle()
          .fill(color.color)
          .frame(width: 8, height: 8)
          .help(color.displayName)
          .accessibilityLabel(Text("Repo color: \(color.displayName)"))
      }
    }
    .frame(maxWidth: .infinity, minHeight: headerCellHeight, maxHeight: .infinity, alignment: .center)
    .padding(.horizontal, 12)
    .padding(.top, hasTopSpacing ? 4 : 0)
    .padding(.bottom, hasTopSpacing && !repository.capabilities.supportsWorktrees ? 4 : 0)
    .contentShape(.interaction, .rect)
    .background {
      if isSelected {
        RoundedRectangle(cornerRadius: 5)
          .fill(Color.accentColor.opacity(0.18))
          .padding(.horizontal, 6)
      } else if Self.debugHeaderLayers {
        Rectangle()
          .fill(.red.opacity(0.12))
          .overlay {
            Rectangle()
              .stroke(.red, lineWidth: 1)
          }
      }
    }
    .onHover { hovering in
      if reduceMotion {
        isHovering = hovering
      } else {
        withAnimation(.easeOut(duration: 0.15)) {
          isHovering = hovering
        }
      }
    }
    .onTapGesture {
      onRepositorySelected()
    }
    .accessibilityAddTraits(.isButton)
    .contentShape(.rect)
    .contextMenu {
      Button("Repo Settings") {
        openRepoSettings()
      }
      .help("Repo Settings ")
      Button("Remove Repository") {
        store.send(.repositoryManagement(.requestRemoveRepository(repository.id)))
      }
      .help("Remove repository ")
      .disabled(isRemovingRepository)
    }
    .contentShape(.dragPreview, .rect)
    .listRowBackground(Color.clear)
    .environment(\.colorScheme, colorScheme)
    .preferredColorScheme(colorScheme)

    VStack(spacing: 0) {
      header
        .tag(SidebarSelection.repository(repository.id))
      if isExpanded {
        WorktreeRowsView(
          repository: repository,
          isExpanded: isExpanded,
          hotkeyRows: hotkeyRows,
          selectedWorktreeIDs: selectedWorktreeIDs,
          store: store,
          terminalManager: terminalManager
        )
      }
    }
    .id(SidebarScrollID.repository(repository.id))
  }

  private var headerCellHeight: CGFloat {
    26
  }

  static func openTabCount(
    for repository: Repository,
    terminalManager: WorktreeTerminalManager
  ) -> Int {
    if repository.capabilities.supportsWorktrees {
      return repository.worktrees.reduce(0) { count, worktree in
        count + (terminalManager.stateIfExists(for: worktree.id)?.tabManager.tabs.count ?? 0)
      }
    }
    return terminalManager.stateIfExists(for: repository.id)?.tabManager.tabs.count ?? 0
  }
}
