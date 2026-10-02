import ComposableArchitecture
import Foundation
import IdentifiedCollections

/// The second level of the workspace editor: one repository at a time.
///
/// Adding walks two steps — pick a source (opened repository, local folder,
/// remote URL), then configure name, role, and checkout. Editing a row added
/// in this session reopens step 2; editing an existing member only exposes
/// name, role, and the staged removal.
@Reducer
struct WorkspaceMemberEditorFeature {
  private enum CancelID {
    static let remoteLoad = "workspaceMemberEditor.remoteLoad"
    static let baseRefs = "workspaceMemberEditor.baseRefs"
  }

  enum Mode: Equatable, Sendable {
    case add
    case editAdded
    case editExisting
  }

  enum SourceChoice: Equatable, Sendable {
    case opened
    case local
    case remote
  }

  enum Field: Equatable, Sendable {
    case remoteURL
    case name
    case branchName
    case baseRef
  }

  @ObservableState
  struct State: Equatable {
    var mode: Mode
    var openedCandidates: IdentifiedArrayOf<ProjectWorkspaceCreationRepository>
    /// Step 1 (add only). `nil` until the user picks a source.
    var sourceChoice: SourceChoice?
    var remoteURL = ""
    var isLoadingRemote = false
    var remoteErrorMessage: String?
    /// Step 2 for added rows.
    var draft: ProjectWorkspaceCreationRepository?
    var isLoadingBaseRefs = false
    /// Step 2 for existing members.
    var existing: WorkspaceEditorExistingRepository?
    var validationMessage: String?
    var validationField: Field?
    var isAdvancedExpanded = false

    var isConfiguring: Bool {
      draft != nil || existing != nil
    }

    static func add(openedCandidates: [ProjectWorkspaceCreationRepository]) -> State {
      State(
        mode: .add,
        openedCandidates: IdentifiedArray(openedCandidates, uniquingIDsWith: { current, _ in current })
      )
    }

    static func editAdded(_ draft: ProjectWorkspaceCreationRepository) -> State {
      State(mode: .editAdded, openedCandidates: [], draft: draft)
    }

    static func editExisting(_ existing: WorkspaceEditorExistingRepository) -> State {
      State(mode: .editExisting, openedCandidates: [], existing: existing)
    }

    mutating func clearValidation() {
      validationMessage = nil
      validationField = nil
    }
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    case sourceChosen(SourceChoice)
    case openedCandidateChosen(Repository.ID)
    case localFolderChosen(String)
    case remoteURLChanged(String)
    case remoteURLCommitted
    case remoteRefsLoaded(url: String, GitRemoteBranchRefs)
    case remoteRefsFailed(url: String, String)
    case baseRefsLoaded(
      sourceLocation: String, options: [GitBranchRefOption], defaultBaseRef: String?, errorMessage: String?)
    case nameChanged(String)
    case roleChanged(String)
    case pathChanged(String)
    case checkoutModeChanged(ProjectWorkspaceRepositoryCheckoutMode)
    case branchNameChanged(String)
    case baseRefChanged(String)
    case resetLocalBranchChanged(Bool)
    case existingNameChanged(String)
    case existingRoleChanged(String)
    case existingRemovalChanged(Bool)
    case existingDeleteFilesChanged(Bool)
    case existingDeleteBranchChanged(Bool)
    case backButtonTapped
    case removeAddedButtonTapped
    case commitButtonTapped
    case delegate(Delegate)
  }

  @CasePathable
  enum Delegate: Equatable {
    case cancel
    case commitAdded(ProjectWorkspaceCreationRepository)
    case commitExisting(WorkspaceEditorExistingRepository)
    case removeAdded(Repository.ID)
  }

  @Dependency(\.uuid) var uuid
  @Dependency(\.continuousClock) var clock
  @Dependency(GitClientDependency.self) var gitClient

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .sourceChosen(let choice):
        state.sourceChoice = choice
        state.remoteErrorMessage = nil
        state.clearValidation()
        return .cancel(id: CancelID.remoteLoad)

      case .openedCandidateChosen(let repositoryID):
        guard let candidate = state.openedCandidates[id: repositoryID] else {
          return .none
        }
        state.draft = candidate
        state.clearValidation()
        return loadBaseRefs(for: candidate, state: &state)

      case .localFolderChosen(let path):
        guard let rootPath = PathPolicy.normalizePath(path) else {
          state.validationMessage =
            ProjectWorkspaceCreationError.missingRepositorySource("repository").localizedDescription
          return .none
        }
        let url = URL(fileURLWithPath: rootPath).standardizedFileURL
        let draft = ProjectWorkspaceCreationRepository(
          id: uuid().uuidString,
          name: WorkspaceEditorFeature.defaultRepositoryName(for: url),
          sourceKind: .localRepository,
          sourceLocation: rootPath
        )
        state.draft = draft
        state.clearValidation()
        return loadBaseRefs(for: draft, state: &state)

