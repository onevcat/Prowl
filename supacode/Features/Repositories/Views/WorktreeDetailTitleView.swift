import SwiftUI

struct WorktreeDetailTitleView: View {
  let title: DetailToolbarTitle
  let onSubmit: ((String) -> Void)?
  let externalRenamePrompt: PendingRenameBranchRequest?
  let onConsumeExternalRenamePrompt: (Int) -> Void
  @Environment(\.resolvedKeybindings) private var resolvedKeybindings
  @Environment(\.interfaceTextScale) private var interfaceTextScale

  @State private var isPresented = false
  @State private var isHovered = false
  @State private var draftName = ""

  var body: some View {
    titleButton
      // The item opts out of the navigation group's shared glass background
      // (`sharedBackgroundVisibility(.hidden)` at the toolbar site) so the
      // Agents pair can render as one system split control in that group,
      // and draws its own capsule instead. Hover feedback must live in the
      // glass material itself: translucent fills layered under `glassEffect`
      // are swallowed by material compositing (docs-ai 049).
      .buttonStyle(.plain)
      .glassEffect(titleGlass, in: Capsule())
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

  @ViewBuilder
  private var titleButton: some View {
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
      // Button wrapper gives folder/workspace the same toolbar padding as the branch button.
      Button {
      } label: {
        labelContent
      }
    }
  }

  private func openRenamePopover() {
    draftName = title.text
    isPresented = true
  }

  /// Interactive glass (press feedback, hover tint) only when the title is a
  /// real rename button; the folder/workspace variant stays a static pill.
  private var titleGlass: Glass {
    guard title.supportsRename else { return .regular }
    return isHovered
      ? .regular.tint(.primary.opacity(0.12)).interactive()
      : .regular.interactive()
  }

  private var labelContent: some View {
    HStack(spacing: 6) {
      Image(systemName: (title.supportsRename && isHovered) ? "pencil" : title.systemImage)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
        .frame(width: 20 * interfaceTextScale, height: 20 * interfaceTextScale)
      Text(title.text)
    }
    .interfaceFont(.title3, weight: .medium)
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .contentShape(Capsule())
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
        .interfaceFont(.headline)

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
