import SwiftUI

struct DeleteWorktreeConfirmationView: View {
  let confirmation: DeleteWorktreeConfirmation
  let onDeleteBranchChanged: (Bool) -> Void
  let onCancel: () -> Void
  let onDelete: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text(confirmation.title)
          .interfaceFont(.headline)
        Text(confirmation.message)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Toggle(
        "Also delete local branch",
        isOn: Binding(
          get: { confirmation.deleteBranch },
          set: { onDeleteBranchChanged($0) }
        )
      )
      .help("Try to delete the local branch with git branch -d after removing the worktree.")

      Text(
        "Protected branches are kept. If safe branch deletion fails, Prowl asks before forcing it. "
          + "Your choice is remembered for the next delete."
      )
      .interfaceFont(.footnote)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      HStack {
        Spacer()
        Button("Cancel", role: .cancel) {
          onCancel()
        }
        .keyboardShortcut(.cancelAction)
        .help("Cancel")

        Button("Delete", role: .destructive) {
          onDelete()
        }
        .keyboardShortcut(.defaultAction)
        .help("Delete worktree")
      }
    }
    .padding(24)
    .frame(width: 420)
  }
}
