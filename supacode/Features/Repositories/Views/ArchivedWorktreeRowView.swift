import SwiftUI

struct ArchivedWorktreeRowView: View {
  let worktree: Worktree
  let info: WorktreeInfoEntry?
  let onUnarchive: () -> Void
  let onDelete: () -> Void
  @Environment(\.interfaceTextScale) private var interfaceTextScale

  var body: some View {
    let display = WorktreePullRequestDisplay(
      worktreeName: worktree.name,
      pullRequest: info?.pullRequest
    )
    let deleteShortcut = KeyboardShortcut(.delete, modifiers: [.command, .shift]).display
    let bodyFontAscender = InterfaceTextMetrics.bodyAscender(scale: interfaceTextScale)
    VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: "archivebox")
          .interfaceFont(.caption)
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
          .frame(width: 16 * interfaceTextScale, height: 16 * interfaceTextScale)
          .alignmentGuide(.firstTextBaseline) { _ in
            bodyFontAscender
          }
        Text(worktree.name)
          .interfaceFont(.body)
          .lineLimit(1)
        Spacer(minLength: 8)
        HStack(spacing: 8) {
          Button {
            onUnarchive()
          } label: {
            Image(systemName: "tray.and.arrow.up")
              .accessibilityLabel("Unarchive worktree")
          }
          .buttonStyle(.plain)
          .help("Unarchive worktree")
          Button(role: .destructive) {
            onDelete()
          } label: {
            Image(systemName: "trash")
              .accessibilityLabel("Delete worktree")
          }
          .buttonStyle(.plain)
          .help("Delete Worktree (\(deleteShortcut))")
        }
      }
      HStack(spacing: 6) {
        if let createdAt = worktree.createdAt {
          Text("Created \(createdAt, style: .relative)")
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        WorktreePullRequestAccessoryView(display: display)
      }
      .interfaceFont(.caption)
      .lineLimit(1)
      .frame(minHeight: 14 * interfaceTextScale)
      .padding(.leading, 16 * interfaceTextScale + 8)
    }
    .frame(height: rowHeight, alignment: .center)
  }

  private var rowHeight: CGFloat {
    50 * interfaceTextScale
  }
}
