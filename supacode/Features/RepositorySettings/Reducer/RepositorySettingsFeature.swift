import ComposableArchitecture
import Foundation

@Reducer
struct RepositorySettingsFeature {
  struct WorkspaceDraft: Equatable {
    var title: String
    var description: String
    var taskLinksText: String
    var agentGuideEnabled: Bool
    var agentGuideOutputsText: String
    var includeChildInstructionFiles: Bool
    var agentGuideExtraNotes: String
    var repositories: [RepositoryDraft]

    init(workspace: ProjectWorkspace) {
      let guide = workspace.agentGuide?.normalized ?? ProjectWorkspaceAgentGuide()
      title = workspace.title
      description = workspace.description
      taskLinksText = workspace.taskLinks.joined(separator: "\n")
      agentGuideEnabled = guide.enabled
      agentGuideOutputsText = guide.outputs.joined(separator: "\n")
      includeChildInstructionFiles = guide.includeChildInstructionFiles
      agentGuideExtraNotes = guide.extraNotes
      repositories = workspace.repositories.map(RepositoryDraft.init)
    }
  }

  struct RepositoryDraft: Equatable, Identifiable {
    var id: String
    var name: String
    var role: String
    var agentNotes: String
    var path: String
    var sourceKind: ProjectWorkspaceRepositorySourceKind
    var sourceLocation: String
    var branchName: String
    var baseRef: String
    var bootstrapScriptID: String
    var bootstrapRequired: Bool
    var bootstrapRunOnCreate: Bool

    init(entry: ProjectWorkspace.RepositoryEntry) {
      id = entry.id
      name = entry.name
      role = entry.role ?? ""
      agentNotes = entry.agentNotes ?? ""
      path = entry.path
      sourceKind = entry.sourceKind
      sourceLocation = entry.sourceLocation ?? ""
      branchName = entry.branchName ?? ""
      baseRef = entry.baseRef ?? ""
      bootstrapScriptID = entry.bootstrap?.scriptID ?? ""
      bootstrapRequired = entry.bootstrap?.required ?? false
      bootstrapRunOnCreate = entry.bootstrap?.runOn.contains(.create) ?? false
    }

    var bootstrap: ProjectWorkspaceRepositoryBootstrap? {
      let scriptID = bootstrapScriptID.trimmingCharacters(in: .whitespacesAndNewlines)
      var runOn = Set<ProjectWorkspaceBootstrapTiming>()
      if bootstrapRunOnCreate {
        runOn.insert(.create)
      }
      guard !scriptID.isEmpty || !runOn.isEmpty || bootstrapRequired else {
        return nil
      }
      return ProjectWorkspaceRepositoryBootstrap(
        scriptKind: .userProfile,
        scriptID: scriptID.isEmpty ? nil : scriptID,
        runOn: runOn,
        required: bootstrapRequired
      )
    }
  }

  @ObservableState
  struct State: Equatable {
    var rootURL: URL
    /// Persistence key for `@Shared(.repositoryAppearances)`. Defaults
    /// to empty so legacy test fixtures that only construct the four
    /// originally-required fields keep compiling — production
    /// callers (AppFeature) always pass the canonical `repository.id`.
    var repositoryID: Repository.ID = ""
    var repositoryKind: Repository.Kind
    var workspace: ProjectWorkspace?
    var workspaceDraft: WorkspaceDraft?
    var workspaceSaveError: String?
    var workspaceSaveStatus: String?
    var settings: RepositorySettings
    var userSettings: UserRepositorySettings
    var appearance: RepositoryAppearance = .empty
    var globalDefaultWorktreeBaseDirectoryPath: String?
    var globalCopyIgnoredOnWorktreeCreate: Bool = false
    var globalCopyUntrackedOnWorktreeCreate: Bool = false
    var globalPullRequestMergeStrategy: PullRequestMergeStrategy = .merge
    var isBareRepository = false
    var branchOptions: [String] = []
    var defaultWorktreeBaseRef = "origin/main"
    var isBranchDataLoaded = false
    var keybindingUserOverrides: KeybindingUserOverrideStore = .empty
    var appearanceImportError: String?

    var capabilities: Repository.Capabilities {
      switch repositoryKind {
      case .git:
        .git
      case .plain:
        .plain
      }
    }

    var showsWorktreeSettings: Bool {
      capabilities.supportsWorktrees
    }

    var showsDiffSettings: Bool {
      capabilities.supportsDiff
    }

    var showsPullRequestSettings: Bool {
      capabilities.supportsPullRequests
    }

