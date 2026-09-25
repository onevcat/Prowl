import AppKit
import SwiftUI

/// Rows for the child repositories of an expanded workspace.
/// Reuses `WorktreeRow` for visual parity with git worktree rows (`+N/-M` diff
/// badge, PR tag), while clicking a child focuses its bound terminal tab,
/// creating one rooted at that repository's folder when needed.
struct WorkspaceChildRowsView: View {
  let rows: [WorkspaceChildRowModel]
  let selectedID: String?
  let onSelect: (String) -> Void
  let onShowDiff: (String) -> Void
  let onShowOutgoingChanges: (String) -> Void
  let onEditWorkspace: () -> Void
  let onRemoveFromWorkspace: (String) -> Void

  var body: some View {
    ForEach(rows) { row in
      let isSelected = row.id == selectedID
      WorktreeRow(
        name: row.branchName ?? row.repositoryName,
        worktreeName: row.branchName == nil ? "" : row.repositoryName,
        info: row.info,
        iconSystemName: nil,
        showsPullRequestInfo: true,
        isHovered: false,
        isPinned: false,
        isMainWorktree: false,
        isLoading: false,
        taskStatus: nil,
        isRunScriptRunning: false,
        showsNotificationIndicator: false,
        notifications: [],
        onFocusNotification: { _ in },
        shortcutHint: nil,
        showsShortcutHint: false,
        pinAction: nil,
        isSelected: isSelected,
        archiveAction: nil,
        onDiffTap: { onShowDiff(row.id) },
        onStopRunScript: nil,
      )
      .padding(.leading, 14)
      .padding(.trailing, 8)
      .background {
        if isSelected {
          RoundedRectangle(cornerRadius: 8)
            .fill(Color.accentColor.opacity(0.18))
            .padding(.horizontal, 6)
        }
      }
      .padding(.vertical, 2)
      .contentShape(.interaction, .rect)
      .contentShape(.rect)
      .onTapGesture {
        onSelect(row.id)
      }
      .accessibilityAddTraits(.isButton)
      .help("Focus Terminal in \(row.repositoryName)")
      .contextMenu {
        Button("Copy Path") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(row.workingDirectory.path, forType: .string)
        }
        Button("Reveal in Finder") {
          NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: row.workingDirectory.path)
        }
        Divider()
        Button("Show Diff") {
          onShowDiff(row.id)
        }
        .help("Show uncommitted changes in \(row.repositoryName)")
        Button("Show Outgoing Changes") {
          onShowOutgoingChanges(row.id)
        }
        .help("Show committed changes relative to this repository's base")
        Divider()
        Button("Edit Workspace…") {
          onEditWorkspace()
        }
        .help("Edit the workspace title, description, links, and repositories")
        Button("Remove from Workspace…") {
          onRemoveFromWorkspace(row.id)
        }
        .help("Open the workspace editor with \(row.repositoryName) marked for removal")
      }
      .id(row.id)
    }
  }
}
