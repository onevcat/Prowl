import ComposableArchitecture
import Foundation
import IdentifiedCollections

/// A member that already exists in the edited workspace. Its source, path and
/// checkout are read-only provenance; only the display name and role can be
/// edited, and the member can be marked for removal until Save.
struct WorkspaceEditorExistingRepository: Equatable, Identifiable, Sendable {
  struct Removal: Equatable, Sendable {
    var deleteFiles = false
    var deleteBranch = false
  }

  let entry: ProjectWorkspaceRepositoryEntry
  var name: String
  var role: String
  var removal: Removal?

  var id: String { entry.id }

  var isMarkedForRemoval: Bool { removal != nil }

  /// Branch deletion is offered on the same terms as workspace removal: a
  /// worktree checkout with a recorded branch and source repository.
  var offersBranchDeletion: Bool {
    entry.sourceKind != .remote && entry.branchName != nil && entry.sourceLocation != nil
  }

  init(entry: ProjectWorkspaceRepositoryEntry) {
    self.entry = entry
    name = entry.name
    role = entry.role ?? ""
  }

  /// The entry as it should be saved, carrying the edited name and role.
  var editedEntry: ProjectWorkspaceRepositoryEntry {
    var entry = entry
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    entry.name = trimmedName.isEmpty ? self.entry.name : trimmedName
    let trimmedRole = role.trimmingCharacters(in: .whitespacesAndNewlines)
    entry.role = trimmedRole.isEmpty ? nil : trimmedRole
    return entry
  }
}

struct WorkspaceTaskLinkDraft: Equatable, Identifiable, Sendable {
  let id: String
  var value: String
}

enum WorkspaceEditorSubmission: Equatable, Sendable {
  case create(ProjectWorkspaceCreationDraft)
  case update(ProjectWorkspaceUpdateRequest)
}

@Reducer
struct WorkspaceEditorFeature {
  private enum CancelID {
    static let remoteRepositoryPromptLoad = "workspaceEditor.remoteRepositoryPromptLoad"
  }

  enum Mode: Equatable, Sendable {
    case create
    case edit(repositoryID: Repository.ID)

    var isEditing: Bool {
      if case .edit = self { return true }
      return false
    }
  }

  @ObservableState
  struct State: Equatable {
    var mode: Mode
    /// Members that already exist on disk (edit mode only), in saved order.
    var existingRepositories: IdentifiedArrayOf<WorkspaceEditorExistingRepository>
    /// Members added in this session; materialized on Create / Save.
    var repositories: IdentifiedArrayOf<ProjectWorkspaceCreationRepository>
    var openedRepositoryCandidates: IdentifiedArrayOf<ProjectWorkspaceCreationRepository>
    var title: String
    var description: String
    var taskLinks: IdentifiedArrayOf<WorkspaceTaskLinkDraft>
    var rootPath: String
    var isRootPathDirty = false
    var validationMessage: String?
    var validationTarget: ValidationTarget?
    var validationRequestID = 0
    var isSaving = false
    var remoteRepositoryPrompt: RemoteRepositoryPromptState?

    var availableOpenedRepositories: [ProjectWorkspaceCreationRepository] {
      openedRepositoryCandidates.filter { repositories[id: $0.id] == nil }
    }

    var rootPathPreview: String {
      PathPolicy.normalizePath(rootPath, resolvingSymlinks: false) ?? rootPath
    }

    /// Members that will exist after Create / Save.
    var remainingRepositoryCount: Int {
      existingRepositories.filter { !$0.isMarkedForRemoval }.count + repositories.count
    }

    var hasPendingRemovals: Bool {
      existingRepositories.contains(where: \.isMarkedForRemoval)
    }

    init(
      repositories: [ProjectWorkspaceCreationRepository],
      title: String,
      rootPath: String,
      openedRepositoryCandidates: [ProjectWorkspaceCreationRepository] = []
    ) {
      mode = .create
      existingRepositories = []
      self.repositories = IdentifiedArray(repositories, uniquingIDsWith: { current, _ in current })
      self.openedRepositoryCandidates = IdentifiedArray(
        openedRepositoryCandidates,
        uniquingIDsWith: { current, _ in current }
      )
      self.title = title
      description = ""
      taskLinks = []
      self.rootPath = rootPath
    }

