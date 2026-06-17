import SwiftUI

struct WorktreeDetailTitleView: View {
  let title: DetailToolbarTitle
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
    HStack(spacing: 6) {
      Image(systemName: (title.supportsRename && isHovered) ? "pencil" : title.systemImage)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
        .frame(width: 18, height: 18)
      Text(title.text)
    }
    .font(.headline)
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
