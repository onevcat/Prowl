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

enum WorkspaceEditorSubmission: Equatable, Sendable {
  case create(ProjectWorkspaceCreationDraft)
  case update(ProjectWorkspaceUpdateRequest)
}

/// Identifies one row of the editor across both member collections so a
/// single order can interleave existing and added members.
enum WorkspaceEditorMemberKey: Equatable, Hashable, Sendable {
  case existing(String)
  case added(Repository.ID)
}

enum WorkspaceEditorMember: Equatable, Identifiable {
  case existing(WorkspaceEditorExistingRepository)
  case added(ProjectWorkspaceCreationRepository)

  var id: WorkspaceEditorMemberKey {
    switch self {
    case .existing(let repository):
      return .existing(repository.id)
    case .added(let repository):
      return .added(repository.id)
    }
  }
}

/// The first level of the workspace editor: metadata plus the member list.
/// Per-repository configuration happens in `WorkspaceMemberEditorFeature`,
/// presented one row at a time.
@Reducer
struct WorkspaceEditorFeature {
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
    /// One link or identifier per line.
    var taskLinksText: String
    var rootPath: String
    var isRootPathDirty = false
    var validationMessage: String?
    var validationTarget: ValidationTarget?
    var isSaving = false
    /// Explicit member order, changed only by move actions. Keys for rows
    /// that were added since the last move are appended by `orderedMemberKeys`,
    /// existing members first, so add/remove never have to touch it.
    var memberOrder: [WorkspaceEditorMemberKey] = []
    @Presents var memberEditor: WorkspaceMemberEditorFeature.State?

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

    var taskLinks: [String] {
      taskLinksText.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    }

    /// `memberOrder` reconciled with the rows that currently exist: stale
    /// keys drop out, new rows append (existing members before added ones).
    var orderedMemberKeys: [WorkspaceEditorMemberKey] {
      let present =
        Set(existingRepositories.ids.map(WorkspaceEditorMemberKey.existing))
        .union(repositories.ids.map(WorkspaceEditorMemberKey.added))
      var keys = memberOrder.filter { present.contains($0) }
      var seen = Set(keys)
      for id in existingRepositories.ids where seen.insert(.existing(id)).inserted {
        keys.append(.existing(id))
      }
      for id in repositories.ids where seen.insert(.added(id)).inserted {
        keys.append(.added(id))
      }
      return keys
    }

    var orderedMembers: [WorkspaceEditorMember] {
      orderedMemberKeys.compactMap { key in
        switch key {
        case .existing(let id):
          return existingRepositories[id: id].map(WorkspaceEditorMember.existing)
        case .added(let id):
          return repositories[id: id].map(WorkspaceEditorMember.added)
        }
      }
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
      taskLinksText = ""
      self.rootPath = rootPath
    }

