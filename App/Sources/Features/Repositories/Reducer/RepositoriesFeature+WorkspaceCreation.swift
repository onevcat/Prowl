import ComposableArchitecture
import Foundation

extension RepositoriesFeature.State {
  var workspaceCreationCandidates: [ProjectWorkspaceCreationRepository] {
    repositories.compactMap { repository in
      guard !repository.isWorkspace, !removingRepositoryIDs.contains(repository.id) else {
        return nil
      }
      let name = repositoryCustomTitles[repository.id] ?? repository.name
      return ProjectWorkspaceCreationRepository(
        id: repository.id,
        name: name,
        rootURL: repository.rootURL
      )
    }
  }
}

nonisolated private let workspaceLog = SupaLogger("workspace")

extension RepositoriesFeature {
  func reduceWorkspaceCreation(
    state: inout State,
    action: WorkspaceCreationAction
  ) -> Effect<Action> {
    switch action {
    case .promptRequested:
      // The sheet is one presentation slot: never replace an open editor (and
      // its unsaved edits or in-flight save) with a fresh creation sheet.
      guard state.workspaceEditor == nil else {
        return .none
      }
      let candidates = state.workspaceCreationCandidates
      let title = "Workspace"
      // Seed with the collision-free base path synchronously (pure path math),
      // then resolve a unique, non-colliding folder name off the main actor so
      // the reducer body performs no filesystem I/O.
      let folderName = ProjectWorkspace.defaultWorkspaceFolderName(for: title)
      let requestedRootPath = ProjectWorkspace.workspaceRootPath(folderName: folderName, suffix: nil)
      state.workspaceEditor = WorkspaceEditorFeature.State(
        repositories: [],
        title: title,
        rootPath: requestedRootPath,
        openedRepositoryCandidates: candidates
      )
      return .run { send in
        let resolved = ProjectWorkspace.uniqueWorkspaceRootPath(folderName: folderName)
        await send(.workspaceCreation(.defaultRootPathResolved(path: resolved, requestedRootPath: requestedRootPath)))
      }
      .cancellable(id: CancelID.workspaceRootPathResolution, cancelInFlight: true)

    case .defaultRootPathResolved(let path, let requestedRootPath):
      // Only adopt the de-duplicated path if the user has not edited the field
      // since the prompt opened, and only for the creation sheet: an edit
      // session opened right after a canceled creation must keep its own root.
      guard let editor = state.workspaceEditor, editor.mode == .create,
        editor.rootPath == requestedRootPath
      else {
        return .none
      }
      state.workspaceEditor?.rootPath = path
      return .none

    case .promptCanceled, .promptDismissed:
      let wasCreating = state.workspaceEditor?.isSaving == true
      state.workspaceEditor = nil
      guard wasCreating else {
        return .merge(
          .cancel(id: CancelID.workspaceCreation),
          .cancel(id: CancelID.workspaceRootPathResolution)
        )
      }
      return .merge(
        .cancel(id: CancelID.workspaceCreation),
        .cancel(id: CancelID.workspaceRootPathResolution),
        .send(.showToast(.warning(String(localized: "Workspace creation canceled"))))
      )

    case .createWorkspace(let draft):
      state.workspaceEditor?.isSaving = true
      state.workspaceEditor?.validationMessage = nil
      let request = ProjectWorkspaceCreationRequest(draft: draft, createdAt: now)
      let gitRunner = Self.workspaceGitRunner(shellClient: shellClient)
      return .run { send in
        do {
          _ = try await ProjectWorkspace.create(request, gitRunner: gitRunner)
          await send(.workspaceCreation(.workspaceCreated(request.draft.rootURL)))
        } catch {
          guard !Task.isCancelled else {
            workspaceLog.warning("Workspace creation canceled, rollback finished")
            return
          }
          workspaceLog.warning("Workspace creation failed: \(error.localizedDescription)")
          await send(.workspaceCreation(.workspaceCreationFailed(error.localizedDescription)))
        }
      }
      .cancellable(id: CancelID.workspaceCreation, cancelInFlight: true)

    case .workspaceCreated(let rootURL):
      analyticsClient.capture("workspace_created", [String: Any]?.none)
      state.workspaceEditor = nil
      return .merge(
        .send(.showToast(.success(String(localized: "Workspace created")))),
        .send(.repositoryManagement(.openRepositories([rootURL])))
      )

    case .workspaceCreationFailed(let message):
      if state.workspaceEditor != nil {
        state.workspaceEditor?.isSaving = false
        state.workspaceEditor?.validationMessage = message
      } else {
        state.alert = messageAlert(title: String(localized: "Unable to create workspace"), message: message)
      }
      return .none
    }
  }

  var workspaceCreationReducer: some ReducerOf<Self> {
    Reduce { state, action in
      guard case .workspaceCreation(let action) = action else {
        return .none
      }
      return reduceWorkspaceCreation(state: &state, action: action)
    }
  }

  static func workspaceGitRunner(
    shellClient: ShellClient,
    resolveGit: @escaping @Sendable () async throws -> GitExecutable = {
      try await GitExecutableResolver.shared.resolve()
    }
  ) -> ProjectWorkspaceGitRunner {
    ProjectWorkspaceGitRunner { command in
      let git = try await resolveGit()
      do {
        _ = try await shellClient.runLogin(
          URL(fileURLWithPath: "/usr/bin/env"),
          git.environmentArguments + [git.url.path(percentEncoded: false)] + command.arguments,
          command.currentDirectoryURL
        )
      } catch let error as ShellClientError {
        throw ProjectWorkspaceCreationError.gitCommandFailed(
          command: command.displayCommand,
          message: error.stderr.isEmpty ? error.stdout : error.stderr
        )
      } catch {
        throw error
      }
    }
  }
}
