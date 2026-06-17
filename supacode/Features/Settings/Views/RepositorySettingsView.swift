import AppKit
import ComposableArchitecture
import SwiftUI

struct RepositorySettingsView: View {
  @Bindable var store: StoreOf<RepositorySettingsFeature>
  @State private var isBranchPickerPresented = false
  @State private var branchSearchText = ""
  @State private var githubIdentityViewModel = RepositoryGithubIdentityViewModel()

  @State var selectedCustomCommandID: UserCustomCommand.ID?
  @State var recordingCustomCommandID: UserCustomCommand.ID?
  @State var recorderMonitor: Any?
  @State var invalidMessageByCommandID: [UserCustomCommand.ID: String] = [:]
  @State var pendingShortcutConflict: CustomCommandShortcutConflict?
  @State var pendingShortcut: PendingCustomShortcut?
  @State var iconPickerCommandID: UserCustomCommand.ID?
  @State var customCommandsFocusAnchor: NSView?
  @State var popoverRefocusTask: Task<Void, Never>?
  @State var commandEditorCommandID: UserCustomCommand.ID?
  @State var editingNameCommandID: UserCustomCommand.ID?
  @FocusState var focusedNameEditorCommandID: UserCustomCommand.ID?

  let keyTokenResolver = ShortcutKeyTokenResolver()

  static let symbolPresets = [
    "terminal",
    "terminal.fill",
    "play.fill",
    "stop.fill",
    "hammer.fill",
    "shippingbox.fill",
    "doc.text.fill",
    "sparkles",
    "bolt.fill",
    "flame.fill",
    "wand.and.stars",
    "wrench.and.screwdriver.fill",
    "checkmark.circle.fill",
    "xmark.circle.fill",
    "exclamationmark.triangle.fill",
    "ladybug.fill",
    "clock.fill",
    "repeat",
    "arrow.clockwise",
    "folder.fill",
    "archivebox.fill",
    "paperplane.fill",
    "cloud.fill",
    "tray.and.arrow.down.fill",
    "tray.and.arrow.up.fill",
    "icloud.and.arrow.up.fill",
    "square.and.arrow.up.fill",
    "arrow.triangle.2.circlepath",
    "folder.badge.plus",
    "doc.badge.plus",
  ]

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