    init(
      editing workspace: ProjectWorkspace,
      rootURL: URL,
      repositoryID: Repository.ID,
      openedRepositoryCandidates: [ProjectWorkspaceCreationRepository] = [],
      taskLinkIDs: (Int) -> String = { "task-link-\($0)" }
    ) {
      mode = .edit(repositoryID: repositoryID)
      existingRepositories = IdentifiedArray(
        workspace.repositories.map(WorkspaceEditorExistingRepository.init(entry:)),
        uniquingIDsWith: { current, _ in current }
      )
      repositories = []
      self.openedRepositoryCandidates = IdentifiedArray(
        openedRepositoryCandidates,
        uniquingIDsWith: { current, _ in current }
      )
      title = workspace.title
      description = workspace.description
      taskLinks = IdentifiedArray(
        workspace.taskLinks.enumerated().map { index, link in
          WorkspaceTaskLinkDraft(id: taskLinkIDs(index), value: link)
        },
        uniquingIDsWith: { current, _ in current }
      )
      var path = rootURL.standardizedFileURL.path(percentEncoded: false)
      while path.count > 1, path.hasSuffix("/") {
        path.removeLast()
      }
      rootPath = path
      isRootPathDirty = true
    }

    mutating func clearValidation() {
      validationMessage = nil
      validationTarget = nil
    }

    mutating func setValidation(_ message: String, target: ValidationTarget?) {
      validationMessage = message
      validationTarget = target
      validationRequestID += 1
    }
  }

  enum ValidationTarget: Equatable, Sendable {
    case title
    case rootPath
    case repository(Repository.ID, RepositoryField)
    case existingRepository(String)
  }

  enum RepositoryField: Equatable, Sendable {
    case name
    case source
    case branchName
    case baseRef
  }

  @ObservableState
  struct RemoteRepositoryPromptState: Equatable {
    var url = ""
    var name = ""
    var branchOptions: [GitBranchRefOption] = []
    var defaultBaseRef: String?
    var validationMessage: String?
    var isLoading = false

    var displayName: String {
      let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? "Remote Repository" : trimmed
    }
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    case titleChanged(String)
    case descriptionChanged(String)
    case addTaskLinkButtonTapped
    case taskLinkChanged(String, String)
    case removeTaskLink(String)
    case rootPathChanged(String)
    case automaticRootPathResolved(path: String, requestedRootPath: String)
    case addOpenedRepository(Repository.ID)
    case addRepositoryFromURL(ProjectWorkspaceRepositorySourceKind, String)
    case addRemoteButtonTapped
    case remoteRepositoryPromptURLChanged(String)
    case remoteRepositoryPromptNameChanged(String)
    case remoteRepositoryPromptLoadButtonTapped
    case remoteRepositoryPromptLoaded(String, GitRemoteBranchRefs)
    case remoteRepositoryPromptFailed(String)
    case remoteRepositoryPromptAddButtonTapped
    case remoteRepositoryPromptDismissed
    case removeRepository(Repository.ID)
    case repositorySourceKindChanged(Repository.ID, ProjectWorkspaceRepositorySourceKind)
    case repositoryCheckoutModeChanged(Repository.ID, ProjectWorkspaceRepositoryCheckoutMode)
    case repositoryNameChanged(Repository.ID, String)
    case repositoryRoleChanged(Repository.ID, String)
    case repositoryPathChanged(Repository.ID, String)
    case repositorySourceChosen(Repository.ID, String)
    case repositorySourceLocationChanged(Repository.ID, String)
    case repositoryBranchNameChanged(Repository.ID, String)
    case repositoryBaseRefChanged(Repository.ID, String)
    case repositoryResetLocalBranchChanged(Repository.ID, Bool)
    case existingRepositoryNameChanged(String, String)
    case existingRepositoryRoleChanged(String, String)
    case existingRepositoryMarkedForRemoval(String)
    case existingRepositoryRemovalUndone(String)
    case existingRepositoryDeleteFilesChanged(String, Bool)
    case existingRepositoryDeleteBranchChanged(String, Bool)
    case existingRepositoryMovedUp(String)
    case existingRepositoryMovedDown(String)
    case rootPathChosen(String)
    case cancelButtonTapped
    case submitButtonTapped
    case delegate(Delegate)
  }

