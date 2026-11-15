import ComposableArchitecture
import SwiftUI

struct WorktreeSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>

  var body: some View {
    let exampleRepositoryRoot = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "code/my-repo", directoryHint: .isDirectory)
    let exampleWorktreePath = ProwlPaths.exampleWorktreePath(
      for: exampleRepositoryRoot,
      globalDefaultPath: store.defaultWorktreeBaseDirectoryPath,
      repositoryOverridePath: nil
    )
    VStack(alignment: .leading) {
      Form {
        Section("Creation") {
          VStack(alignment: .leading) {
            TextField(
              "Default: current behavior",
              text: $store.defaultWorktreeBaseDirectoryPath
            )
            .textFieldStyle(.roundedBorder)
            Text("Default directory for new worktrees across repositories. Leave empty to keep current behavior.")
              .foregroundStyle(.secondary)
            Text("Example new worktree path: \(exampleWorktreePath)")
              .foregroundStyle(.secondary)
              .monospaced()
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          Toggle(isOn: $store.promptForWorktreeCreation) {
            Text("Prompt for branch name during creation")
            Text("When enabled, you choose the branch name and where it branches from before creating the worktree.")
          }
          .help("Ask for branch name and base ref before creating a worktree.")
          Toggle(isOn: $store.fetchRemoteBeforeWorktreeCreation) {
            Text("Fetch remote before creating worktree")
            Text("Keeps remote-tracking base branches current. Fetch failures are logged and creation continues.")
          }
          .help("Runs git fetch <remote> before creating a worktree.")
        }
        Section("Cleanup") {
          Toggle(isOn: $store.deleteBranchOnAutomaticCleanup) {
            Text("Delete local branch during automatic cleanup")
            Text(
              """
              Applies when merged or expired worktrees are cleaned up automatically, and only to branches \
              created by Prowl. The manual delete dialog remembers your last choice instead.
              """
            )
          }
          .help("Delete the local branch when automatic cleanup removes a Prowl-created worktree.")
          Picker(selection: $store.mergedWorktreeAction) {
            Text("Do nothing").tag(MergedWorktreeAction?.none)
            ForEach(MergedWorktreeAction.allCases) { action in
              Text(action.title).tag(MergedWorktreeAction?.some(action))
            }
          } label: {
            Text("When a pull request is merged")
            switch store.mergedWorktreeAction {
            case .archive:
              Text("Archives worktrees when their pull requests are merged.")
            case .delete:
              let uncommittedChangesWarning = Text("Uncommitted changes will be lost.").foregroundStyle(.red)
              Text("Deletes worktrees when their pull requests are merged. \(uncommittedChangesWarning)")
            case nil:
              EmptyView()
            }
          }
          Picker(selection: $store.displayedArchivedAutoDeletePeriod.sending(\.archivedAutoDeletePeriodSelected)) {
            Text("Never").tag(AutoDeletePeriod?.none)
            ForEach(AutoDeletePeriod.allCases) { period in
              Text(period.label).tag(AutoDeletePeriod?.some(period))
            }
          } label: {
            Text("Auto-delete archived worktrees")
            Text("Permanently removes archived worktrees after the selected period.")
          }
        }
        Section("Copy Defaults") {
          Toggle(isOn: $store.copyIgnoredOnWorktreeCreate) {
            Text("Copy ignored files to new worktrees")
            Text("Copies gitignored files from the main worktree.")
          }
          Toggle(isOn: $store.copyUntrackedOnWorktreeCreate) {
            Text("Copy untracked files to new worktrees")
            Text("Copies untracked files from the main worktree.")
          }
        }
      }
      .formStyle(.grouped)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}
