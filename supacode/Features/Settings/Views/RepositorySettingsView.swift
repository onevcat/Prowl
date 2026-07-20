import AppKit
import ComposableArchitecture
import Sharing
import SwiftUI

struct RepositorySettingsView: View {
  @Bindable var store: StoreOf<RepositorySettingsFeature>
  @Shared(.scriptProfiles) var scriptProfiles
  @State private var isBranchPickerPresented = false
  @State private var branchSearchText = ""
  @State private var githubIdentityViewModel = RepositoryGithubIdentityViewModel()
  @State private var isAddWorkspaceRepositorySheetPresented = false
  @State private var pendingWorkspaceRepositoryID: String?
  @State private var isCommittingAddWorkspaceRepositorySheet = false

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
          repositoryScriptSourceEditor(
            inlineScript: settings.setupScript,
            profileID: settings.setupScriptProfileID,
            placeholder: "claude --dangerously-skip-permissions"
          )
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
          repositoryScriptSourceEditor(
            inlineScript: settings.archiveScript,
            profileID: settings.archiveScriptProfileID,
            placeholder: "docker compose down"
          )
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
          repositoryScriptSourceEditor(
            inlineScript: settings.runScript,
            profileID: settings.runScriptProfileID,
            placeholder: "npm run dev"
          )
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
    .sheet(isPresented: $isAddWorkspaceRepositorySheetPresented) {
      addWorkspaceRepositorySheet
    }
    .sheet(
      item: Binding(
        get: { store.workspaceRepositoryRemovalConfirmation },
        set: { if $0 == nil { store.send(.workspaceRepositoryRemovalCanceled) } }
      )
    ) { confirmation in
      WorkspaceRepoRemovalConfirmationView(
        confirmation: confirmation,
        onDeleteBranchChanged: { store.send(.workspaceRemovalDeleteBranchChanged($0)) },
        onCancel: { store.send(.workspaceRepositoryRemovalCanceled) },
        onRemove: { store.send(.workspaceRepositoryRemovalConfirmed) }
      )
    }
    .onChange(of: isAddWorkspaceRepositorySheetPresented) { _, isPresented in
      if !isPresented {
        handleAddWorkspaceRepositorySheetDismissed()
      }
    }
  }

  private func workspaceEditor(
    workspace _: ProjectWorkspace,
    draft: RepositorySettingsFeature.WorkspaceDraft
  ) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      workspaceMetadataEditor(draft: draft)
      workspaceRepositoriesEditor(draft: draft)
      workspaceAgentGuideEditor(draft: draft)
      workspaceStatusView
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func repositoryScriptSourceEditor(
    inlineScript: Binding<String>,
    profileID: Binding<String?>,
    placeholder: String
  ) -> some View {
    let usesProfile = Binding<Bool>(
      get: { profileID.wrappedValue != nil },
      set: { useProfile in
        if useProfile {
          profileID.wrappedValue = profileID.wrappedValue ?? scriptProfiles.first?.id ?? ""
        } else {
          profileID.wrappedValue = nil
        }
      }
    )

    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 12) {
        Text("Source")
          .foregroundStyle(.secondary)
          .frame(width: 108, alignment: .leading)

        Picker("Source", selection: usesProfile) {
          Text("Inline Script").tag(false)
          Text("Script Profile").tag(true)
        }
        .pickerStyle(.segmented)
        .frame(width: 260)
      }

      if usesProfile.wrappedValue {
        LabeledContent("Profile") {
          Picker("Profile", selection: profileID) {
            Text("Missing Profile").tag(String?.none)
            ForEach(scriptProfiles) { profile in
              Text(scriptProfileTitle(profile)).tag(String?.some(profile.id))
            }
          }
          .labelsHidden()
          .frame(maxWidth: 320)
        }
        .labelStyle(.titleOnly)

        if let profile = scriptProfiles.first(where: { $0.id == profileID.wrappedValue }) {
          scriptProfilePreview(profile)
        } else {
          ContentUnavailableView(
            "No Script Profile Selected",
            systemImage: "terminal",
            description: Text("Create or select a script profile in Settings → Scripts.")
          )
          .frame(minHeight: 120)
        }
      } else {
        PlainTextEditor(
          text: inlineScript,
          placeholder: placeholder
        )
        .frame(minHeight: 120)
      }
    }
  }

  func scriptProfilePreview(_ profile: ScriptProfile) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(profile.command)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .textSelection(.enabled)
      Text(profile.script.isEmpty ? "Empty script" : profile.script)
        .font(.caption.monospaced())
        .foregroundStyle(profile.script.isEmpty ? .tertiary : .secondary)
        .lineLimit(6)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }
  }

  func scriptProfileTitle(_ profile: ScriptProfile) -> String {
    if profile.name.isEmpty || profile.name == profile.id {
      return profile.id
    }
    return "\(profile.name) (\(profile.id))"
  }

  private func workspaceMetadataEditor(
    draft: RepositorySettingsFeature.WorkspaceDraft
  ) -> some View {
    settingsCard {
      settingsRow("Folder", alignment: .top) {
        VStack(alignment: .leading, spacing: 2) {
          Text(store.rootURL.lastPathComponent)
            .foregroundStyle(.primary)
          Text(store.rootURL.path(percentEncoded: false))
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
        }
      }

      Divider()

      settingsRow("Description", alignment: .top) {
        PlainTextEditor(
          text: Binding(
            get: { draft.description },
            set: { store.send(.workspaceDescriptionChanged($0)) }
          )
        )
        .frame(maxWidth: 520, minHeight: 54)
      }

      Divider()

      settingsRow("Task links", alignment: .top) {
        PlainTextEditor(
          text: Binding(
            get: { draft.taskLinksText },
            set: { store.send(.workspaceTaskLinksChanged($0)) }
          )
        )
        .frame(maxWidth: 520, minHeight: 54)
      }
    }
  }

  private func workspaceRepositoriesEditor(
    draft: RepositorySettingsFeature.WorkspaceDraft
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Repositories")
          .font(.headline)
        Spacer()
        Menu {
          Button {
            chooseInitialLocalWorkspaceRepositorySource(from: draft)
          } label: {
            Label("Local Repository", systemImage: "folder")
          }

          Button {
            beginAddingRemoteWorkspaceRepository(from: draft)
          } label: {
            Label("Remote Repository", systemImage: "network")
          }
        } label: {
          Label("Add Repository", systemImage: "plus")
        }
        .help("Add a child repository to this workspace")
      }
      ForEach(draft.repositories.filter { $0.id != pendingWorkspaceRepositoryID }) { repository in
        workspaceRepositoryEditor(repository)
      }
    }
  }

  private func workspaceAgentGuideEditor(
    draft: RepositorySettingsFeature.WorkspaceDraft
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Agent Guide")
            .font(.headline)
          Text("Updates managed workspace instructions from repository metadata.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          store.send(.regenerateWorkspaceGuideButtonTapped)
        } label: {
          Label("Update Guide", systemImage: "arrow.clockwise")
        }
        .help("Update managed workspace guide files now")
      }

      settingsCard {
        settingsRow("Output files", alignment: .top) {
          PlainTextEditor(
            text: Binding(
              get: { draft.agentGuideOutputsText },
              set: { store.send(.workspaceAgentGuideOutputsChanged($0)) }
            )
          )
          .frame(maxWidth: 420, minHeight: 42)
        }

        Divider()

        settingsRow("Child instructions") {
          Toggle(
            "Reference child instruction files",
            isOn: Binding(
              get: { draft.includeChildInstructionFiles },
              set: { store.send(.workspaceChildInstructionsChanged($0)) }
            )
          )
          .toggleStyle(.switch)
          .help("List child AGENTS.md, CLAUDE.md, Cursor rules, and Copilot instructions when present")
        }

        Divider()

        settingsRow("Guide notes", alignment: .top) {
          PlainTextEditor(
            text: Binding(
              get: { draft.agentGuideExtraNotes },
              set: { store.send(.workspaceAgentGuideExtraNotesChanged($0)) }
            )
          )
          .frame(maxWidth: 520, minHeight: 64)
        }
      }
    }
  }

  private func workspaceRepositoryEditor(
    _ repository: RepositorySettingsFeature.RepositoryDraft
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Text(repository.name.isEmpty ? "Repository" : repository.name)
          .font(.headline)
          .strikethrough(repository.isRemoved)
        Text(repository.sourceKind.rawValue)
          .font(.caption)
          .foregroundStyle(.secondary)
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
            store.send(.requestWorkspaceRepositoryRemoval(id: repository.id))
          } label: {
            Image(systemName: "trash")
              .accessibilityLabel("Remove Repository")
          }
          .buttonStyle(.borderless)
          .disabled(store.activeWorkspaceRepositoryCount <= 2)
          .help("Remove repository from this workspace")
        }
      }

      if repository.isNew {
        workspaceNewRepositoryMaterializationEditor(repository)
      } else {
        workspaceRepositoryMaterializationSummary(repository)
      }

      DisclosureGroup("Guide metadata") {
        VStack(alignment: .leading, spacing: 8) {
          settingsRow("Role") {
            TextField(
              "Optional guide role",
              text: Binding(
                get: { repository.role },
                set: { store.send(.workspaceRepositoryRoleChanged(id: repository.id, $0)) }
              )
            )
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 420)
          }

          settingsRow("Agent notes", alignment: .top) {
            PlainTextEditor(
              text: Binding(
                get: { repository.agentNotes },
                set: { store.send(.workspaceRepositoryAgentNotesChanged(id: repository.id, $0)) }
              )
            )
            .frame(maxWidth: 520, minHeight: 54)
          }
        }
        .padding(.top, 8)
      }
      .font(.subheadline)

      if repository.isNew {
        workspaceBootstrapConfigurationEditor(repository)
      } else if !repository.bootstrapScriptIDs.isEmpty {
        workspaceBootstrapRuntimeView(repository)
      }
    }
    .opacity(repository.isRemoved ? 0.55 : 1)
    .padding(14)
    .background(
      Color(nsColor: .separatorColor).opacity(0.08),
      in: RoundedRectangle(cornerRadius: 14, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 1)
    }
  }

  private func workspaceBootstrapConfigurationEditor(
    _ repository: RepositorySettingsFeature.RepositoryDraft
  ) -> some View {
    let selectedProfileIDs = repository.bootstrapScriptIDs
    let hasProfile = !selectedProfileIDs.isEmpty
    let disablesBootstrap = repository.usesLinkCheckout
    let availableProfiles = scriptProfiles.filter { !selectedProfileIDs.contains($0.id) }
    return VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Bootstrap Scripts")
          .font(.subheadline)
          .fontWeight(.semibold)
        Spacer()
        Menu {
          if availableProfiles.isEmpty {
            Text(scriptProfiles.isEmpty ? "No script profiles" : "All profiles selected")
          } else {
            ForEach(availableProfiles) { profile in
              Button(bootstrapProfileTitle(profile)) {
                store.send(.workspaceBootstrapProfileAdded(id: repository.id, profile.id))
              }
            }
          }
        } label: {
          Label("Add Script", systemImage: "plus")
        }
        .disabled(scriptProfiles.isEmpty || repository.isRemoved || disablesBootstrap)
        .help("Add an initialization script profile")
      }

      if hasProfile {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(Array(selectedProfileIDs.enumerated()), id: \.element) { index, profileID in
            workspaceBootstrapProfileRow(
              profileID: profileID,
              index: index,
              count: selectedProfileIDs.count,
              repository: repository
            )
          }
        }
      } else {
        Text(
          disablesBootstrap
            ? "Bootstrap scripts are disabled for linked repositories."
            : "No bootstrap scripts configured."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }

  private func workspaceBootstrapProfileRow(
    profileID: String,
    index: Int,
    count: Int,
    repository: RepositorySettingsFeature.RepositoryDraft
  ) -> some View {
    return HStack(spacing: 8) {
      Text(bootstrapProfileTitle(id: profileID))
        .lineLimit(1)
      Spacer()
      Button {
        store.send(.workspaceBootstrapProfileMoved(id: repository.id, profileID, .earlier))
      } label: {
        Image(systemName: "chevron.up")
          .accessibilityLabel("Move earlier")
      }
      .buttonStyle(.borderless)
      .disabled(index == 0 || repository.isRemoved)
      .help("Move earlier")
      Button {
        store.send(.workspaceBootstrapProfileMoved(id: repository.id, profileID, .later))
      } label: {
        Image(systemName: "chevron.down")
          .accessibilityLabel("Move later")
      }
      .buttonStyle(.borderless)
      .disabled(index == count - 1 || repository.isRemoved)
      .help("Move later")
      Button {
        store.send(.workspaceBootstrapProfileRemoved(id: repository.id, profileID))
      } label: {
        Image(systemName: "xmark")
          .accessibilityLabel("Remove")
      }
      .buttonStyle(.borderless)
      .disabled(repository.isRemoved)
      .help("Remove initialization script")
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
  }

  private func workspaceBootstrapRuntimeView(
    _ repository: RepositorySettingsFeature.RepositoryDraft
  ) -> some View {
    let runtime = store.workspaceBootstrapRuntime.state.repositories[repository.id]
    let logURL = store.workspaceBootstrapRuntime.logURLsByRepositoryID[repository.id]
    return VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Text("Bootstrap")
          .font(.subheadline)
          .fontWeight(.semibold)
        if let runtime {
          Label(
            runtime.lastStatus == .succeeded ? "Succeeded" : "Failed",
            systemImage: runtime.lastStatus == .succeeded
              ? "checkmark.circle.fill"
              : "xmark.circle.fill"
          )
          .font(.caption)
          Text(runtime.lastRunAt.formatted(date: .abbreviated, time: .shortened))
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Label("Never run", systemImage: "clock")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if logURL != nil {
          Button {
            store.send(.openWorkspaceBootstrapLogButtonTapped(id: repository.id))
          } label: {
            Label("View Log", systemImage: "doc.text.magnifyingglass")
          }
          .controlSize(.small)
          .help("Open the latest bootstrap log")
        }
      }

      if let runtime, !runtime.lastScriptIDs.isEmpty {
        Text(runtime.lastScriptIDs.joined(separator: ", "))
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }

      VStack(alignment: .leading, spacing: 6) {
        ForEach(repository.bootstrapScriptIDs, id: \.self) { profileID in
          workspaceBootstrapRuntimeProfileRow(profileID: profileID, repository: repository)
        }
      }
    }
  }

  private func workspaceBootstrapRuntimeProfileRow(
    profileID: String,
    repository: RepositorySettingsFeature.RepositoryDraft
  ) -> some View {
    let profile = scriptProfiles.first { $0.id == profileID }
    let title = profile.map { bootstrapProfileTitle($0) } ?? profileID
    let runID = RepositorySettingsFeature.workspaceBootstrapRunID(
      repositoryID: repository.id,
      scriptID: profileID
    )
    let isRunning = store.runningWorkspaceBootstrapIDs.contains(runID)
    let runDisabled =
      profile == nil
      || repository.isRemoved
      || repository.usesLinkCheckout
      || isRunning
    return HStack(spacing: 8) {
      Image(systemName: profile == nil ? "exclamationmark.triangle" : "terminal")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .lineLimit(1)
        if profile == nil {
          Text("Missing Profile")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if title != profileID {
          Text(profileID)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      }
      Spacer()
      Button {
        store.send(.runWorkspaceBootstrapProfileButtonTapped(id: repository.id, scriptID: profileID))
      } label: {
        if isRunning {
          Label {
            Text("Running")
          } icon: {
            ProgressView()
              .controlSize(.small)
          }
        } else {
          Label("Run", systemImage: "play.fill")
        }
      }
      .frame(width: 84)
      .disabled(runDisabled)
      .help(workspaceBootstrapRunHelp(profileID: profileID, title: title, repository: repository))
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
  }

  private func workspaceBootstrapRunHelp(
    profileID: String,
    title: String,
    repository: RepositorySettingsFeature.RepositoryDraft
  ) -> String {
    if scriptProfiles.contains(where: { $0.id == profileID }) == false {
      return "Restore this profile in Settings > Scripts before running it"
    }
    if repository.usesLinkCheckout {
      return "Linked repositories cannot run bootstrap scripts"
    }
    return "Run \(title) in \(repository.name)"
  }

  private func bootstrapProfileTitle(_ profile: ScriptProfile) -> String {
    if profile.name.isEmpty || profile.name == profile.id {
      return profile.id
    }
    return "\(profile.name) (\(profile.id))"
  }

  private func bootstrapProfileTitle(id: String) -> String {
    if let profile = scriptProfiles.first(where: { $0.id == id }) {
      return bootstrapProfileTitle(profile)
    }
    return id
  }

  private var workspaceStatusView: some View {
    Group {
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
    }
  }

  private var addWorkspaceRepositorySheet: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("Add Repository")
          .font(.headline)
        Spacer()
      }

      if let repository = pendingWorkspaceRepository {
        settingsCard {
          workspaceNewRepositoryMaterializationEditor(repository)
        }

        settingsCard {
          DisclosureGroup("Guide metadata") {
            VStack(alignment: .leading, spacing: 8) {
              settingsRow("Role") {
                TextField(
                  "Optional guide role",
                  text: Binding(
                    get: { repository.role },
                    set: { store.send(.workspaceRepositoryRoleChanged(id: repository.id, $0)) }
                  )
                )
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 420)
              }

              settingsRow("Agent notes", alignment: .top) {
                PlainTextEditor(
                  text: Binding(
                    get: { repository.agentNotes },
                    set: { store.send(.workspaceRepositoryAgentNotesChanged(id: repository.id, $0)) }
                  )
                )
                .frame(maxWidth: 520, minHeight: 54)
              }
            }
            .padding(.top, 8)
          }
        }

        settingsCard {
          workspaceBootstrapConfigurationEditor(repository)
        }
      } else {
        Text("No repository is being added.")
          .foregroundStyle(.secondary)
      }

      HStack {
        Spacer()
        Button("Cancel") {
          cancelAddWorkspaceRepositorySheet()
        }
        .keyboardShortcut(.cancelAction)

        Button("Add Repository") {
          saveAndCloseAddWorkspaceRepositorySheet()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!canSubmitAddWorkspaceRepositorySheet)
      }
    }
    .padding(20)
    .frame(width: 760)
  }

  private func workspaceNewRepositoryMaterializationEditor(
    _ repository: RepositorySettingsFeature.RepositoryDraft
  ) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          settingsFieldLabel("Name")
          TextField(
            "Repository name",
            text: Binding(
              get: { repository.name },
              set: { store.send(.workspaceRepositoryNameChanged(id: repository.id, $0)) }
            )
          )
          .textFieldStyle(.roundedBorder)
        }

        VStack(alignment: .leading, spacing: 4) {
          settingsFieldLabel("Folder inside workspace")
          TextField(
            "Folder name",
            text: Binding(
              get: { repository.path },
              set: { store.send(.workspaceRepositoryPathChanged(id: repository.id, $0)) }
            )
          )
          .textFieldStyle(.roundedBorder)
        }
      }

      HStack(spacing: 8) {
        TextField(
          repository.sourceKind == .remote ? "Remote URL" : "Repository source path",
          text: Binding(
            get: { repository.sourceLocation },
            set: { store.send(.workspaceRepositorySourceChosen(id: repository.id, $0)) }
          )
        )
        .textFieldStyle(.roundedBorder)
        .font(.body.monospaced())

        if repository.sourceKind != .remote {
          Button {
            chooseWorkspaceRepositorySource(for: repository.id)
          } label: {
            Image(systemName: "folder")
              .accessibilityLabel("Choose Repository Source")
          }
          .help("Choose Repository Source")
        }
      }

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
        .labelsHidden()
        .frame(width: 170)

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

        Spacer()

        Button {
          store.send(.workspaceLoadBaseRefsTapped(id: repository.id))
        } label: {
          Label("Load Branches", systemImage: "arrow.clockwise")
        }
        .disabled(repository.sourceLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .help("Load available branches for this repository")
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

  private func settingsCard<Content: View>(
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      content()
    }
    .padding(14)
    .background(
      Color(nsColor: .controlBackgroundColor),
      in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
    }
  }

  private func settingsRow<Content: View>(
    _ title: String,
    alignment: VerticalAlignment = .center,
    @ViewBuilder content: () -> Content
  ) -> some View {
    HStack(alignment: alignment, spacing: 12) {
      Text(title)
        .frame(width: 140, alignment: .leading)
        .foregroundStyle(.secondary)
      content()
    }
  }

  private func settingsFieldLabel(_ title: String) -> some View {
    Text(title)
      .foregroundStyle(.secondary)
  }

  private var pendingWorkspaceRepository: RepositorySettingsFeature.RepositoryDraft? {
    guard let pendingWorkspaceRepositoryID else {
      return nil
    }
    return store.workspaceDraft?.repositories.first { $0.id == pendingWorkspaceRepositoryID }
  }

  private var canSubmitAddWorkspaceRepositorySheet: Bool {
    guard let repository = pendingWorkspaceRepository else {
      return false
    }
    return !repository.sourceLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func chooseInitialLocalWorkspaceRepositorySource(
    from draft: RepositorySettingsFeature.WorkspaceDraft
  ) {
    chooseWorkspaceRepositorySource { source in
      beginAddingLocalWorkspaceRepository(source: source, from: draft)
    }
  }

  private func beginAddingLocalWorkspaceRepository(
    source: String,
    from draft: RepositorySettingsFeature.WorkspaceDraft
  ) {
    let existingIDs = Set(draft.repositories.map(\.id))
    store.send(.workspaceAddLocalRepository(source))
    openPendingWorkspaceRepositorySheet(excluding: existingIDs)
  }

  private func beginAddingRemoteWorkspaceRepository(
    from draft: RepositorySettingsFeature.WorkspaceDraft
  ) {
    let existingIDs = Set(draft.repositories.map(\.id))
    store.send(.workspaceAddRemoteRepository(name: "Remote Repository", url: ""))
    openPendingWorkspaceRepositorySheet(excluding: existingIDs)
  }

  private func openPendingWorkspaceRepositorySheet(excluding existingIDs: Set<String>) {
    guard
      let repository = store.workspaceDraft?.repositories.reversed().first(where: {
        $0.isNew && !existingIDs.contains($0.id)
      })
    else {
      return
    }
    pendingWorkspaceRepositoryID = repository.id
    isAddWorkspaceRepositorySheetPresented = true
  }

  private func submitAddWorkspaceRepositorySheet() {
    isCommittingAddWorkspaceRepositorySheet = true
    pendingWorkspaceRepositoryID = nil
    isAddWorkspaceRepositorySheetPresented = false
  }

  private func saveAndCloseAddWorkspaceRepositorySheet() {
    submitAddWorkspaceRepositorySheet()
    store.send(.saveWorkspaceMetadataButtonTapped)
  }

  private func cancelAddWorkspaceRepositorySheet() {
    discardPendingWorkspaceRepository()
    isAddWorkspaceRepositorySheetPresented = false
  }

  private func handleAddWorkspaceRepositorySheetDismissed() {
    if isCommittingAddWorkspaceRepositorySheet {
      isCommittingAddWorkspaceRepositorySheet = false
      pendingWorkspaceRepositoryID = nil
      return
    }
    discardPendingWorkspaceRepository()
  }

  private func discardPendingWorkspaceRepository() {
    if let pendingWorkspaceRepositoryID {
      store.send(.workspaceDiscardNewRepository(id: pendingWorkspaceRepositoryID))
    }
    pendingWorkspaceRepositoryID = nil
  }

  private func chooseWorkspaceRepositorySource(for repositoryID: String) {
    chooseWorkspaceRepositorySource { source in
      store.send(.workspaceRepositorySourceChosen(id: repositoryID, source))
    }
  }

  private func chooseWorkspaceRepositorySource(_ completion: @escaping (String) -> Void) {
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
      completion(url.path(percentEncoded: false))
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

private struct WorkspaceRepoRemovalConfirmationView: View {
  let confirmation: RepositorySettingsFeature.WorkspaceRepositoryRemovalConfirmation
  let onDeleteBranchChanged: (Bool) -> Void
  let onCancel: () -> Void
  let onRemove: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Remove repository?")
          .font(.headline)
        Text("This removes \(confirmation.repositoryName) from the workspace.")
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Text(confirmation.repositoryPath)
          .font(.footnote.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
      }

      if let branchName = confirmation.branchName {
        Toggle(
          isOn: Binding(
            get: { confirmation.deleteBranch },
            set: { onDeleteBranchChanged($0) }
          )
        ) {
          HStack(spacing: 4) {
            Text("Also delete local branch")
            Text(branchName)
              .font(.body.monospaced())
          }
        }
        .help("Delete the branch from the source repository after removing the workspace worktree.")

        Text("Protected branches are kept.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      } else {
        Text("No local branch is associated with this repository entry.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }

      HStack {
        Spacer()
        Button("Cancel", role: .cancel) {
          onCancel()
        }
        .keyboardShortcut(.cancelAction)
        .help("Cancel")

        Button("Remove", role: .destructive) {
          onRemove()
        }
        .keyboardShortcut(.defaultAction)
        .help("Remove repository")
      }
    }
    .padding(24)
    .frame(width: 440)
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
