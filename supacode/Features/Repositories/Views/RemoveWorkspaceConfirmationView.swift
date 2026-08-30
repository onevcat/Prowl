import SwiftUI

struct RemoveWorkspaceConfirmationView: View {
  let confirmation: RemoveWorkspaceConfirmation
  let onDeleteFilesChanged: (Bool) -> Void
  let onDeleteBranchChanged: (String, Bool) -> Void
  let onCancel: () -> Void
  let onRemove: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Remove workspace?")
          .interfaceFont(.headline)
        Text("This removes \(confirmation.workspaceTitle) from Prowl.")
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Text(confirmation.rootPath)
          .interfaceFont(.footnote, design: .monospaced)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
      }

      Toggle(
        "Also delete the workspace folder and its worktrees",
        isOn: Binding(
          get: { confirmation.deleteFiles },
          set: { onDeleteFilesChanged($0) }
        )
      )
      .help(
        "Unregister worktrees created for this workspace from their source repositories, "
          + "then delete the workspace folder."
      )

      if !confirmation.branchOptions.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(confirmation.branchOptions) { option in
            Toggle(
              isOn: Binding(
                get: { option.isSelected },
                set: { onDeleteBranchChanged(option.id, $0) }
              )
            ) {
              HStack(spacing: 4) {
                Text("Delete branch")
                Text(option.branchName)
                  .interfaceFont(.body, design: .monospaced)
                Text("in \(option.repositoryName)")
              }
            }
            .help("Delete the branch from the source repository with git branch -D after removing the worktree.")
          }
        }
        .padding(.leading, 20)
        .disabled(!confirmation.deleteFiles)
      }

      Text("Linked repositories stay untouched; only the symlinks inside the workspace folder are removed.")
        .interfaceFont(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      HStack {
        Spacer()
        Button("Cancel", role: .cancel) {
          onCancel()
        }
        .keyboardShortcut(.cancelAction)
        .help("Cancel (Esc)")

        Button("Remove", role: .destructive) {
          onRemove()
        }
        .keyboardShortcut(.defaultAction)
        .help("Remove workspace (↩)")
      }
    }
    .padding(24)
    .frame(width: 440)
  }
}