      if let workspace = store.workspace, let draft = store.workspaceDraft {
        Section {
          workspaceEditor(workspace: workspace, draft: draft)
        } header: {
          Text("Workspace")
        } footer: {
          Text(ProjectWorkspace.metadataURL(for: store.rootURL).path(percentEncoded: false))
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
          customCommandsEditor
        } header: {
          VStack(alignment: .leading, spacing: 4) {
            Text("Custom Commands")
            Text(
              "Repository-local terminal actions. Custom command shortcuts take precedence in this repository."
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
      await githubIdentityViewModel.load()
      syncSelectedCommandID(with: store.userSettings.customCommands)
    }
    .onChange(of: store.userSettings.customCommands) { _, commands in
      syncSelectedCommandID(with: commands)
      clearRemovedCommandState(using: commands)
    }
    .onChange(of: selectedCustomCommandID) { _, selectedID in
      if editingNameCommandID != selectedID {
        editingNameCommandID = nil
      }
      focusedNameEditorCommandID = nil
      if let iconPickerCommandID, iconPickerCommandID != selectedID {
        self.iconPickerCommandID = nil
      }
      if let commandEditorCommandID, commandEditorCommandID != selectedID {
        self.commandEditorCommandID = nil
      }
      if let recordingCustomCommandID, recordingCustomCommandID != selectedID {
        self.recordingCustomCommandID = nil
      }
    }
    .onChange(of: recordingCustomCommandID) { _, commandID in
      if commandID == nil {
        stopRecorderMonitor()
      } else {
        startRecorderMonitor()
      }
    }
    .onDisappear {
      stopRecorderMonitor()
      popoverRefocusTask?.cancel()
      popoverRefocusTask = nil
      focusedNameEditorCommandID = nil
    }
    .alert(
      "Shortcut Conflict",
      isPresented: isShortcutConflictAlertPresented,
      presenting: pendingShortcutConflict
    ) { _ in
      Button("Replace", role: .destructive) {
        applyPendingShortcut(replacingConflict: true)
      }
      Button("Cancel", role: .cancel) {
        clearPendingShortcutConflict()
      }
    } message: { conflict in
      Text(
        "“\(conflict.newCommandTitle)” and “\(conflict.existingCommandTitle)” both use \(conflict.shortcutDisplay)."
          + "\n\nChoose Replace to keep the new shortcut and clear the conflicting command."
      )
    }
  }

  private func workspaceEditor(
    workspace: ProjectWorkspace,
    draft: RepositorySettingsFeature.WorkspaceDraft
  ) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      labeledTextField(
        "Title",
        text: draft.title,
        action: RepositorySettingsFeature.Action.workspaceTitleChanged
      )
      labeledPlainTextEditor(
        "Description",
        text: draft.description,
        height: 54,
        action: RepositorySettingsFeature.Action.workspaceDescriptionChanged
      )
      labeledPlainTextEditor(
        "Task links",
        text: draft.taskLinksText,
        height: 54,
        action: RepositorySettingsFeature.Action.workspaceTaskLinksChanged
      )
      Divider()
      workspaceAgentGuideEditor(draft: draft)
      Divider()
      WorkspaceRepositoriesGridView(workspace: workspace, rootURL: store.rootURL)
      HStack {
        Button {
          chooseWorkspaceRepositorySource()
        } label: {
          Label("Add Local", systemImage: "folder.badge.plus")
        }
        .help("Add a local repository to this workspace")

        Button {
          store.send(.workspaceAddRemoteRepository(name: "Remote Repository", url: ""))
        } label: {
          Label("Add Remote", systemImage: "network")
        }
        .help("Add a remote repository to this workspace")
      }
      ForEach(draft.repositories) { repository in
        workspaceRepositoryEditor(repository)
      }
      if let error = store.workspaceSaveError {
        Text(error)
          .font(.footnote)
          .foregroundStyle(.red)
          .textSelection(.enabled)
      } else if let status = store.workspaceSaveStatus {
        Text(status)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      HStack {
        Button {
          store.send(.saveWorkspaceMetadataButtonTapped)
        } label: {
          Label("Save Workspace", systemImage: "square.and.arrow.down")
        }
        .disabled(!store.canSaveWorkspaceDraft)
        .help("Save workspace metadata")

        Button {
          store.send(.regenerateWorkspaceGuideButtonTapped)
        } label: {
          Label("Regenerate Guide", systemImage: "arrow.clockwise")
        }
        .disabled(!draft.agentGuideEnabled)
        .help("Regenerate workspace agent guide")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func workspaceAgentGuideEditor(
    draft: RepositorySettingsFeature.WorkspaceDraft
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Toggle(
        "Generate agent guide",
        isOn: Binding(
          get: { draft.agentGuideEnabled },
          set: { store.send(.workspaceAgentGuideEnabledChanged($0)) }
        )
      )
      .help("Generate managed workspace instructions such as AGENTS.md")
      labeledPlainTextEditor(
        "Outputs",
        text: draft.agentGuideOutputsText,
        height: 42,
        action: RepositorySettingsFeature.Action.workspaceAgentGuideOutputsChanged
      )
      Toggle(
        "Reference child instruction files",
        isOn: Binding(
          get: { draft.includeChildInstructionFiles },
          set: { store.send(.workspaceChildInstructionsChanged($0)) }
        )
      )
      .help("List child AGENTS.md, CLAUDE.md, Cursor rules, and Copilot instructions when present")
      labeledPlainTextEditor(
        "Guide notes",
        text: draft.agentGuideExtraNotes,
        height: 64,
        action: RepositorySettingsFeature.Action.workspaceAgentGuideExtraNotesChanged
      )
    }
  }

  private func workspaceRepositoryEditor(
    _ repository: RepositorySettingsFeature.RepositoryDraft
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(repository.name.isEmpty ? "Repository" : repository.name)
          .font(.headline)
          .strikethrough(repository.isRemoved)
        if repository.isNew {
          Text("New")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if repository.isRemoved {
          Button {
            store.send(.workspaceRestoreRepository(id: repository.id))
          } label: {
            Image(systemName: "arrow.uturn.backward")
              .accessibilityLabel("Restore Repository")
          }
          .buttonStyle(.borderless)
          .help("Keep this repository in the workspace")
        } else {
          Button {
            store.send(.workspaceRemoveRepository(id: repository.id))
          } label: {
            Image(systemName: "trash")
              .accessibilityLabel("Remove Repository")
          }
          .buttonStyle(.borderless)
          .disabled(store.activeWorkspaceRepositoryCount <= 2)
          .help("Remove repository from this workspace")
        }
      }
      labeledTextField(
        "Role",
        text: repository.role,
        action: { .workspaceRepositoryRoleChanged(id: repository.id, $0) }
      )
      if repository.isNew {
        workspaceNewRepositoryMaterializationEditor(repository)
      } else {
        workspaceRepositoryMaterializationSummary(repository)
      }
      labeledPlainTextEditor(
        "Agent notes",
        text: repository.agentNotes,
        height: 54,
        action: { .workspaceRepositoryAgentNotesChanged(id: repository.id, $0) }
      )
      labeledTextField(
        "Bootstrap profile",
        text: repository.bootstrapScriptID,
        action: { .workspaceBootstrapIDChanged(id: repository.id, $0) }
      )
      HStack {
        Toggle(
          "Create",
          isOn: Binding(
            get: { repository.bootstrapRunOnCreate },
            set: {
              store.send(.workspaceBootstrapCreateChanged(id: repository.id, $0))
            }
          )
        )
        Toggle(
          "On add",
          isOn: Binding(
            get: { repository.bootstrapRunOnAdd },
            set: { store.send(.workspaceBootstrapOnAddChanged(id: repository.id, $0)) }
          )
        )
        Toggle(
          "Manual",
          isOn: Binding(
            get: { repository.bootstrapRunOnManual },
            set: { store.send(.workspaceBootstrapManualChanged(id: repository.id, $0)) }
          )
        )
        Toggle(
          "Required",
          isOn: Binding(
            get: { repository.bootstrapRequired },
            set: { store.send(.workspaceBootstrapRequiredChanged(id: repository.id, $0)) }
          )
        )
      }
      .help("Choose when this repository's workspace bootstrap profile runs")
      Button {
        store.send(.runWorkspaceBootstrapButtonTapped(id: repository.id))
      } label: {
        Label("Run Bootstrap", systemImage: "play")
      }
      .disabled(
        repository.isNew || repository.isRemoved
          || repository.bootstrapScriptID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      )
      .help("Run this repository's bootstrap profile now")
    }
    .opacity(repository.isRemoved ? 0.55 : 1)
    .padding(.top, 6)
  }

  private func workspaceNewRepositoryMaterializationEditor(
    _ repository: RepositorySettingsFeature.RepositoryDraft
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      labeledTextField(
        "Name",
        text: repository.name,
        action: { .workspaceRepositoryNameChanged(id: repository.id, $0) }
      )
      labeledTextField(
        "Folder",
        text: repository.path,
        action: { .workspaceRepositoryPathChanged(id: repository.id, $0) }
      )
      labeledTextField(
        repository.sourceKind == .remote ? "Remote URL" : "Source",
        text: repository.sourceLocation,
        action: { .workspaceRepositorySourceChosen(id: repository.id, $0) }
      )
      Button {
        store.send(.workspaceLoadBaseRefsTapped(id: repository.id))
      } label: {
        Label("Load Branches", systemImage: "arrow.clockwise")
      }
      .disabled(repository.sourceLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      .help("Load available branches for this repository")
      HStack(spacing: 8) {
        Picker(
          "Branch action",
          selection: Binding(
            get: { repository.checkoutMode },
            set: { store.send(.workspaceRepositoryCheckoutModeChanged(id: repository.id, $0)) }
          )
        ) {
          if repository.sourceKind.supportsLinkCheckout {
            Text("Link").tag(ProjectWorkspaceRepositoryCheckoutMode.link)
          }
          Text("Create Branch").tag(ProjectWorkspaceRepositoryCheckoutMode.createBranch)
          Text("Use Existing").tag(ProjectWorkspaceRepositoryCheckoutMode.useExistingRef)
        }
        .pickerStyle(.menu)
        .frame(width: 150)

        if repository.checkoutMode == .createBranch {
          TextField(
            "Branch",
            text: Binding(
              get: { repository.branchName },
              set: { store.send(.workspaceRepositoryBranchNameChanged(id: repository.id, $0)) }
            )
          )
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: 180)
        }

        if repository.checkoutMode != .link {
          WorkspaceSettingsBranchRefMenu(
            selection: repository.baseRef,
            options: repository.baseRefOptions
          ) { ref in
            store.send(.workspaceRepositoryBaseRefChanged(id: repository.id, ref))
          }
          if repository.baseRefOptions.isEmpty {
            Text("Load branches before saving.")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  private func workspaceRepositoryMaterializationSummary(
    _ repository: RepositorySettingsFeature.RepositoryDraft
  ) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text("Path: \(repository.path)")
      Text("Source: \(repository.sourceKind.rawValue)")
      if !repository.sourceLocation.isEmpty {
        Text(repository.sourceLocation)
          .lineLimit(1)
          .truncationMode(.middle)
      }
    }
    .font(.footnote.monospaced())
    .foregroundStyle(.secondary)
    .textSelection(.enabled)
  }

  private func labeledTextField(
    _ title: String,
    text: String,
    action: @escaping (String) -> RepositorySettingsFeature.Action
  ) -> some View {
    HStack {
      Text(title)
        .frame(width: 120, alignment: .leading)
      TextField("", text: Binding(get: { text }, set: { store.send(action($0)) }))
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 420)
    }
  }

  private func labeledPlainTextEditor(
    _ title: String,
    text: String,
    height: CGFloat,
    action: @escaping (String) -> RepositorySettingsFeature.Action
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.subheadline)
      PlainTextEditor(
        text: Binding(get: { text }, set: { store.send(action($0)) })
      )
      .frame(maxWidth: 520, minHeight: height)
    }
  }

  private func chooseWorkspaceRepositorySource() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Add"
    panel.message = "Choose a repository folder"
    panel.begin { response in
      guard response == .OK, let url = panel.url else {
        return
      }
      store.send(.workspaceAddLocalRepository(url.path(percentEncoded: false)))
    }
  }
}

private struct WorkspaceSettingsBranchRefMenu: View {
  let selection: String
  let options: [GitBranchRefOption]
  let onSelect: (String) -> Void

  var body: some View {
    Menu {
      ForEach(options) { option in
        Button {
          onSelect(option.ref)
        } label: {
          if option.ref == selection {
            Label(option.ref, systemImage: "checkmark")
          } else {
            Text(option.ref)
          }
        }
      }
    } label: {
      Text(selection.isEmpty ? "Branch/ref" : selection)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: 220, alignment: .leading)
    }
    .disabled(options.isEmpty)
    .help("Choose branch or ref")
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