    var showsDiffsAndPullRequestSettings: Bool {
      showsDiffSettings || showsPullRequestSettings
    }

    var showsSetupScriptSettings: Bool {
      capabilities.supportsWorktrees
    }

    var showsArchiveScriptSettings: Bool {
      capabilities.supportsWorktrees
    }

    var showsRunScriptSettings: Bool {
      capabilities.supportsRunnableFolderActions
    }

    var showsCustomCommandsSettings: Bool {
      capabilities.supportsRunnableFolderActions
    }

    var exampleWorktreePath: String {
      SupacodePaths.exampleWorktreePath(
        for: rootURL,
        globalDefaultPath: globalDefaultWorktreeBaseDirectoryPath,
        repositoryOverridePath: settings.worktreeBaseDirectoryPath
      )
    }

    var canSaveWorkspaceDraft: Bool {
      workspace != nil && workspaceDraft != nil
    }

    mutating func setWorkspace(_ workspace: ProjectWorkspace?) {
      self.workspace = workspace
      workspaceDraft = workspace.map(WorkspaceDraft.init)
      workspaceSaveError = nil
      workspaceSaveStatus = nil
    }

    mutating func updateWorkspaceRepositoryDraft(
      id: String,
      _ update: (inout RepositoryDraft) -> Void
    ) {
      guard var draft = workspaceDraft,
        let index = draft.repositories.firstIndex(where: { $0.id == id })
      else {
        return
      }
      update(&draft.repositories[index])
      workspaceDraft = draft
      workspaceSaveStatus = nil
    }

    func updatedWorkspaceFromDraft() -> ProjectWorkspace? {
      guard var workspace, let draft = workspaceDraft else {
        return nil
      }
      workspace.title = draft.title
      workspace.description = draft.description
      workspace.taskLinks = draft.taskLinksText
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
      workspace.agentGuide = ProjectWorkspaceAgentGuide(
        enabled: draft.agentGuideEnabled,
        outputs: draft.agentGuideOutputsText.components(separatedBy: .newlines),
        includeChildInstructionFiles: draft.includeChildInstructionFiles,
        extraNotes: draft.agentGuideExtraNotes
      )
      workspace.repositories = workspace.repositories.map { entry in
        guard let repositoryDraft = draft.repositories.first(where: { $0.id == entry.id }) else {
          return entry
        }
        var updated = entry
        updated.role = Self.trimmedNonEmpty(repositoryDraft.role)
        updated.agentNotes = Self.trimmedNonEmpty(repositoryDraft.agentNotes)
        updated.bootstrap = repositoryDraft.bootstrap
        return updated
      }
      return workspace
    }

    private static func trimmedNonEmpty(_ value: String) -> String? {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
  }

  enum Action: BindableAction {
    case task
    case settingsLoaded(
      RepositorySettings,
      UserRepositorySettings,
      isBareRepository: Bool,
      globalDefaultWorktreeBaseDirectoryPath: String?,
      globalCopyIgnoredOnWorktreeCreate: Bool,
      globalCopyUntrackedOnWorktreeCreate: Bool,
      globalPullRequestMergeStrategy: PullRequestMergeStrategy,
      keybindingUserOverrides: KeybindingUserOverrideStore
    )
    case appearanceLoaded(RepositoryAppearance)
    case setAppearanceColor(RepositoryColorChoice?)
    case setAppearanceIcon(RepositoryIconSource?)
    case importUserImage(URL)
    case userImageImported(filename: String)
    case userImageImportFailed(String)
    case dismissAppearanceImportError
    case resetAppearance
    case branchDataLoaded([String], defaultBaseRef: String)
    case workspaceTitleChanged(String)
    case workspaceDescriptionChanged(String)
    case workspaceTaskLinksChanged(String)
    case workspaceAgentGuideEnabledChanged(Bool)
    case workspaceAgentGuideOutputsChanged(String)
    case workspaceChildInstructionsChanged(Bool)
    case workspaceAgentGuideExtraNotesChanged(String)
    case workspaceRepositoryRoleChanged(id: String, String)
    case workspaceRepositoryAgentNotesChanged(id: String, String)
    case workspaceBootstrapIDChanged(id: String, String)
    case workspaceBootstrapRequiredChanged(id: String, Bool)
    case workspaceBootstrapCreateChanged(id: String, Bool)
    case saveWorkspaceMetadataButtonTapped
    case regenerateWorkspaceGuideButtonTapped
    case workspaceMetadataSaved(ProjectWorkspace)
    case workspaceMetadataSaveFailed(String)
    case workspaceGuideRegenerated
    case workspaceGuideRegenerateFailed(String)
    case delegate(Delegate)
    case binding(BindingAction<State>)
  }

