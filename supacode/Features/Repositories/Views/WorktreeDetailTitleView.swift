import SwiftUI

struct DetailToolbarAgentIdentity: Equatable {
  let agent: DetectedAgent
  let icon: TabIconSource?
  let accessibilityLabel: String
}

struct WorktreeDetailTitleView: View {
  let title: DetailToolbarTitle
  let repositoryColor: RepositoryColorChoice?
  let agentIdentity: DetailToolbarAgentIdentity?
  let isTmuxBacked: Bool
  let onSubmit: ((String) -> Void)?
  let externalRenamePrompt: PendingRenameBranchRequest?
  let onConsumeExternalRenamePrompt: (Int) -> Void
  @Environment(\.resolvedKeybindings) private var resolvedKeybindings

  @State private var isPresented = false
  @State private var isHovered = false
  @State private var draftName = ""

  var body: some View {
    Group {
      if title.supportsRename {
        Button {
          openRenamePopover()
        } label: {
          labelContent
        }
        .help(
          AppShortcuts.helpText(
            title: "Rename branch",
            commandID: AppShortcuts.CommandID.renameBranch,
            in: resolvedKeybindings
          )
        )
        .modifier(
          KeyboardShortcutModifier(
            shortcut: resolvedKeybindings.keyboardShortcut(for: AppShortcuts.CommandID.renameBranch)
          ))
      } else {
        labelContent
      }
    }
    .onHover { hovering in
      isHovered = hovering
    }
    .popover(isPresented: $isPresented) {
      RenameBranchPopover(
        draftName: $draftName,
        onCancel: { isPresented = false },
        onSubmit: { newName in
          isPresented = false
          if newName != title.text {
            onSubmit?(newName)
          }
        }
      )
    }
    .task(id: externalRenamePrompt?.id) {
      guard let prompt = externalRenamePrompt, title.supportsRename else { return }
      openRenamePopover()
      onConsumeExternalRenamePrompt(prompt.id)
    }
  }

  private func openRenamePopover() {
    draftName = title.text
    isPresented = true
  }

  private var labelContent: some View {
    HStack(spacing: horizontalSpacing) {
      Image(systemName: title.systemImage)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
        .frame(width: iconWidth, alignment: .center)
      titleText
      if let agentIdentity {
        agentIcon(agentIdentity)
      }
      if isTmuxBacked {
        Image(systemName: "checkmark")
          .foregroundStyle(.green)
          .accessibilityLabel("Tmux-backed terminal")
      }
      if title.supportsRename && isHovered {
        Image(systemName: "pencil")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
      }
    }
    .font(.headline)
    .padding(.horizontal, horizontalPadding)
  }

  @ViewBuilder
  private var titleText: some View {
    if let directoryParts {
      HStack(spacing: 0) {
        if let prefix = directoryParts.prefix {
          Text(prefix)
            .foregroundStyle(.secondary)
        }
        Text(directoryParts.name)
          .foregroundStyle(repositoryColor?.color ?? .accentColor)
          .fontWeight(.semibold)
      }
      if case .branch = title.kind {
        Text("|")
          .foregroundStyle(.tertiary)
        Text(title.text)
      }
    } else {
      Text(title.text)
    }
  }

  @ViewBuilder
  private func agentIcon(_ identity: DetailToolbarAgentIdentity) -> some View {
    Group {
      if let icon = identity.icon {
        TabIconImage(rawName: icon.storageString, pointSize: 15)
      } else {
        Image(systemName: "sparkle")
          .font(.system(size: 15))
      }
    }
    .foregroundStyle(AgentIconTint.color(for: identity.agent) ?? .primary)
    .frame(width: iconWidth, height: iconWidth)
    .accessibilityLabel(identity.accessibilityLabel)
  }

  private var directoryParts: (prefix: String?, name: String)? {
    guard let directory = title.directory else { return nil }
    let path = directory.standardizedFileURL.path(percentEncoded: false)
    guard !path.isEmpty else { return nil }
    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path(percentEncoded: false)
    let displayPath =
      if path == home {
        "~"
      } else if path.hasPrefix(home + "/") {
        "~" + path.dropFirst(home.count)
      } else {
        path
      }
    let name = directory.lastPathComponent.isEmpty ? displayPath : directory.lastPathComponent
    guard !name.isEmpty else { return nil }
    let suffix = "/\(name)"
    if displayPath.hasSuffix(suffix) {
      return (String(displayPath.dropLast(name.count)), name)
    }
    return (nil, displayPath)
  }

  private var iconWidth: CGFloat {
    16
  }

  private var horizontalSpacing: CGFloat {
    6
  }

  private var horizontalPadding: CGFloat {
    title.supportsRename ? 0 : 6
  }
}

private struct RenameBranchPopover: View {
  @Binding var draftName: String
  let onCancel: () -> Void
  let onSubmit: (String) -> Void
  @FocusState private var isFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Rename Branch")
        .font(.headline)

      TextField("Branch name", text: $draftName)
        .textFieldStyle(.roundedBorder)
        .focused($isFocused)
        .onChange(of: draftName) { _, newValue in
          let filtered = String(newValue.filter { !$0.isWhitespace })
          if filtered != newValue {
            draftName = filtered
          }
        }
        .onSubmit { submit() }
        .onExitCommand { onCancel() }

      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { onCancel() }
          .keyboardShortcut(.cancelAction)
        Button("Rename") { submit() }
          .keyboardShortcut(.defaultAction)
          .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding()
    .frame(width: 280)
    .task { isFocused = true }
  }

  private func submit() {
    let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    onSubmit(trimmed)
  }
}
