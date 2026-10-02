import SwiftUI

struct RenameBranchPromptView: View {
  let currentName: String
  let onCancel: () -> Void
  let onSubmit: (String) -> Void

  @State private var draftName: String
  @FocusState private var isFocused: Bool

  init(
    currentName: String,
    onCancel: @escaping () -> Void,
    onSubmit: @escaping (String) -> Void
  ) {
    self.currentName = currentName
    self.onCancel = onCancel
    self.onSubmit = onSubmit
    _draftName = State(initialValue: currentName)
  }

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
          .help("Cancel (Esc)")
        Button("Rename") { submit() }
          .keyboardShortcut(.defaultAction)
          .help("Rename (↩)")
          .disabled(trimmedDraftName.isEmpty)
      }
    }
    .padding()
    .frame(width: 280)
    .task { isFocused = true }
  }

  private var trimmedDraftName: String {
    draftName.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func submit() {
    guard !trimmedDraftName.isEmpty else { return }
    guard trimmedDraftName != currentName else {
      onCancel()
      return
    }
    onSubmit(trimmedDraftName)
  }
}