  @CasePathable
  enum Delegate: Equatable {
    case baseRefSourceChanged(Repository.ID)
    case cancel
    case submit(WorkspaceEditorSubmission)
  }

  @Dependency(\.uuid) var uuid
  @Dependency(\.date.now) var now
  @Dependency(GitClientDependency.self) var gitClient

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        state.clearValidation()
        return .none

      case .titleChanged(let title):
        state.title = title
        state.clearValidation()
        guard !state.mode.isEditing, !state.isRootPathDirty else {
          return .none
        }
        let folderName = ProjectWorkspace.defaultWorkspaceFolderName(for: title)
        let requestedRootPath = ProjectWorkspace.workspaceRootPath(folderName: folderName, suffix: nil)
        state.rootPath = requestedRootPath
        return .run { send in
          let resolved = ProjectWorkspace.uniqueWorkspaceRootPath(folderName: folderName)
          await send(
            .automaticRootPathResolved(path: resolved, requestedRootPath: requestedRootPath))
        }

      case .descriptionChanged(let description):
        state.description = description
        state.clearValidation()
        return .none

      case .addTaskLinkButtonTapped:
        state.taskLinks.append(WorkspaceTaskLinkDraft(id: uuid().uuidString, value: ""))
        state.clearValidation()
        return .none

      case .taskLinkChanged(let linkID, let value):
        state.taskLinks[id: linkID]?.value = value
        state.clearValidation()
        return .none

      case .removeTaskLink(let linkID):
        state.taskLinks.remove(id: linkID)
        state.clearValidation()
        return .none

      case .rootPathChanged(let rootPath):
        state.rootPath = rootPath
        state.isRootPathDirty = true
        state.clearValidation()
        return .none

      case .automaticRootPathResolved(let path, let requestedRootPath):
        guard !state.isRootPathDirty, state.rootPath == requestedRootPath else {
          return .none
        }
        state.rootPath = path
        return .none

      case .addOpenedRepository(let repositoryID):
        guard let repository = state.openedRepositoryCandidates[id: repositoryID],
          state.repositories[id: repositoryID] == nil
        else {
          return .none
        }
        state.repositories.append(repository)
        state.clearValidation()
        return .send(.delegate(.baseRefSourceChanged(repositoryID)))

      case .addRemoteButtonTapped:
        state.remoteRepositoryPrompt = RemoteRepositoryPromptState()
        state.clearValidation()
        return .none

      case .remoteRepositoryPromptURLChanged(let url):
        state.remoteRepositoryPrompt?.url = url
        state.remoteRepositoryPrompt?.validationMessage = nil
        state.remoteRepositoryPrompt?.branchOptions = []
        state.remoteRepositoryPrompt?.defaultBaseRef = nil
        if state.remoteRepositoryPrompt?.name.trimmingCharacters(in: .whitespacesAndNewlines)
          .isEmpty == true
        {
          state.remoteRepositoryPrompt?.name = GitRemoteNaming.repositoryName(fromRemoteURL: url)
        }
        return .none

      case .remoteRepositoryPromptNameChanged(let name):
        state.remoteRepositoryPrompt?.name = name
        state.remoteRepositoryPrompt?.validationMessage = nil
        return .none