      case .remoteURLChanged(let url):
        state.remoteURL = url
        state.remoteErrorMessage = nil
        state.clearValidation()
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
          state.isLoadingRemote = false
          return .cancel(id: CancelID.remoteLoad)
        }
        // Branches load on their own once typing pauses; Return loads at once.
        return .run { send in
          try await clock.sleep(for: .milliseconds(800))
          await send(.remoteURLCommitted)
        }
        .cancellable(id: CancelID.remoteLoad, cancelInFlight: true)

      case .remoteURLCommitted:
        let url = state.remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
          state.validationMessage = String(localized: "Remote URL required.")
          state.validationField = .remoteURL
          return .none
        }
        state.isLoadingRemote = true
        state.remoteErrorMessage = nil
        let gitClient = gitClient
        return .run { send in
          do {
            let refs = try await Self.loadRemoteBranchRefs(url, gitClient: gitClient)
            await send(.remoteRefsLoaded(url: url, refs))
          } catch {
            await send(.remoteRefsFailed(url: url, error.localizedDescription))
          }
        }
        .cancellable(id: CancelID.remoteLoad, cancelInFlight: true)

      case .remoteRefsLoaded(let url, let refs):
        guard state.remoteURL.trimmingCharacters(in: .whitespacesAndNewlines) == url else {
          return .none
        }
        state.isLoadingRemote = false
        let options = ProjectWorkspaceCreationRepository.normalizedBaseRefOptions(refs.options)
        guard !options.isEmpty else {
          state.remoteErrorMessage = String(localized: "No remote branches found.")
          return .none
        }
        state.draft = ProjectWorkspaceCreationRepository(
          id: uuid().uuidString,
          name: GitRemoteNaming.repositoryName(fromRemoteURL: url),
          sourceKind: .remote,
          sourceLocation: url,
          checkoutMode: .useExistingRef,
          baseRef: ProjectWorkspaceCreationRepository.preferredBaseRef(
            automaticBaseRef: refs.defaultBaseRef, options: options),
          baseRefOptions: options
        )
        return .none

      case .remoteRefsFailed(let url, let message):
        guard state.remoteURL.trimmingCharacters(in: .whitespacesAndNewlines) == url else {
          return .none
        }
        state.isLoadingRemote = false
        state.remoteErrorMessage = message
        return .none

      case .baseRefsLoaded(let sourceLocation, let options, let defaultBaseRef, let errorMessage):
        guard var draft = state.draft, draft.sourceLocation == sourceLocation else {
          return .none
        }
        state.isLoadingBaseRefs = false
        if let errorMessage {
          state.validationMessage = errorMessage
        }
        let baseRefOptions = ProjectWorkspaceCreationRepository.normalizedBaseRefOptions(options)
        draft.baseRefOptions = baseRefOptions
        if let baseRef = draft.baseRef?.trimmingCharacters(in: .whitespacesAndNewlines),
          baseRefOptions.contains(where: { $0.ref == baseRef })
        {
          draft.baseRef = baseRef
        } else {
          draft.baseRef = defaultBaseRef
        }
        state.draft = draft
        return .none

      case .nameChanged(let name):
        state.draft?.name = name
        state.clearValidation()
        return .none

      case .roleChanged(let role):
        state.draft?.role = role
        state.clearValidation()
        return .none

      case .pathChanged(let path):
        state.draft?.path = path
        state.clearValidation()
        return .none

      case .checkoutModeChanged(let checkoutMode):
        guard var draft = state.draft, checkoutMode != .link || draft.sourceKind.supportsLinkCheckout
        else {
          return .none
        }
        draft.checkoutMode = checkoutMode
        state.draft = draft
        state.clearValidation()
        return .none

      case .branchNameChanged(let branchName):
        state.draft?.branchName = branchName
        state.clearValidation()
        return .none

      case .baseRefChanged(let baseRef):
        guard var draft = state.draft else {
          return .none
        }
        let trimmed = baseRef.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty || draft.baseRefOptions.contains(where: { $0.ref == trimmed }) else {
          return .none
        }
        draft.baseRef = trimmed.isEmpty ? nil : trimmed
        // A new ref selection invalidates any previous keep/reset choice.
        draft.resetLocalBranchToRemote = false
        state.draft = draft
        state.clearValidation()
        return .none

      case .resetLocalBranchChanged(let resetToRemote):
        state.draft?.resetLocalBranchToRemote = resetToRemote
        return .none

      case .existingNameChanged(let name):
        state.existing?.name = name
        return .none

      case .existingRoleChanged(let role):
        state.existing?.role = role
        return .none

      case .existingRemovalChanged(let isRemoved):
        guard state.existing != nil else {
          return .none
        }
        state.existing?.removal = isRemoved ? .init() : nil
        return .none

      case .existingDeleteFilesChanged(let deleteFiles):
        guard var removal = state.existing?.removal else {
          return .none
        }
        removal.deleteFiles = deleteFiles
        if !deleteFiles {
          removal.deleteBranch = false
        }
        state.existing?.removal = removal
        return .none

      case .existingDeleteBranchChanged(let deleteBranch):
        guard let existing = state.existing, var removal = existing.removal,
          removal.deleteFiles || !deleteBranch,
          existing.offersBranchDeletion || !deleteBranch
        else {
          return .none
        }
        removal.deleteBranch = deleteBranch
        state.existing?.removal = removal
        return .none

      case .backButtonTapped:
        return .merge(
          .cancel(id: CancelID.remoteLoad),
          .cancel(id: CancelID.baseRefs),
          .send(.delegate(.cancel))
        )

      case .removeAddedButtonTapped:
        guard state.mode == .editAdded, let draft = state.draft else {
          return .none
        }
        return .send(.delegate(.removeAdded(draft.id)))

      case .commitButtonTapped:
        if let existing = state.existing {
          return .send(.delegate(.commitExisting(existing)))
        }
        guard let draft = state.draft else {
          return .none
        }
        switch WorkspaceEditorFeature.plan(for: draft) {
        case .success:
          state.clearValidation()
          return .merge(
            .cancel(id: CancelID.baseRefs),
            .send(.delegate(.commitAdded(draft)))
          )
        case .failure(let error):
          state.validationMessage = error.localizedDescription
          state.validationField = Self.validationField(for: error)
          return .none
        }

      case .delegate:
        return .none
      }
    }
  }

  private func loadBaseRefs(
    for draft: ProjectWorkspaceCreationRepository,
    state: inout State
  ) -> Effect<Action> {
    state.isLoadingBaseRefs = true
    let gitClient = gitClient
    return .run { send in
      let result = await Self.baseRefs(for: draft, gitClient: gitClient)
      await send(
        .baseRefsLoaded(
          sourceLocation: draft.sourceLocation,
          options: result.options,
          defaultBaseRef: result.defaultBaseRef,
          errorMessage: result.errorMessage
        ))
    }
    .cancellable(id: CancelID.baseRefs, cancelInFlight: true)
  }

  nonisolated static func validationField(for error: ProjectWorkspaceCreationError) -> Field? {
    switch error {
    case .missingRepositoryName:
      return .name
    case .missingBranchName:
      return .branchName
    case .missingExistingRef:
      return .baseRef
    case .missingRepositorySource, .missingTitle, .missingPath, .notEnoughRepositories,
      .linkCheckoutUnsupported, .destinationIsFile, .workspaceAlreadyExists,
      .workspaceMetadataMissing, .repositoryDoesNotExist, .linkAlreadyExists, .gitCommandFailed:
      return nil
    }
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

  nonisolated struct BaseRefsResult: Equatable, Sendable {
    var options: [GitBranchRefOption] = []
    var defaultBaseRef: String?
    var errorMessage: String?
  }

  /// Local refs for an opened / local / bare source: the automatic base ref
  /// (default branch) first, then every branch ref, grouped by kind.
  nonisolated static func baseRefs(
    for repository: ProjectWorkspaceCreationRepository,
    gitClient: GitClientDependency
  ) async -> BaseRefsResult {
    switch repository.sourceKind {
    case .remote:
      return BaseRefsResult()

    case .existingPath, .localRepository, .bareRepository:
      guard let sourceURL = repository.localSourceURL else {
        return BaseRefsResult()
      }
      let repositoryURL: URL
      if repository.sourceKind == .bareRepository {
        repositoryURL = sourceURL
      } else {
        repositoryURL = (try? await gitClient.repoRoot(sourceURL)) ?? sourceURL
      }
      async let automaticBaseRefTask = gitClient.automaticWorktreeBaseRef(repositoryURL)
      async let refsTask = gitClient.branchRefOptions(repositoryURL)
      let automaticBaseRef = await automaticBaseRefTask
      let refs: [GitBranchRefOption]
      var errorMessage: String?
      do {
        refs = try await refsTask
      } catch {
        refs = []
        let name = repository.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = name.isEmpty ? repositoryURL.lastPathComponent : name
        errorMessage = String(
          localized: "Could not read branches for \(displayName): \(error.localizedDescription)"
        )
        SupaLogger("workspace").warning(
          "Branch detection failed for \(repositoryURL.path(percentEncoded: false)): \(error)"
        )
      }
      let options = ProjectWorkspaceCreationRepository.baseRefOptions(
        automaticBaseRef: automaticBaseRef,
        options: refs
      )
      let defaultBaseRef =
        automaticBaseRef != nil || !refs.isEmpty
        ? ProjectWorkspaceCreationRepository.preferredBaseRef(
          automaticBaseRef: automaticBaseRef,
          options: options
        )
        : nil
      return BaseRefsResult(
        options: options,
        defaultBaseRef: defaultBaseRef,
        errorMessage: errorMessage
      )
    }
  }
}

private struct RemoteBranchLoadTimeoutError: LocalizedError {
  var errorDescription: String? {
    String(localized: "Remote branch loading timed out.")
  }
}