  @CasePathable
  enum Delegate: Equatable {
    case settingsChanged(URL)
  }

  @Dependency(GitClientDependency.self) private var gitClient
  @Dependency(\.repositoryIconAssetStore) private var repositoryIconAssetStore
  @Dependency(\.date.now) private var now

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .task:
        let rootURL = state.rootURL
        guard state.capabilities.supportsRepositoryGitSettings else {
          return .run { send in
            @Shared(.repositorySettings(rootURL)) var repositorySettings
            @Shared(.userRepositorySettings(rootURL)) var userRepositorySettings
            @Shared(.settingsFile) var settingsFile
            let global = settingsFile.global
            await send(
              .settingsLoaded(
                repositorySettings,
                userRepositorySettings,
                isBareRepository: false,
                globalDefaultWorktreeBaseDirectoryPath: global.defaultWorktreeBaseDirectoryPath,
                globalCopyIgnoredOnWorktreeCreate: global.copyIgnoredOnWorktreeCreate,
                globalCopyUntrackedOnWorktreeCreate: global.copyUntrackedOnWorktreeCreate,
                globalPullRequestMergeStrategy: global.pullRequestMergeStrategy,
                keybindingUserOverrides: global.keybindingUserOverrides
              )
            )
          }
        }
        let gitClient = gitClient
        return .run { send in
          let isBareRepository = (try? await gitClient.isBareRepository(rootURL)) ?? false
          @Shared(.repositorySettings(rootURL)) var repositorySettings
          @Shared(.userRepositorySettings(rootURL)) var userRepositorySettings
          @Shared(.settingsFile) var settingsFile
          let global = settingsFile.global
          await send(
            .settingsLoaded(
              repositorySettings,
              userRepositorySettings,
              isBareRepository: isBareRepository,
              globalDefaultWorktreeBaseDirectoryPath: global.defaultWorktreeBaseDirectoryPath,
              globalCopyIgnoredOnWorktreeCreate: global.copyIgnoredOnWorktreeCreate,
              globalCopyUntrackedOnWorktreeCreate: global.copyUntrackedOnWorktreeCreate,
              globalPullRequestMergeStrategy: global.pullRequestMergeStrategy,
              keybindingUserOverrides: global.keybindingUserOverrides
            )
          )
          let branches: [String]
          do {
            branches = try await gitClient.branchRefs(rootURL)
          } catch {
            let rootPath = rootURL.path(percentEncoded: false)
            SupaLogger("Settings").warning(
              "Branch refs failed for \(rootPath): \(error.localizedDescription)"
            )
            branches = []
          }
          let defaultBaseRef = await gitClient.automaticWorktreeBaseRef(rootURL) ?? "HEAD"
          await send(.branchDataLoaded(branches, defaultBaseRef: defaultBaseRef))
        }

      case .settingsLoaded(
        let settings,
        let userSettings,
        let isBareRepository,
        let globalDefaultWorktreeBaseDirectoryPath,
        let globalCopyIgnoredOnWorktreeCreate,
        let globalCopyUntrackedOnWorktreeCreate,
        let globalPullRequestMergeStrategy,
        let keybindingUserOverrides
      ):
        var updatedSettings = settings
        updatedSettings.worktreeBaseDirectoryPath =
          SupacodePaths.normalizedWorktreeBaseDirectoryPath(
            updatedSettings.worktreeBaseDirectoryPath,
            repositoryRootURL: state.rootURL
          )
        if isBareRepository {
          updatedSettings.copyIgnoredOnWorktreeCreate = nil
          updatedSettings.copyUntrackedOnWorktreeCreate = nil
        }
        state.settings = updatedSettings
        state.userSettings = userSettings.normalized()
        state.globalDefaultWorktreeBaseDirectoryPath =
          SupacodePaths.normalizedWorktreeBaseDirectoryPath(globalDefaultWorktreeBaseDirectoryPath)
        state.globalCopyIgnoredOnWorktreeCreate = globalCopyIgnoredOnWorktreeCreate
        state.globalCopyUntrackedOnWorktreeCreate = globalCopyUntrackedOnWorktreeCreate
        state.globalPullRequestMergeStrategy = globalPullRequestMergeStrategy
        state.isBareRepository = isBareRepository
        state.keybindingUserOverrides = keybindingUserOverrides
        guard updatedSettings != settings else { return .none }
        let rootURL = state.rootURL
        @Shared(.repositorySettings(rootURL)) var repositorySettings
        $repositorySettings.withLock { $0 = updatedSettings }
        return .send(.delegate(.settingsChanged(rootURL)))

