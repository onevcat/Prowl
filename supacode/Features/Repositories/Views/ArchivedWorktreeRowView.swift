import SwiftUI

struct ArchivedWorktreeRowView: View {
  let worktree: Worktree
  let info: WorktreeInfoEntry?
  let onUnarchive: () -> Void
  let onDelete: () -> Void
  @Environment(\.interfaceText) private var interfaceText

  var body: some View {
    let display = WorktreePullRequestDisplay(
      worktreeName: worktree.name,
      pullRequest: info?.pullRequest
    )
    let deleteShortcut = KeyboardShortcut(.delete, modifiers: [.command, .shift]).display
    let bodyFontAscender = InterfaceTextMetrics.bodyAscender(resolution: interfaceText)
    VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: "archivebox")
          .interfaceFont(.caption)
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
          .frame(width: 16, height: 16)
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
      .frame(minHeight: 14 + InterfaceTextMetrics.extraHeight(.caption, resolution: interfaceText))
      .padding(.leading, 24)
    }
    .frame(height: rowHeight, alignment: .center)
  }

  /// Base height plus whatever the text floor adds to the two lines
  /// (body name, caption info) the row stacks.
  private var rowHeight: CGFloat {
    50
      + InterfaceTextMetrics.extraHeight(.body, resolution: interfaceText)
      + InterfaceTextMetrics.extraHeight(.caption, resolution: interfaceText)
  }
}
