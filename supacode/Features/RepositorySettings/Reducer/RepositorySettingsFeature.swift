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
    var baseRefOptions: [GitBranchRefOption]
    var checkoutMode: ProjectWorkspaceRepositoryCheckoutMode
    var resetLocalBranchToRemote: Bool
    var isNew: Bool
    var isRemoved: Bool
    var bootstrapScriptIDs: [String]
    var bootstrapRequired: Bool
    var bootstrapRunOnCreate: Bool
    var bootstrapRunOnAdd: Bool
    var bootstrapRunOnManual: Bool

    var usesLinkCheckout: Bool {
      if isNew {
        return checkoutMode == .link
      }
      return sourceKind == .existingPath
        || (sourceKind == .localRepository && branchName.isEmpty && baseRef.isEmpty)
    }

    var hasAutomaticBootstrapTiming: Bool {
      bootstrapRunOnCreate || bootstrapRunOnAdd
    }

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
      baseRefOptions = []
      checkoutMode = .useExistingRef
      resetLocalBranchToRemote = false
      isNew = false
      isRemoved = false
      bootstrapScriptIDs = entry.bootstrap?.scriptIDs ?? []
      bootstrapRequired = entry.bootstrap?.required ?? false
      bootstrapRunOnCreate = entry.bootstrap?.runOn.contains(.create) ?? false
      bootstrapRunOnAdd = entry.bootstrap?.runOn.contains(.onAdd) ?? false
      bootstrapRunOnManual = entry.bootstrap?.runOn.contains(.manual) ?? false
    }

    init(
      id: String,
      name: String,
      sourceKind: ProjectWorkspaceRepositorySourceKind,
      sourceLocation: String
    ) {
      self.id = id
      self.name = name
      role = ""
      agentNotes = ""
      path = ""
      self.sourceKind = sourceKind
      self.sourceLocation = sourceLocation
      branchName = ""
      baseRef = ""
      baseRefOptions = []
      checkoutMode = sourceKind.defaultCheckoutMode
      resetLocalBranchToRemote = false
      isNew = true
      isRemoved = false
      bootstrapScriptIDs = []
      bootstrapRequired = false
      bootstrapRunOnCreate = false
      bootstrapRunOnAdd = false
      bootstrapRunOnManual = false
    }

    var bootstrap: ProjectWorkspaceRepositoryBootstrap? {
      let scriptIDs = bootstrapScriptIDs
      guard !scriptIDs.isEmpty else {
        return nil
      }
      return ProjectWorkspaceRepositoryBootstrap(
        scriptKind: .userProfile,
        scriptIDs: scriptIDs,
        runOn: [.manual],
        required: false
      )
    }

    var creationRepository: ProjectWorkspaceCreationRepository {
      ProjectWorkspaceCreationRepository(
        id: id,
        name: name,
        sourceKind: sourceKind,
        sourceLocation: sourceLocation,
        checkoutMode: checkoutMode,
        branchName: branchName.isEmpty ? nil : branchName,
        baseRef: baseRef.isEmpty ? nil : baseRef,
        path: path.isEmpty ? nil : path,
        baseRefOptions: baseRefOptions
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

    var activeWorkspaceRepositoryCount: Int {
      workspaceDraft?.repositories.filter { !$0.isRemoved }.count ?? 0
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
      workspace.repositories = workspace.repositories.compactMap { entry in
        guard let repositoryDraft = draft.repositories.first(where: { $0.id == entry.id }) else {
          return entry
        }
        guard !repositoryDraft.isRemoved else {
          return nil
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
    case workspaceAddLocalRepository(String)
    case workspaceAddRemoteRepository(name: String, url: String)
    case workspaceDiscardNewRepository(id: String)
    case workspaceRepositoryNameChanged(id: String, String)
    case workspaceRepositorySourceChosen(id: String, String)
    case workspaceLoadBaseRefsTapped(id: String)
    case workspaceRepositoryPathChanged(id: String, String)
    case workspaceRepositoryCheckoutModeChanged(id: String, ProjectWorkspaceRepositoryCheckoutMode)
    case workspaceRepositoryBranchNameChanged(id: String, String)
    case workspaceRepositoryBaseRefChanged(id: String, String)
    case workspaceRepositoryBaseRefsLoaded(
      id: String, [GitBranchRefOption], defaultBaseRef: String?)
    case workspaceRemoveRepository(id: String)
    case workspaceRestoreRepository(id: String)
    case workspaceBootstrapProfileAdded(id: String, String)
    case workspaceBootstrapProfileRemoved(id: String, String)
    case workspaceBootstrapProfileMoved(id: String, String, BootstrapProfileMoveDirection)
    case workspaceBootstrapRequiredChanged(id: String, Bool)
    case workspaceBootstrapCreateChanged(id: String, Bool)
    case workspaceBootstrapOnAddChanged(id: String, Bool)
    case workspaceBootstrapManualChanged(id: String, Bool)
    case runWorkspaceBootstrapButtonTapped(id: String)
    case runWorkspaceBootstrapProfileButtonTapped(id: String, scriptID: String)
    case saveWorkspaceMetadataButtonTapped
    case regenerateWorkspaceGuideButtonTapped
    case workspaceMetadataSaved(ProjectWorkspace)
    case workspaceMetadataSaveFailed(String)
    case workspaceBootstrapRan(String)
    case workspaceBootstrapRunFailed(String)
    case workspaceGuideRegenerated
    case workspaceGuideRegenerateFailed(String)
    case delegate(Delegate)
    case binding(BindingAction<State>)
  }

  enum BootstrapProfileMoveDirection: Equatable, Sendable {
    case earlier
    case later
  }

  @CasePathable
  enum Delegate: Equatable {
    case settingsChanged(URL)
  }

  @Dependency(GitClientDependency.self) private var gitClient
  @Dependency(\.repositoryIconAssetStore) private var repositoryIconAssetStore
  @Dependency(\.date.now) private var now
  @Dependency(ShellClient.self) private var shellClient
  @Dependency(\.uuid) private var uuid

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

      case .workspaceAddLocalRepository(let sourceLocation):
        let trimmed = sourceLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var draft = state.workspaceDraft else {
          return .none
        }
        let rootURL = URL(fileURLWithPath: trimmed, isDirectory: true)
        let id = uuid().uuidString
        draft.repositories.append(
          RepositoryDraft(
            id: id,
            name: trimmed.isEmpty ? "" : Repository.name(for: rootURL),
            sourceKind: .localRepository,
            sourceLocation: trimmed
          )
        )
        state.workspaceDraft = draft
        state.workspaceSaveStatus = nil
        return trimmed.isEmpty ? .none : workspaceBaseRefsEffect(for: draft.repositories.last)

      case .workspaceAddRemoteRepository(let name, let url):
        guard var draft = state.workspaceDraft else {
          return .none
        }
        let sourceLocation = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = uuid().uuidString
        draft.repositories.append(
          RepositoryDraft(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
              ?? GitRemoteNaming.repositoryName(fromRemoteURL: sourceLocation),
            sourceKind: .remote,
            sourceLocation: sourceLocation
          )
        )
        state.workspaceDraft = draft
        state.workspaceSaveStatus = nil
        return .none

      case .workspaceDiscardNewRepository(let id):
        guard var draft = state.workspaceDraft else {
          return .none
        }
        draft.repositories.removeAll { $0.id == id && $0.isNew }
        state.workspaceDraft = draft
        return .none

      case .workspaceRepositoryNameChanged(let id, let name):
        state.updateWorkspaceRepositoryDraft(id: id) { $0.name = name }
        return .none

      case .workspaceRepositorySourceChosen(let id, let sourceLocation):
        let trimmed = sourceLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        state.updateWorkspaceRepositoryDraft(id: id) {
          $0.sourceLocation = trimmed
          if $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            $0.sourceKind == .remote
          {
            $0.name = GitRemoteNaming.repositoryName(fromRemoteURL: trimmed)
          }
          if $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            $0.sourceKind != .remote,
            !trimmed.isEmpty
          {
            $0.name = Repository.name(for: URL(fileURLWithPath: trimmed, isDirectory: true))
          }
          $0.baseRef = ""
          $0.baseRefOptions = []
        }
        return .none

      case .workspaceLoadBaseRefsTapped(let id):
        guard let repository = state.workspaceDraft?.repositories.first(where: { $0.id == id })
        else {
          return .none
        }
        return workspaceBaseRefsEffect(for: repository)

      case .workspaceRepositoryPathChanged(let id, let path):
        state.updateWorkspaceRepositoryDraft(id: id) { $0.path = path }
        return .none

      case .workspaceRepositoryCheckoutModeChanged(let id, let mode):
        state.updateWorkspaceRepositoryDraft(id: id) { repository in
          guard mode != .link || repository.sourceKind.supportsLinkCheckout else {
            return
          }
          repository.checkoutMode = mode
          if mode == .link {
            repository.bootstrapScriptIDs = []
            repository.bootstrapRunOnCreate = false
            repository.bootstrapRunOnAdd = false
            repository.bootstrapRunOnManual = false
            repository.bootstrapRequired = false
          }
        }
        return .none

      case .workspaceRepositoryBranchNameChanged(let id, let branchName):
        state.updateWorkspaceRepositoryDraft(id: id) { $0.branchName = branchName }
        return .none

      case .workspaceRepositoryBaseRefChanged(let id, let baseRef):
        state.updateWorkspaceRepositoryDraft(id: id) {
          $0.baseRef = baseRef
          $0.resetLocalBranchToRemote = false
        }
        return .none

      case .workspaceRepositoryBaseRefsLoaded(let id, let options, let defaultBaseRef):
        state.updateWorkspaceRepositoryDraft(id: id) { repository in
          repository.baseRefOptions = options
          repository.baseRef = defaultBaseRef ?? options.first?.ref ?? repository.baseRef
        }
        return .none

      case .workspaceRemoveRepository(let id):
        state.updateWorkspaceRepositoryDraft(id: id) { $0.isRemoved = true }
        return .none

      case .workspaceRestoreRepository(let id):
        state.updateWorkspaceRepositoryDraft(id: id) { $0.isRemoved = false }
        return .none

      case .workspaceBootstrapProfileAdded(let id, let scriptID):
        state.updateWorkspaceRepositoryDraft(id: id) { repository in
          guard !repository.usesLinkCheckout else {
            return
          }
          repository.bootstrapScriptIDs = ProjectWorkspaceCreationRepository.normalizedBootstrapScriptIDs(
            repository.bootstrapScriptIDs + [scriptID]
          )
          repository.bootstrapRunOnManual = true
        }
        return .none

      case .workspaceBootstrapProfileRemoved(let id, let scriptID):
        state.updateWorkspaceRepositoryDraft(id: id) { repository in
          repository.bootstrapScriptIDs.removeAll { $0 == scriptID }
          if repository.bootstrapScriptIDs.isEmpty {
            repository.bootstrapRunOnCreate = false
            repository.bootstrapRunOnAdd = false
            repository.bootstrapRunOnManual = false
            repository.bootstrapRequired = false
          }
        }
        return .none

      case .workspaceBootstrapProfileMoved(let id, let scriptID, let direction):
        state.updateWorkspaceRepositoryDraft(id: id) { repository in
          guard let index = repository.bootstrapScriptIDs.firstIndex(of: scriptID) else {
            return
          }
          let targetIndex: Int
          switch direction {
          case .earlier:
            guard index > repository.bootstrapScriptIDs.startIndex else {
              return
            }
            targetIndex = repository.bootstrapScriptIDs.index(before: index)
          case .later:
            targetIndex = repository.bootstrapScriptIDs.index(after: index)
            guard targetIndex < repository.bootstrapScriptIDs.endIndex else {
              return
            }
          }
          repository.bootstrapScriptIDs.swapAt(index, targetIndex)
        }
        return .none

      case .workspaceBootstrapRequiredChanged(let id, let required):
        state.updateWorkspaceRepositoryDraft(id: id) { repository in
          guard repository.hasAutomaticBootstrapTiming else {
            return
          }
          repository.bootstrapRequired = required
        }
        return .none

      case .workspaceBootstrapCreateChanged(let id, let enabled):
        state.updateWorkspaceRepositoryDraft(id: id) { repository in
          guard !repository.usesLinkCheckout else {
            return
          }
          repository.bootstrapRunOnCreate = enabled
          if !repository.hasAutomaticBootstrapTiming {
            repository.bootstrapRequired = false
          }
        }
        return .none

      case .workspaceBootstrapOnAddChanged(let id, let enabled):
        state.updateWorkspaceRepositoryDraft(id: id) { repository in
          guard !repository.usesLinkCheckout else {
            return
          }
          repository.bootstrapRunOnAdd = enabled
          if !repository.hasAutomaticBootstrapTiming {
            repository.bootstrapRequired = false
          }
        }
        return .none

      case .workspaceBootstrapManualChanged(let id, let enabled):
        state.updateWorkspaceRepositoryDraft(id: id) { repository in
          guard !repository.usesLinkCheckout else {
            return
          }
          repository.bootstrapRunOnManual = enabled
        }
        return .none

      case .runWorkspaceBootstrapButtonTapped(let id):
        guard let workspace = state.updatedWorkspaceFromDraft(),
          let draftRepository = state.workspaceDraft?.repositories.first(where: { $0.id == id }),
          !draftRepository.isNew,
          !draftRepository.isRemoved,
          !draftRepository.usesLinkCheckout,
          var entry = workspace.repositories.first(where: { $0.id == id })
        else {
          return .none
        }
        entry.bootstrap = ProjectWorkspaceRepositoryBootstrap(
          scriptKind: .userProfile,
          scriptIDs: draftRepository.bootstrapScriptIDs,
          runOn: [.manual],
          required: true
        )
        let bootstrapEntry = entry
        let rootURL = state.rootURL
        @Shared(.bootstrapProfiles) var bootstrapProfiles
        let bootstrapRunner = ProjectWorkspaceBootstrapExecutor(
          profiles: bootstrapProfiles,
          shellClient: shellClient,
          now: { Date() }
        ).runner
        return .run { send in
          do {
            try await ProjectWorkspace.runBootstrap(
              for: bootstrapEntry,
              workspaceRootURL: rootURL,
              timing: .manual,
              bootstrapRunner: bootstrapRunner
            )
            await send(.workspaceBootstrapRan(bootstrapEntry.name))
          } catch {
            await send(.workspaceBootstrapRunFailed(error.localizedDescription))
          }
        }

      case .runWorkspaceBootstrapProfileButtonTapped(let id, let scriptID):
        guard let workspace = state.updatedWorkspaceFromDraft(),
          let draftRepository = state.workspaceDraft?.repositories.first(where: { $0.id == id }),
          !draftRepository.isNew,
          !draftRepository.isRemoved,
          !draftRepository.usesLinkCheckout,
          draftRepository.bootstrapScriptIDs.contains(scriptID),
          var entry = workspace.repositories.first(where: { $0.id == id })
        else {
          return .none
        }
        entry.bootstrap = ProjectWorkspaceRepositoryBootstrap(
          scriptKind: .userProfile,
          scriptIDs: [scriptID],
          runOn: [.manual],
          required: true
        )
        let bootstrapEntry = entry
        let rootURL = state.rootURL
        @Shared(.bootstrapProfiles) var bootstrapProfiles
        let bootstrapRunner = ProjectWorkspaceBootstrapExecutor(
          profiles: bootstrapProfiles,
          shellClient: shellClient,
          now: { Date() }
        ).runner
        return .run { send in
          do {
            try await ProjectWorkspace.runBootstrap(
              for: bootstrapEntry,
              workspaceRootURL: rootURL,
              timing: .manual,
              bootstrapRunner: bootstrapRunner
            )
            await send(.workspaceBootstrapRan(bootstrapEntry.name))
          } catch {
            await send(.workspaceBootstrapRunFailed(error.localizedDescription))
          }
        }

      case .saveWorkspaceMetadataButtonTapped:
        guard let updatedWorkspace = state.updatedWorkspaceFromDraft() else {
          return .none
        }
        state.workspaceSaveError = nil
        let rootURL = state.rootURL
        let savedAt = now
        let originalWorkspace = state.workspace
        let draft = state.workspaceDraft
        let gitRunner = RepositoriesFeature.workspaceGitRunner(shellClient: shellClient)
        @Shared(.bootstrapProfiles) var bootstrapProfiles
        let bootstrapRunner = ProjectWorkspaceBootstrapExecutor(
          profiles: bootstrapProfiles,
          shellClient: shellClient,
          now: { Date() }
        ).runner
        return .run { send in
          do {
            let additions =
              try draft?.repositories.filter { $0.isNew && !$0.isRemoved }.map {
                try Self.plan(for: $0)
              } ?? []
            let removedIDs = Set(draft?.repositories.filter(\.isRemoved).map(\.id) ?? [])
            let removedRepositories =
              originalWorkspace?.repositories.filter { removedIDs.contains($0.id) } ?? []
            let savedWorkspace: ProjectWorkspace
            if !additions.isEmpty || !removedRepositories.isEmpty {
              savedWorkspace = try await ProjectWorkspace.updateRepositories(
                ProjectWorkspaceRepositoryUpdateRequest(
                  workspace: updatedWorkspace,
                  rootURL: rootURL,
                  additions: additions,
                  removedRepositories: removedRepositories,
                  updatedAt: savedAt
                ),
                gitRunner: gitRunner,
                bootstrapRunner: bootstrapRunner,
                agentGuideWriter: ProjectWorkspaceAgentGuideFileWriter().writer()
              ) { workspace in
                try ProjectWorkspaceMetadataPatcher(now: { savedAt }).save(
                  workspace, rootURL: rootURL)
              }
            } else {
              savedWorkspace =
                try ProjectWorkspaceMetadataPatcher(now: { savedAt }).save(
                  updatedWorkspace,
                  rootURL: rootURL
                )
              if savedWorkspace.agentGuide?.enabled == true {
                try ProjectWorkspaceAgentGuideFileWriter().write(
                  workspace: savedWorkspace, rootURL: rootURL)
              }
            }
            await send(.workspaceMetadataSaved(savedWorkspace))
          } catch {
            await send(.workspaceMetadataSaveFailed(error.localizedDescription))
          }
        }

      case .regenerateWorkspaceGuideButtonTapped:
        guard var updatedWorkspace = state.updatedWorkspaceFromDraft() else {
          return .none
        }
        updatedWorkspace.agentGuide = (updatedWorkspace.agentGuide ?? ProjectWorkspaceAgentGuide())
          .withEnabledForManualUpdate()
        let workspaceToWrite = updatedWorkspace
        state.workspaceSaveError = nil
        let rootURL = state.rootURL
        return .run { send in
          do {
            try ProjectWorkspaceAgentGuideFileWriter().write(
              workspace: workspaceToWrite, rootURL: rootURL)
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

      case .workspaceBootstrapRan(let name):
        state.workspaceSaveStatus = "Ran bootstrap for \(name)."
        state.workspaceSaveError = nil
        return .none

      case .workspaceBootstrapRunFailed(let message):
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

  private func workspaceBaseRefsEffect(
    for repository: RepositoryDraft?
  ) -> Effect<Action> {
    guard let repository,
      repository.isNew,
      !repository.sourceLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return .none
    }
    let id = repository.id
    let creationRepository = Self.creationRepository(for: repository)
    let gitClient = gitClient
    return .run { send in
      let result = await RepositoriesFeature.workspaceBaseRefs(
        for: creationRepository,
        gitClient: gitClient
      )
      await send(
        .workspaceRepositoryBaseRefsLoaded(
          id: id,
          result.options,
          defaultBaseRef: result.defaultBaseRef
        )
      )
    }
  }

  nonisolated private static func plan(for repository: RepositoryDraft)
    throws -> ProjectWorkspaceRepositoryPlan
  {
    var plan = try WorkspaceCreationPromptFeature.plan(for: creationRepository(for: repository))
      .get()
    plan.bootstrap = bootstrap(for: repository)
    return plan
  }

  nonisolated private static func creationRepository(
    for repository: RepositoryDraft
  ) -> ProjectWorkspaceCreationRepository {
    ProjectWorkspaceCreationRepository(
      id: repository.id,
      name: repository.name,
      sourceKind: repository.sourceKind,
      sourceLocation: repository.sourceLocation,
      checkoutMode: repository.checkoutMode,
      branchName: repository.branchName.isEmpty ? nil : repository.branchName,
      baseRef: repository.baseRef.isEmpty ? nil : repository.baseRef,
      path: repository.path.isEmpty ? nil : repository.path,
      baseRefOptions: repository.baseRefOptions,
      bootstrapScriptIDs: repository.bootstrapScriptIDs
    )
  }

  nonisolated private static func bootstrap(
    for repository: RepositoryDraft
  ) -> ProjectWorkspaceRepositoryBootstrap? {
    let scriptIDs = repository.bootstrapScriptIDs
    guard !scriptIDs.isEmpty else {
      return nil
    }
    return ProjectWorkspaceRepositoryBootstrap(
      scriptKind: .userProfile,
      scriptIDs: scriptIDs,
      runOn: [.manual],
      required: false
    )
  }
}

extension String {
  fileprivate var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}

extension ProjectWorkspaceAgentGuide {
  fileprivate func withEnabledForManualUpdate() -> ProjectWorkspaceAgentGuide {
    var copy = self
    copy.enabled = true
    return copy
  }
}