      case .appearanceLoaded(let appearance):
        state.appearance = appearance
        return .none

      case .setAppearanceColor(let color):
        guard state.appearance.color != color else { return .none }
        state.appearance.color = color
        return persistAppearance(state.appearance, repositoryID: state.repositoryID)

      case .setAppearanceIcon(let newIcon):
        let previousIcon = state.appearance.icon
        guard previousIcon != newIcon else { return .none }
        state.appearance.icon = newIcon
        let persist = persistAppearance(state.appearance, repositoryID: state.repositoryID)
        let cleanup = removeAbandonedUserImage(
          previous: previousIcon,
          new: newIcon,
          rootURL: state.rootURL
        )
        return .merge(persist, cleanup)

      case .importUserImage(let sourceURL):
        let rootURL = state.rootURL
        let store = repositoryIconAssetStore
        return .run { send in
          do {
            let filename = try store.importImage(sourceURL, rootURL)
            await send(.userImageImported(filename: filename))
          } catch {
            await send(.userImageImportFailed(error.localizedDescription))
          }
        }

      case .userImageImported(let filename):
        return .send(.setAppearanceIcon(.userImage(filename: filename)))

      case .userImageImportFailed(let message):
        state.appearanceImportError = message
        return .none

      case .dismissAppearanceImportError:
        state.appearanceImportError = nil
        return .none

      case .resetAppearance:
        let previousIcon = state.appearance.icon
        guard !state.appearance.isEmpty else { return .none }
        state.appearance = .empty
        let persist = persistAppearance(.empty, repositoryID: state.repositoryID)
        let cleanup = removeAbandonedUserImage(
          previous: previousIcon,
          new: nil,
          rootURL: state.rootURL
        )
        return .merge(persist, cleanup)

      case .branchDataLoaded(let branches, let defaultBaseRef):
        state.defaultWorktreeBaseRef = defaultBaseRef
        var options = branches
        if !options.contains(defaultBaseRef) {
          options.append(defaultBaseRef)
        }
        if let selected = state.settings.worktreeBaseRef, !options.contains(selected) {
          options.append(selected)
        }
        state.branchOptions = options
        state.isBranchDataLoaded = true
        return .none

      case .workspaceTitleChanged(let title):
        state.workspaceDraft?.title = title
        state.workspaceSaveStatus = nil
        return .none

      case .workspaceDescriptionChanged(let description):
        state.workspaceDraft?.description = description
        state.workspaceSaveStatus = nil
        return .none

      case .workspaceTaskLinksChanged(let links):
        state.workspaceDraft?.taskLinksText = links
        state.workspaceSaveStatus = nil
        return .none

      case .workspaceAgentGuideEnabledChanged(let enabled):
        state.workspaceDraft?.agentGuideEnabled = enabled
        state.workspaceSaveStatus = nil
        return .none

      case .workspaceAgentGuideOutputsChanged(let outputs):
        state.workspaceDraft?.agentGuideOutputsText = outputs
        state.workspaceSaveStatus = nil
        return .none

      case .workspaceChildInstructionsChanged(let include):
        state.workspaceDraft?.includeChildInstructionFiles = include
        state.workspaceSaveStatus = nil
        return .none

      case .workspaceAgentGuideExtraNotesChanged(let notes):
        state.workspaceDraft?.agentGuideExtraNotes = notes
        state.workspaceSaveStatus = nil
        return .none

      case .workspaceRepositoryRoleChanged(let id, let role):
        state.updateWorkspaceRepositoryDraft(id: id) { $0.role = role }
        return .none

      case .workspaceRepositoryAgentNotesChanged(let id, let notes):
        state.updateWorkspaceRepositoryDraft(id: id) { $0.agentNotes = notes }
        return .none

      case .workspaceBootstrapIDChanged(let id, let scriptID):
        state.updateWorkspaceRepositoryDraft(id: id) { $0.bootstrapScriptID = scriptID }
        return .none

      case .workspaceBootstrapRequiredChanged(let id, let required):
        state.updateWorkspaceRepositoryDraft(id: id) { $0.bootstrapRequired = required }
        return .none

      case .workspaceBootstrapCreateChanged(let id, let enabled):
        state.updateWorkspaceRepositoryDraft(id: id) { $0.bootstrapRunOnCreate = enabled }
        return .none

