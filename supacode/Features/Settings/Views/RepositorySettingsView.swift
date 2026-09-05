import AppKit
import ComposableArchitecture
import Sharing
import SwiftUI

struct RepositorySettingsView: View {
  @Bindable var store: StoreOf<RepositorySettingsFeature>
  @State private var isBranchPickerPresented = false
  @State private var branchSearchText = ""
  @State private var githubIdentityViewModel = RepositoryGithubIdentityViewModel()
  @Shared(.userGlobalSettings) private var globalSettings

  var body: some View {
    let baseRefOptions =
      store.branchOptions.isEmpty ? [store.defaultWorktreeBaseRef] : store.branchOptions
    let settings = $store.settings
    let worktreeBaseDirectoryPath = Binding(
      get: { settings.worktreeBaseDirectoryPath.wrappedValue ?? "" },
      set: { settings.worktreeBaseDirectoryPath.wrappedValue = $0 },
    )
    let customTitle = Binding(
      get: { settings.customTitle.wrappedValue ?? "" },
      set: { settings.customTitle.wrappedValue = $0 },
    )
    let observeLineDiffsAutomatically = Binding(
      get: { settings.observeLineDiffsAutomatically.wrappedValue ?? true },
      set: { settings.observeLineDiffsAutomatically.wrappedValue = $0 },
    )
    let fetchPullRequestState = Binding(
      get: { settings.fetchPullRequestState.wrappedValue ?? true },
      set: { settings.fetchPullRequestState.wrappedValue = $0 },
    )
    let exampleWorktreePath = store.exampleWorktreePath
    let folderName = Repository.name(for: store.rootURL)
    @Bindable var workflowsStore = store.scope(state: \.workflows, action: \.workflows)

    NavigationStack(path: $workflowsStore.scope(state: \.path, action: \.path)) {
      Form {
        Section("Display") {
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              Text("Name")
              Spacer().frame(width: 20)
              TextField("", text: customTitle, prompt: Text(folderName))
                .frame(width: 300)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
            }
            Divider()
            RepositoryAppearancePickerView(store: store)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }

        if let workspace = store.workspace {
          Section {
            VStack(alignment: .leading, spacing: 12) {
              if !workspace.description.isEmpty {
                Text(workspace.description)
                  .foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
                  .textSelection(.enabled)
              }
              if !workspace.taskLinks.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                  ForEach(workspace.taskLinks, id: \.self) { link in
                    Text(link)
                      .font(.subheadline.monospaced())
                      .foregroundStyle(.secondary)
                      .textSelection(.enabled)
                  }
                }
              }
              WorkspaceRepositoriesGridView(workspace: workspace, rootURL: store.rootURL)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          } header: {
            Text("Workspace")
          } footer: {
            Text(
              "Read-only. Defined in "
                + "\(ProjectWorkspace.metadataURL(for: store.rootURL).path(percentEncoded: false)) "
                + "— edit that file to change it."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
          }
        }

        if store.showsWorktreeSettings {
          Section {
            if store.isBranchDataLoaded {
              Button {
                branchSearchText = ""
                isBranchPickerPresented = true
              } label: {
                HStack {
                  Text(
                    store.settings.worktreeBaseRef ?? "Automatic (\(store.defaultWorktreeBaseRef))"
                  )
                  .foregroundStyle(.primary)
                  Spacer()
                  Image(systemName: "chevron.up.chevron.down")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .popover(isPresented: $isBranchPickerPresented) {
                BranchPickerPopover(
                  searchText: $branchSearchText,
                  options: baseRefOptions,
                  automaticLabel: "Automatic (\(store.defaultWorktreeBaseRef))",
                  selection: store.settings.worktreeBaseRef,
                  onSelect: { ref in
                    store.settings.worktreeBaseRef = ref
                    isBranchPickerPresented = false
                  }
                )
              }
            } else {
              ProgressView()
                .controlSize(.small)
            }
          } header: {
            VStack(alignment: .leading, spacing: 4) {
              Text("Branch new worktrees from")
              Text("Each workspace is an isolated copy of your codebase.")
                .foregroundStyle(.secondary)
            }
          }

          Section {
            VStack(alignment: .leading) {
              TextField(
                "Inherit global default",
                text: worktreeBaseDirectoryPath
              )
              .textFieldStyle(.roundedBorder)

              Text(
                "Set a repository-specific worktree base directory. Leave empty to inherit the global setting."
              )
              .foregroundStyle(.secondary)
              Text("Example new worktree path: \(exampleWorktreePath)")
                .foregroundStyle(.secondary)
                .monospaced()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Picker(selection: settings.copyIgnoredOnWorktreeCreate) {
              Text(
                "Global \(Text(store.globalCopyIgnoredOnWorktreeCreate ? "Yes" : "No").foregroundStyle(.secondary))"
              )
              .tag(Bool?.none)
              Text("Yes").tag(Bool?.some(true))
              Text("No").tag(Bool?.some(false))
            } label: {
              Text("Copy ignored files to new worktrees")
              Text("Copies gitignored files from the main worktree.")
            }
            .disabled(store.isBareRepository)

            Picker(selection: settings.copyUntrackedOnWorktreeCreate) {
              Text(
                "Global \(Text(store.globalCopyUntrackedOnWorktreeCreate ? "Yes" : "No").foregroundStyle(.secondary))"
              )
              .tag(Bool?.none)
              Text("Yes").tag(Bool?.some(true))
              Text("No").tag(Bool?.some(false))
            } label: {
              Text("Copy untracked files to new worktrees")
              Text("Copies untracked files from the main worktree.")
            }
            .disabled(store.isBareRepository)

            if store.isBareRepository {
              Text("Copy flags are ignored for bare repositories.")
                .foregroundStyle(.secondary)
            }
          } header: {
            VStack(alignment: .leading, spacing: 4) {
              Text("Worktree")
              Text("Applies when creating a new worktree")
                .foregroundStyle(.secondary)
            }
          }
        }

        if store.showsDiffsAndPullRequestSettings {
          Section {
            if store.showsDiffSettings {
              Toggle(isOn: observeLineDiffsAutomatically) {
                Text("Observe line diffs automatically")
                Text(
                  "Keeps each workspace's line-change badge up to date in the background. "
                    + "Turn off for very large repositories to avoid background git diff work."
                )
              }
              .help(
                "Refresh workspace line-change badges automatically. "
                  + "Disable to skip background git diff for large repositories."
              )
            }

            if store.showsPullRequestSettings {
              Toggle(isOn: fetchPullRequestState) {
                Text("Fetch pull request state")
                Text(
                  "Periodically checks pull request status (open, merged, checks) for this repository's branches. "
                    + "Turn off to skip background GitHub queries."
                )
              }
              .help(
                "Fetch pull request status for this repository's branches. "
                  + "Disable to skip background GitHub queries and save API rate limit."
              )

              Picker(selection: settings.githubAccountOverride) {
                Text("Automatic").tag(GithubAccountOverride?.none)
                if let override = store.settings.githubAccountOverride,
                  !githubIdentityViewModel.accounts.contains(where: { $0.override == override })
                {
                  Text("\(override.login) @ \(override.host)")
                    .tag(GithubAccountOverride?.some(override))
                }
                ForEach(githubIdentityViewModel.accounts) { account in
                  Text("\(account.login) @ \(account.host)")
                    .tag(GithubAccountOverride?.some(account.override))
                }
              } label: {
                Text("GitHub identity")
                Text("Account Prowl switches to before running gh for this repository.")
              }
              .help("Select the gh account Prowl should use for this repository.")

              Picker(selection: settings.pullRequestMergeStrategy) {
                Text(
                  "Global \(Text(store.globalPullRequestMergeStrategy.title).foregroundStyle(.secondary))"
                )
                .tag(PullRequestMergeStrategy?.none)
                ForEach(PullRequestMergeStrategy.allCases) { strategy in
                  Text(strategy.title).tag(PullRequestMergeStrategy?.some(strategy))
                }
              } label: {
                Text("Merge strategy")
                Text("Used when merging PRs from the command palette.")
              }
            }
          } header: {
            VStack(alignment: .leading, spacing: 4) {
              Text("Diffs & Pull Requests")
              Text("Background refresh of line-change badges and pull request status")
                .foregroundStyle(.secondary)
            }
          }
        }
        Section {
          Picker(
            "Default Agent Profile",
            selection: Binding(
              get: { store.userSettings.defaultAgentProfileID },
              set: { store.send(.setDefaultAgentProfileID($0)) }
            )
          ) {
            Text("None").tag(AgentProfile.ID?.none)
            ForEach(globalSettings.agentProfiles.filter(\.isEnabled)) { profile in
              Label {
                Text(profile.name)
              } icon: {
                AgentProfileIconImage(source: profile.iconSource, pointSize: 14)
                  .frame(width: 14, height: 14)
              }
              .tag(AgentProfile.ID?.some(profile.id))
            }
          }
        } header: {
          VStack(alignment: .leading, spacing: 4) {
            Text("Agents")
            Text(
              "Recommended first in the Agents menu for this repository. "
                + "Without a designation, the last profile launched here is recommended."
            )
            .foregroundStyle(.secondary)
          }
        }

        WorkflowSettingsSections(store: workflowsStore, showsIntroduction: false)

        Section {
          ScriptEnvironmentRow(
            name: "PROWL_WORKTREE_PATH",
            description: "Path to the active worktree."
          )
          ScriptEnvironmentRow(
            name: "PROWL_ROOT_PATH",
            value: store.rootURL.path(percentEncoded: false),
            description: "Path to the repository root."
          )
        } header: {
          VStack(alignment: .leading, spacing: 4) {
            Text("Environment Variables")
            Text("Exported in all scripts below")
              .foregroundStyle(.secondary)
          }
        }

        if store.showsSetupScriptSettings {
          Section {
            PlainTextEditor(
              text: settings.setupScript,
              placeholder: "claude --dangerously-skip-permissions"
            )
            .frame(minHeight: 120)
          } header: {
            VStack(alignment: .leading, spacing: 4) {
              Text("Setup Script")
              Text("Initial setup script that will be launched once after worktree creation")
                .foregroundStyle(.secondary)
            }
          }
        }

        if store.showsArchiveScriptSettings {
          Section {
            PlainTextEditor(
              text: settings.archiveScript,
              placeholder: "docker compose down"
            )
            .frame(minHeight: 120)
          } header: {
            VStack(alignment: .leading, spacing: 4) {
              Text("Archive Script")
              Text("Archive script that runs before a worktree is archived")
                .foregroundStyle(.secondary)
            }
          }
        }

        if store.showsRunScriptSettings {
          Section {
            PlainTextEditor(
              text: settings.runScript,
              placeholder: "npm run dev"
            )
            .frame(minHeight: 120)
          } header: {
            VStack(alignment: .leading, spacing: 4) {
              Text("Run Script")
              Text("Run script launched on demand from the toolbar")
                .foregroundStyle(.secondary)
            }
          }
        }

        if store.showsCustomCommandsSettings {
          Section {
            CustomCommandsEditor(
              commands: $store.userSettings.customCommands,
              source: .repository,
              keybindingUserOverrides: store.keybindingUserOverrides,
              globalCommands: globalSettings.customCommands,
              globalCommandEnabled: { commandID in
                Binding(
                  get: { store.userSettings.isGlobalCommandEnabled(commandID) },
                  set: { isEnabled in
                    store.send(.setGlobalCommandEnabled(commandID, isEnabled))
                  }
                )
              }
            )
          } header: {
            VStack(alignment: .leading, spacing: 4) {
              Text("Custom Commands")
              Text(
                "Repository and global terminal actions. Enabled commands appear in repository order, "
                  + "then global order. Edit global commands in Settings → Commands."
              )
              .foregroundStyle(.secondary)
            }
          }
        }
      }
      .formStyle(.grouped)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .task {
        store.send(.task)
        store.send(.workflowsAppeared)
        workflowsStore.send(.task)
        await githubIdentityViewModel.load()
      }
      .alert($workflowsStore.scope(state: \.alert, action: \.alert))
      .sheet(
        isPresented: $workflowsStore.isAuthoringPromptPresented.sending(
          \.setAuthoringPromptPresented)
      ) {
        AskAgentHelpView(
          strings: workflowAuthoringPromptStrings(directory: workflowsStore.workflowDirectory)
        ) {
          workflowsStore.send(.setAuthoringPromptPresented(false))
        }
      }
    } destination: { detailStore in
      WorkflowSettingsDetailView(store: detailStore)
    }
    .onDisappear { workflowsStore.send(.teardown) }
  }
}

@MainActor @Observable
private final class RepositoryGithubIdentityViewModel {
  var accounts: [GithubAuthAccountStatus] = []

  @ObservationIgnored
  @Dependency(GithubCLIClient.self) private var githubCLI

  func load() async {
    do {
      let snapshot = try await githubCLI.authStatusSnapshot()
      accounts = snapshot.allAccounts
    } catch {
      accounts = []
    }
  }
}
