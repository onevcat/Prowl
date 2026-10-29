import SwiftUI

/// Asks for the title of a new or renamed sidebar group (docs-ai 086).
struct GroupTitlePromptView: View {
  let isRename: Bool
  let onCancel: () -> Void
  let onSubmit: (String) -> Void

  @State private var draftTitle: String
  @FocusState private var isFocused: Bool

  init(
    prompt: GroupTitlePrompt,
    onCancel: @escaping () -> Void,
    onSubmit: @escaping (String) -> Void
  ) {
    if case .rename = prompt.target {
      isRename = true
    } else {
      isRename = false
    }
    self.onCancel = onCancel
    self.onSubmit = onSubmit
    _draftTitle = State(initialValue: prompt.currentTitle)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(isRename ? "Rename Group" : "New Group")
        .font(.headline)

      TextField("Group name", text: $draftTitle)
        .textFieldStyle(.roundedBorder)
        .focused($isFocused)
        .onSubmit { submit() }
        .onExitCommand { onCancel() }

      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { onCancel() }
          .keyboardShortcut(.cancelAction)
          .help("Cancel (Esc)")
        Button(isRename ? "Rename" : "Create") { submit() }
          .keyboardShortcut(.defaultAction)
          .help(isRename ? "Rename (↩)" : "Create (↩)")
          .disabled(RepositoryGroup.normalizedTitle(draftTitle) == nil)
      }
    }
    .padding()
    .frame(width: 280)
    .task { isFocused = true }
  }

  private func submit() {
    guard RepositoryGroup.normalizedTitle(draftTitle) != nil else { return }
    onSubmit(draftTitle)
  }
}