      case .saveWorkspaceMetadataButtonTapped:
        guard let updatedWorkspace = state.updatedWorkspaceFromDraft() else {
          return .none
        }
        state.workspaceSaveError = nil
        let rootURL = state.rootURL
        let savedAt = now
        return .run { send in
          do {
            let patcher = ProjectWorkspaceMetadataPatcher(now: { savedAt })
            let savedWorkspace = try patcher.save(updatedWorkspace, rootURL: rootURL)
            if savedWorkspace.agentGuide?.enabled == true {
              try ProjectWorkspaceAgentGuideFileWriter().write(
                workspace: savedWorkspace, rootURL: rootURL)
            }
            await send(.workspaceMetadataSaved(savedWorkspace))
          } catch {
            await send(.workspaceMetadataSaveFailed(error.localizedDescription))
          }
        }

      case .regenerateWorkspaceGuideButtonTapped:
        guard let updatedWorkspace = state.updatedWorkspaceFromDraft() else {
          return .none
        }
        state.workspaceSaveError = nil
        let rootURL = state.rootURL
        return .run { send in
          do {
            try ProjectWorkspaceAgentGuideFileWriter().write(
              workspace: updatedWorkspace, rootURL: rootURL)
            await send(.workspaceGuideRegenerated)
          } catch {
            await send(.workspaceGuideRegenerateFailed(error.localizedDescription))
          }
        }

      case .workspaceMetadataSaved(let workspace):
        state.workspace = workspace
        state.workspaceDraft = WorkspaceDraft(workspace: workspace)
        state.workspaceSaveStatus = "Saved workspace metadata."
        state.workspaceSaveError = nil
        return .send(.delegate(.settingsChanged(state.rootURL)))

      case .workspaceMetadataSaveFailed(let message):
        state.workspaceSaveError = message
        state.workspaceSaveStatus = nil
        return .none

      case .workspaceGuideRegenerated:
        state.workspaceSaveStatus = "Regenerated agent guide."
        state.workspaceSaveError = nil
        return .none

      case .workspaceGuideRegenerateFailed(let message):
        state.workspaceSaveError = message
        state.workspaceSaveStatus = nil
        return .none

      case .binding:
        if state.isBareRepository {
          state.settings.copyIgnoredOnWorktreeCreate = nil
          state.settings.copyUntrackedOnWorktreeCreate = nil
        }
        state.userSettings = state.userSettings.normalized()
        let rootURL = state.rootURL
        var normalizedSettings = state.settings
        normalizedSettings.worktreeBaseDirectoryPath =
          SupacodePaths.normalizedWorktreeBaseDirectoryPath(
            normalizedSettings.worktreeBaseDirectoryPath,
            repositoryRootURL: rootURL
          )
        let trimmedCustomTitle =
          normalizedSettings.customTitle?
          .trimmingCharacters(in: .whitespacesAndNewlines)
        normalizedSettings.customTitle =
          (trimmedCustomTitle?.isEmpty ?? true) ? nil : trimmedCustomTitle
        normalizedSettings.githubAccountOverride =
          normalizedSettings.githubAccountOverride?.normalized
        @Shared(.repositorySettings(rootURL)) var repositorySettings
        @Shared(.userRepositorySettings(rootURL)) var userRepositorySettings
        $repositorySettings.withLock { $0 = normalizedSettings }
        $userRepositorySettings.withLock { $0 = state.userSettings }
        return .send(.delegate(.settingsChanged(rootURL)))

      case .delegate:
        return .none
      }
    }
  }

  /// Writes the appearance back to the global `@Shared` dict, dropping
  /// the entry when it's been cleared so the on-disk file stays tight.
  private func persistAppearance(
    _ appearance: RepositoryAppearance,
    repositoryID: Repository.ID
  ) -> Effect<Action> {
    .run { _ in
      @Shared(.repositoryAppearances) var appearances
      $appearances.withLock {
        if appearance.isEmpty {
          $0.removeValue(forKey: repositoryID)
        } else {
          $0[repositoryID] = appearance
        }
      }
    }
  }

  /// When the icon transitions away from a user-imported file, the old
  /// asset on disk is no longer referenced and should be cleaned up.
  /// No-op when the previous icon wasn't a user image or when the new
  /// icon is the same user image.
  private func removeAbandonedUserImage(
    previous: RepositoryIconSource?,
    new: RepositoryIconSource?,
    rootURL: URL
  ) -> Effect<Action> {
    guard case .userImage(let oldFilename) = previous else { return .none }
    if case .userImage(let newFilename) = new, newFilename == oldFilename {
      return .none
    }
    let store = repositoryIconAssetStore
    return .run { _ in
      try? store.remove(oldFilename, rootURL)
    }
  }

}