    init(
      editing workspace: ProjectWorkspace,
      rootURL: URL,
      repositoryID: Repository.ID,
      openedRepositoryCandidates: [ProjectWorkspaceCreationRepository] = []
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
      taskLinksText = workspace.taskLinks.joined(separator: "\n")
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
    }
  }

  enum ValidationTarget: Equatable, Sendable {
    case title
    case rootPath
    case repositories
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    case titleChanged(String)
    case descriptionChanged(String)
    case taskLinksTextChanged(String)
    case automaticRootPathResolved(path: String, requestedRootPath: String)
    case rootPathChosen(String)
    case addRepositoryButtonTapped
    case editMember(WorkspaceEditorMemberKey)
    case removeMember(WorkspaceEditorMemberKey)
    case undoRemoval(String)
    case memberMovedUp(WorkspaceEditorMemberKey)
    case memberMovedDown(WorkspaceEditorMemberKey)
    case memberEditor(PresentationAction<WorkspaceMemberEditorFeature.Action>)
    case cancelButtonTapped
    case submitButtonTapped
    case delegate(Delegate)
  }

  @CasePathable
  enum Delegate: Equatable {
    case cancel
    case submit(WorkspaceEditorSubmission)
  }

  @Dependency(\.date.now) var now

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

      case .taskLinksTextChanged(let text):
        state.taskLinksText = text
        state.clearValidation()
        return .none

      case .automaticRootPathResolved(let path, let requestedRootPath):
        guard !state.isRootPathDirty, state.rootPath == requestedRootPath else {
          return .none
        }
        state.rootPath = path
        return .none

      case .rootPathChosen(let path):
        state.rootPath = path
        state.isRootPathDirty = true
        state.clearValidation()
        return .none

      case .addRepositoryButtonTapped:
        state.memberEditor = .add(openedCandidates: state.availableOpenedRepositories)
        state.clearValidation()
        return .none

      case .editMember(let key):
        switch key {
        case .existing(let id):
          guard let existing = state.existingRepositories[id: id] else { return .none }
          state.memberEditor = .editExisting(existing)
        case .added(let id):
          guard let draft = state.repositories[id: id] else { return .none }
          state.memberEditor = .editAdded(draft)
        }
        state.clearValidation()
        return .none

      case .removeMember(let key):
        switch key {
        case .existing(let id):
          guard state.existingRepositories[id: id] != nil else { return .none }
          state.existingRepositories[id: id]?.removal = .init()
        case .added(let id):
          state.repositories.remove(id: id)
        }
        state.clearValidation()
        return .none

      case .undoRemoval(let id):
        state.existingRepositories[id: id]?.removal = nil
        state.clearValidation()
        return .none

      case .memberMovedUp(let key):
        var keys = state.orderedMemberKeys
        guard let index = keys.firstIndex(of: key), index > 0 else {
          return .none
        }
        keys.swapAt(index, index - 1)
        state.memberOrder = keys
        return .none

      case .memberMovedDown(let key):
        var keys = state.orderedMemberKeys
        guard let index = keys.firstIndex(of: key), index < keys.count - 1 else {
          return .none
        }
        keys.swapAt(index, index + 1)
        state.memberOrder = keys
        return .none

      case .memberEditor(.presented(.delegate(.cancel))):
        state.memberEditor = nil
        return .none

      case .memberEditor(.presented(.delegate(.commitAdded(let draft)))):
        // A re-edited row keeps its place; a new row appends.
        if state.repositories[id: draft.id] != nil {
          state.repositories[id: draft.id] = draft
        } else {
          state.repositories.append(draft)
        }
        state.memberEditor = nil
        state.clearValidation()
        return .none

      case .memberEditor(.presented(.delegate(.commitExisting(let existing)))):
        if state.existingRepositories[id: existing.id] != nil {
          state.existingRepositories[id: existing.id] = existing
        }
        state.memberEditor = nil
        state.clearValidation()
        return .none

      case .memberEditor(.presented(.delegate(.removeAdded(let id)))):
        state.repositories.remove(id: id)
        state.memberEditor = nil
        state.clearValidation()
        return .none

      case .memberEditor:
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
            target: .repositories
          )
          return .none
        }
        // Rows are validated when they are added; a stale draft is still
        // reported here rather than reaching the domain.
        var plansByID: [Repository.ID: ProjectWorkspaceRepositoryPlan] = [:]
        for repository in state.repositories {
          switch Self.plan(for: repository) {
          case .success(let plan):
            plansByID[repository.id] = plan
          case .failure(let error):
            state.setValidation(error.localizedDescription, target: .repositories)
            return .none
          }
        }
        state.clearValidation()
        let description = state.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let taskLinks = state.taskLinks
        // Both submissions follow the user's row order, interleaving existing
        // and added members.
        let orderedKeys = state.orderedMemberKeys
        switch state.mode {
        case .create:
          let plans = orderedKeys.compactMap { key -> ProjectWorkspaceRepositoryPlan? in
            guard case .added(let id) = key else { return nil }
            return plansByID[id]
          }
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
          let members: [ProjectWorkspaceUpdateMember] = orderedKeys.compactMap { key in
            switch key {
            case .existing(let id):
              guard let repository = state.existingRepositories[id: id], !repository.isMarkedForRemoval
              else {
                return nil
              }
              return .existing(repository.editedEntry)
            case .added(let id):
              return plansByID[id].map { .added($0) }
            }
          }
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
    .ifLet(\.$memberEditor, action: \.memberEditor) {
      WorkspaceMemberEditorFeature()
    }
  }

  static func defaultRepositoryName(for url: URL) -> String {
    let name = Repository.name(for: url)
    guard name.count > 4, name.hasSuffix(".git") else {
      return name
    }
    return String(name.dropLast(4))
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
