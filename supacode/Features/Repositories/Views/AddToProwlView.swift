import AppKit
import SwiftUI

struct AddToProwlView: View {
  let dismiss: () -> Void
  let onBrowse: () -> Void
  let onCloneCompleted: (URL) -> Void
  let onWorkspace: () -> Void
  let onDrop: ([URL]) -> Void
  @State private var isDragTargeted = false
  @State private var isWorkspaceHovered = false
  @State private var showCloneForm = false
  @State private var showRemoteForm = false

  var body: some View {
    if showRemoteForm {
      AddRemoteMirrorView(dismiss: dismiss, back: { showRemoteForm = false })
    } else if showCloneForm {
      CloneRepositoryView(dismiss: dismiss) { clonedURL in
        onCloneCompleted(clonedURL)
      }
    } else {
      mainContent
    }
  }

  private var mainContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center, spacing: 12) {
        Image(nsImage: NSApp.applicationIconImage)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 38, height: 38)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text("Add to Prowl")
            .font(.system(size: 16, weight: .semibold))
          Text("Bring a project in for an agent to work on.")
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
        }
      }
      .padding(.bottom, 18)

      dropZone

      orDivider
        .padding(.top, 16)
        .padding(.bottom, 12)
        .padding(.horizontal, 2)

      workspaceRow
      Button {
        showRemoteForm = true
      } label: {
        HStack(spacing: 16) {
          Image(systemName: "network").font(.title).accessibilityHidden(true)
          VStack(alignment: .leading) {
            Text("Remote Mirror Pane").font(.headline)
            Text("Connect to a pane on another Prowl").foregroundStyle(.secondary)
          }
          Spacer()
          Image(systemName: "chevron.right").accessibilityHidden(true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
      }
      .buttonStyle(.plain)
      .padding(.top, 12)
      .accessibilityIdentifier("add-remote-mirror-button")

      HStack {
        Spacer()
        Button("Cancel") {
          dismiss()
        }
      }
      .padding(.top, 16)
    }
    .padding(EdgeInsets(top: 26, leading: 26, bottom: 20, trailing: 26))
    .frame(width: 400)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Add to Prowl")
    .accessibilityIdentifier("add-to-prowl-popover")
  }

  private var dropZone: some View {
    VStack(spacing: 2) {
      Image(systemName: "folder.badge.plus")
        .font(.system(size: 28))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(Color.accentColor)
        .frame(width: 52, height: 52)
        .accessibilityHidden(true)
        .background(
          Color.accentColor.opacity(isDragTargeted ? 0.2 : 0.1),
          in: .rect(cornerRadius: 14)
        )
        .scaleEffect(isDragTargeted ? 1.06 : 1)

      Text(isDragTargeted ? "Release to add" : "Drag a repo here")
        .font(.system(size: 15, weight: .semibold))
        .padding(.top, 10)

      Text("a Git repository or any folder — opens one project root")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)

      HStack(spacing: 8) {
        Button("Browse…") {
          dismiss()
          onBrowse()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)

        Button("Clone…") {
          showCloneForm = true
        }
        .controlSize(.small)
      }
      .padding(.top, 14)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 26)
    .padding(.horizontal, 20)
    .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 15))
    .overlay {
      RoundedRectangle(cornerRadius: 15)
        .strokeBorder(
          isDragTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
          style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
        )
    }
    .dropDestination(for: URL.self) { urls, _ in
      let fileURLs = urls.filter(\.isFileURL)
      guard !fileURLs.isEmpty else { return false }
      dismiss()
      onDrop(fileURLs)
      return true
    } isTargeted: { targeted in
      withAnimation(.easeOut(duration: 0.18)) {
        isDragTargeted = targeted
      }
    }
  }

  private var orDivider: some View {
    HStack(spacing: 12) {
      Rectangle().fill(.separator).frame(height: 1)
      Text("OR")
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(.tertiary)
      Rectangle().fill(.separator).frame(height: 1)
    }
  }

  private var workspaceRow: some View {
    Button {
      dismiss()
      onWorkspace()
    } label: {
      HStack(spacing: 13) {
        Image(systemName: "rectangle.stack")
          .font(.system(size: 18))
          .foregroundStyle(.secondary)
          .frame(width: 38, height: 38)
          .background(.quaternary, in: .rect(cornerRadius: 10))
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 1) {
          Text("Add Workspace")
            .font(.system(size: 13.5, weight: .semibold))
          Text("A shared task folder spanning multiple repos for one agent.")
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }

        Spacer()

        Image(systemName: "chevron.right")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.tertiary)
          .offset(x: isWorkspaceHovered ? 2 : 0)
          .accessibilityHidden(true)
      }
      .padding(.vertical, 13)
      .padding(.horizontal, 14)
      .background(
        .quaternary.opacity(isWorkspaceHovered ? 0.7 : 0.4),
        in: .rect(cornerRadius: 13)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 13)
          .strokeBorder(.separator, lineWidth: 0.5)
      }
      .contentShape(.rect(cornerRadius: 13))
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      withAnimation(.easeOut(duration: 0.15)) {
        isWorkspaceHovered = hovering
      }
    }
  }
}