      case .remoteRepositoryPromptLoadButtonTapped:
        guard var prompt = state.remoteRepositoryPrompt else {
          return .none
        }
        let url = prompt.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
          prompt.validationMessage = String(localized: "Remote URL required.")
          state.remoteRepositoryPrompt = prompt
          return .none
        }
        prompt.url = url
        if prompt.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          prompt.name = GitRemoteNaming.repositoryName(fromRemoteURL: url)
        }
        prompt.isLoading = true
        prompt.validationMessage = nil
        state.remoteRepositoryPrompt = prompt
        let gitClient = gitClient
        return .run { send in
          do {
            let refs = try await Self.loadRemoteBranchRefs(url, gitClient: gitClient)
            await send(.remoteRepositoryPromptLoaded(url, refs))
          } catch {
            await send(.remoteRepositoryPromptFailed(error.localizedDescription))
          }
        }
        .cancellable(id: CancelID.remoteRepositoryPromptLoad, cancelInFlight: true)

      case .remoteRepositoryPromptLoaded(let url, let refs):
        guard var prompt = state.remoteRepositoryPrompt,
          prompt.url.trimmingCharacters(in: .whitespacesAndNewlines) == url
        else {
          return .none
        }
        let options = ProjectWorkspaceCreationRepository.normalizedBaseRefOptions(refs.options)
        prompt.isLoading = false
        prompt.branchOptions = options
        prompt.defaultBaseRef = ProjectWorkspaceCreationRepository.preferredBaseRef(
          automaticBaseRef: refs.defaultBaseRef,
          options: options
        )
        prompt.validationMessage = options.isEmpty ? String(localized: "No remote branches found.") : nil
        state.remoteRepositoryPrompt = prompt
        return .none

      case .remoteRepositoryPromptFailed(let message):
        state.remoteRepositoryPrompt?.isLoading = false
        state.remoteRepositoryPrompt?.validationMessage = message
        return .none

      case .remoteRepositoryPromptAddButtonTapped:
        guard let prompt = state.remoteRepositoryPrompt else {
          return .none
        }
        let url = prompt.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
          state.remoteRepositoryPrompt?.validationMessage = String(localized: "Remote URL required.")
          return .none
        }
        guard !prompt.branchOptions.isEmpty else {
          state.remoteRepositoryPrompt?.validationMessage = String(localized: "Load remote branches before adding.")
          return .none
        }
        let id = uuid().uuidString
        state.repositories.append(
          ProjectWorkspaceCreationRepository(
            id: id,
            name: prompt.displayName,
            sourceKind: .remote,
            sourceLocation: url,
            checkoutMode: .useExistingRef,
            baseRef: prompt.defaultBaseRef,
            baseRefOptions: prompt.branchOptions
          )
        )
        state.remoteRepositoryPrompt = nil
        state.clearValidation()
        return .none

      case .remoteRepositoryPromptDismissed:
        state.remoteRepositoryPrompt = nil
        return .cancel(id: CancelID.remoteRepositoryPromptLoad)

      case .addRepositoryFromURL(let sourceKind, let path):
        guard let rootPath = PathPolicy.normalizePath(path) else {
          state.setValidation(
            ProjectWorkspaceCreationError.missingRepositorySource("repository").localizedDescription,
            target: nil
          )
          return .none
        }
        let url = URL(fileURLWithPath: rootPath).standardizedFileURL
        let id = uuid().uuidString
        state.repositories.append(
          ProjectWorkspaceCreationRepository(
            id: id,
            name: Self.defaultRepositoryName(for: url),
            sourceKind: sourceKind,
            sourceLocation: rootPath
          )
        )
        state.clearValidation()
        return .send(.delegate(.baseRefSourceChanged(id)))

      case .removeRepository(let repositoryID):
        state.repositories.remove(id: repositoryID)
        state.clearValidation()
        return .none

      case .repositoryCheckoutModeChanged(let repositoryID, let checkoutMode):
        guard var repository = state.repositories[id: repositoryID] else {
          return .none
        }
        guard checkoutMode != .link || repository.sourceKind.supportsLinkCheckout else {
          return .none
        }
        repository.checkoutMode = checkoutMode
        state.repositories[id: repositoryID] = repository
        state.clearValidation()
        return .none

      case .repositorySourceKindChanged(let repositoryID, let sourceKind):
        guard var repository = state.repositories[id: repositoryID] else {
          return .none
        }
        repository.sourceKind = sourceKind
        repository.baseRef = nil
        repository.baseRefOptions = []
        if repository.checkoutMode == .link, !sourceKind.supportsLinkCheckout {
          repository.checkoutMode = sourceKind.defaultCheckoutMode
        }
        if sourceKind == .remote {
          repository.sourceLocation = ""
        }
        state.repositories[id: repositoryID] = repository
        state.clearValidation()
        guard sourceKind != .remote, repository.localSourceURL != nil else {
          return .none
        }
        return .send(.delegate(.baseRefSourceChanged(repositoryID)))

      case .repositoryNameChanged(let repositoryID, let name):
        state.repositories[id: repositoryID]?.name = name
        state.clearValidation()
        return .none

      case .repositoryRoleChanged(let repositoryID, let role):
        state.repositories[id: repositoryID]?.role = role
        state.clearValidation()
        return .none

      case .repositoryPathChanged(let repositoryID, let path):
        state.repositories[id: repositoryID]?.path = path
        state.clearValidation()
        return .none

      case .repositorySourceChosen(let repositoryID, let sourceLocation):
        guard let rootPath = PathPolicy.normalizePath(sourceLocation) else {
          state.setValidation(
            ProjectWorkspaceCreationError.missingRepositorySource("repository").localizedDescription,
            target: .repository(repositoryID, .source)
          )
          return .none
        }
        guard var repository = state.repositories[id: repositoryID] else {
          return .none
        }
        repository.sourceLocation = rootPath
        if repository.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          repository.name = Self.defaultRepositoryName(for: URL(fileURLWithPath: rootPath))
        }
        repository.baseRef = nil
        repository.baseRefOptions = []
        state.repositories[id: repositoryID] = repository
        state.clearValidation()
        return .send(.delegate(.baseRefSourceChanged(repositoryID)))

      case .repositorySourceLocationChanged(let repositoryID, let sourceLocation):
        guard var repository = state.repositories[id: repositoryID] else {
          return .none
        }
        let sourceLocationChanged = repository.sourceLocation != sourceLocation
        repository.sourceLocation = sourceLocation
        if sourceLocationChanged {
          repository.baseRef = nil
          repository.baseRefOptions = []
        }
        state.repositories[id: repositoryID] = repository
        state.clearValidation()
        guard sourceLocationChanged, repository.sourceKind != .remote,
          repository.localSourceURL != nil
        else {
          return .none
        }
        return .send(.delegate(.baseRefSourceChanged(repositoryID)))

      case .repositoryBranchNameChanged(let repositoryID, let branchName):
        state.repositories[id: repositoryID]?.branchName = branchName
        state.clearValidation()
        return .none

      case .repositoryBaseRefChanged(let repositoryID, let baseRef):
        guard var repository = state.repositories[id: repositoryID] else {
          return .none
        }
        let trimmed = baseRef.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty || repository.baseRefOptions.contains(where: { $0.ref == trimmed })
        else {
          return .none
        }
        repository.baseRef = trimmed.isEmpty ? nil : trimmed
        // A new ref selection invalidates any previous keep/reset choice.
        repository.resetLocalBranchToRemote = false
        state.repositories[id: repositoryID] = repository
        state.clearValidation()
        return .none

      case .repositoryResetLocalBranchChanged(let repositoryID, let resetToRemote):
        state.repositories[id: repositoryID]?.resetLocalBranchToRemote = resetToRemote
        state.clearValidation()
        return .none

      case .existingRepositoryNameChanged(let entryID, let name):
        state.existingRepositories[id: entryID]?.name = name
        state.clearValidation()
        return .none

      case .existingRepositoryRoleChanged(let entryID, let role):
        state.existingRepositories[id: entryID]?.role = role
        state.clearValidation()
        return .none

      case .existingRepositoryMarkedForRemoval(let entryID):
        guard state.existingRepositories[id: entryID] != nil else {
          return .none
        }
        state.existingRepositories[id: entryID]?.removal = .init()
        state.clearValidation()
        return .none

      case .existingRepositoryRemovalUndone(let entryID):
        state.existingRepositories[id: entryID]?.removal = nil
        state.clearValidation()
        return .none

      case .existingRepositoryDeleteFilesChanged(let entryID, let deleteFiles):
        guard var removal = state.existingRepositories[id: entryID]?.removal else {
          return .none
        }
        removal.deleteFiles = deleteFiles
        if !deleteFiles {
          removal.deleteBranch = false
        }
        state.existingRepositories[id: entryID]?.removal = removal
        return .none

      case .existingRepositoryDeleteBranchChanged(let entryID, let deleteBranch):
        guard let repository = state.existingRepositories[id: entryID],
          var removal = repository.removal,
          removal.deleteFiles || !deleteBranch,
          repository.offersBranchDeletion || !deleteBranch
        else {
          return .none
        }
        removal.deleteBranch = deleteBranch
        state.existingRepositories[id: entryID]?.removal = removal
        return .none

      case .existingRepositoryMovedUp(let entryID):
        guard let index = state.existingRepositories.index(id: entryID), index > 0 else {
          return .none
        }
        state.existingRepositories.swapAt(index, index - 1)
        return .none

      case .existingRepositoryMovedDown(let entryID):
        guard let index = state.existingRepositories.index(id: entryID),
          index < state.existingRepositories.count - 1
        else {
          return .none
        }
        state.existingRepositories.swapAt(index, index + 1)
        return .none

      case .rootPathChosen(let path):
        state.rootPath = path
        state.isRootPathDirty = true
        state.clearValidation()
        return .none

      case .cancelButtonTapped:
        return .send(.delegate(.cancel))

      case .submitButtonTapped:
        let title = state.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
          state.setValidation(
            ProjectWorkspaceCreationError.missingTitle.localizedDescription,
            target: .title
          )
          return .none
        }
        guard let rootPath = PathPolicy.normalizePath(state.rootPath, resolvingSymlinks: false)
        else {
          state.setValidation(
            ProjectWorkspaceCreationError.missingPath.localizedDescription,
            target: .rootPath
          )
          return .none
        }
        guard state.remainingRepositoryCount >= 1 else {
          state.setValidation(
            ProjectWorkspaceCreationError.notEnoughRepositories.localizedDescription,
            target: nil
          )
          return .none
        }
        var plans: [ProjectWorkspaceRepositoryPlan] = []
        for repository in state.repositories {
          switch Self.plan(for: repository) {
          case .success(let plan):
            plans.append(plan)
          case .failure(let error):
            state.setValidation(
              error.localizedDescription,
              target: Self.validationTarget(for: error, repositoryID: repository.id)
            )
            return .none
          }
        }
        state.clearValidation()
        let description = state.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let taskLinks = state.taskLinks.map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter { !$0.isEmpty }
        switch state.mode {
        case .create:
          return .send(
            .delegate(
              .submit(
                .create(
                  ProjectWorkspaceCreationDraft(
                    title: title,
                    description: description,
                    taskLinks: taskLinks,
                    rootURL: URL(filePath: rootPath, directoryHint: .isDirectory),
                    repositories: plans
                  )
                )
              )
            )
          )
        case .edit:
          let members: [ProjectWorkspaceUpdateMember] =
            state.existingRepositories
            .filter { !$0.isMarkedForRemoval }
            .map { .existing($0.editedEntry) }
            + plans.map { .added($0) }
          let removals = state.existingRepositories.compactMap { repository in
            repository.removal.map { removal in
              ProjectWorkspaceRepositoryRemoval(
                entry: repository.entry,
                deleteFiles: removal.deleteFiles,
                deleteBranch: removal.deleteFiles && removal.deleteBranch
              )
            }
          }
          return .send(
            .delegate(
              .submit(
                .update(
                  ProjectWorkspaceUpdateRequest(
                    rootURL: URL(filePath: rootPath, directoryHint: .isDirectory),
                    title: title,
                    description: description,
                    taskLinks: taskLinks,
                    members: members,
                    removals: removals,
                    updatedAt: now
                  )
                )
              )
            )
          )
        }

      case .delegate:
        return .none
      }
    }
  }

  static func defaultRepositoryName(for url: URL) -> String {
    let name = Repository.name(for: url)
    guard name.count > 4, name.hasSuffix(".git") else {
      return name
    }
    return String(name.dropLast(4))
  }

  nonisolated private static func loadRemoteBranchRefs(
    _ url: String,
    gitClient: GitClientDependency
  ) async throws -> GitRemoteBranchRefs {
    try await withThrowingTaskGroup(of: GitRemoteBranchRefs.self) { group in
      group.addTask {
        try await gitClient.remoteBranchRefs(url)
      }
      group.addTask {
        try await Task.sleep(for: .seconds(30))
        throw RemoteBranchLoadTimeoutError()
      }
      guard let refs = try await group.next() else {
        throw CancellationError()
      }
      group.cancelAll()
      return refs
    }
  }

  nonisolated static func validationTarget(
    for error: ProjectWorkspaceCreationError,
    repositoryID: Repository.ID
  ) -> ValidationTarget? {
    switch error {
    case .missingRepositoryName:
      return .repository(repositoryID, .name)
    case .missingRepositorySource:
      return .repository(repositoryID, .source)
    case .missingBranchName:
      return .repository(repositoryID, .branchName)
    case .missingExistingRef:
      return .repository(repositoryID, .baseRef)
    case .missingTitle:
      return .title
    case .missingPath:
      return .rootPath
    case .notEnoughRepositories, .linkCheckoutUnsupported, .destinationIsFile,
      .workspaceAlreadyExists, .workspaceMetadataMissing, .repositoryDoesNotExist,
      .linkAlreadyExists, .gitCommandFailed:
      return nil
    }
  }

  static func plan(
    for repository: ProjectWorkspaceCreationRepository
  ) -> Result<ProjectWorkspaceRepositoryPlan, ProjectWorkspaceCreationError> {
    let name = repository.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let displayName = name.isEmpty ? "repository" : name
    let sourceLocation = repository.sourceLocation.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sourceLocation.isEmpty else {
      return .failure(.missingRepositorySource(displayName))
    }
    let checkout: ProjectWorkspaceRepositoryCheckout
    switch repository.checkoutMode {
    case .link:
      guard repository.sourceKind.supportsLinkCheckout else {
        return .failure(.linkCheckoutUnsupported(displayName))
      }
      checkout = .link
    case .createBranch:
      guard let branchName = repository.branchName?.trimmingCharacters(in: .whitespacesAndNewlines),
        !branchName.isEmpty
      else {
        return .failure(.missingBranchName(displayName))
      }
      let trimmedBase = repository.baseRef?.trimmingCharacters(in: .whitespacesAndNewlines)
      checkout = .createBranch(
        branchName: branchName,
        baseRef: trimmedBase?.isEmpty == false ? trimmedBase : nil
      )
    case .useExistingRef:
      guard let baseRef = repository.baseRef?.trimmingCharacters(in: .whitespacesAndNewlines),
        !baseRef.isEmpty
      else {
        return .failure(.missingExistingRef(displayName))
      }
      let kind = repository.baseRefOptions.first { $0.ref == baseRef }?.kind ?? .local
      if kind == .local {
        checkout = .useExistingRef(baseRef)
      } else {
        guard
          let branchName = ProjectWorkspaceCreationRepository.localBranchName(forRemoteRef: baseRef)
        else {
          return .failure(.missingExistingRef(displayName))
        }
        if let localBranchName = repository.resettableLocalBranchName,
          !repository.resetLocalBranchToRemote
        {
          // A same-named local branch already exists and the user chose to keep
          // it: check out the local branch directly rather than resetting it to
          // the remote ref with `-B`, which would discard local-only commits.
          checkout = .useExistingRef(localBranchName)
        } else {
          checkout = .trackRemoteRef(remoteRef: baseRef, branchName: branchName)
        }
      }
    }
    let role = repository.role?.trimmingCharacters(in: .whitespacesAndNewlines)
    return .success(
      ProjectWorkspaceRepositoryPlan(
        id: repository.id,
        name: repository.name,
        role: role?.isEmpty == false ? role : nil,
        path: repository.path,
        sourceKind: repository.sourceKind,
        sourceLocation: sourceLocation,
        checkout: checkout
      )
    )
  }
}

private struct RemoteBranchLoadTimeoutError: LocalizedError {
  var errorDescription: String? {
    String(localized: "Remote branch loading timed out.")
  }
}
