import ComposableArchitecture
import Foundation

nonisolated private let workspaceEditingLog = SupaLogger("workspace")

extension RepositoriesFeature {
  func reduceWorkspaceEditing(
    state: inout State,
    action: WorkspaceEditingAction
  ) -> Effect<Action> {
    switch action {
    case .promptRequested(let repositoryID, let removingChildID):
      guard let repository = state.repositories[id: repositoryID],
        let snapshot = repository.workspace,
        !state.removingRepositoryIDs.contains(repositoryID),
        state.workspaceEditor == nil
      else {
        return .none
      }
      let rootURL = repository.rootURL
      return .run { send in
        // Re-read the file so edits made outside Prowl since the last reload
        // are what the editor shows; the loaded snapshot is the fallback.
        let workspace = ProjectWorkspace.load(from: rootURL) ?? snapshot
        await send(
          .workspaceEditing(
            .promptLoaded(repositoryID, workspace, removingChildID: removingChildID)))
      }

    case .promptLoaded(let repositoryID, let workspace, let removingChildID):
      guard let repository = state.repositories[id: repositoryID], state.workspaceEditor == nil
      else {
        return .none
      }
      var editor = WorkspaceEditorFeature.State(
        editing: workspace,
        rootURL: repository.rootURL,
        repositoryID: repositoryID,
        openedRepositoryCandidates: state.workspaceCreationCandidates
      )
      if let removingChildID,
        let entry = workspace.repositories.first(where: { entry in
          entry.resolvedURL(relativeTo: repository.rootURL).path(percentEncoded: false)
            == removingChildID
        })
      {
        editor.existingRepositories[id: entry.id]?.removal = .init()
      }
      state.workspaceEditor = editor
      return .none

    case .promptCanceled, .promptDismissed:
      // Cancel is disabled while saving (cleanup runs after the metadata is
      // committed, so an interrupted save would strand folders); the guard
      // covers a stray cancel. `.dismiss` has already been applied by `ifLet`.
      guard state.workspaceEditor?.isSaving != true else {
        return .none
      }
      state.workspaceEditor = nil
      return .none

    case .saveWorkspace(let request):
      guard case .edit(let repositoryID)? = state.workspaceEditor?.mode else {
        return .none
      }
      state.workspaceEditor?.isSaving = true
      state.workspaceEditor?.validationMessage = nil
      return saveWorkspaceEffect(request, repositoryID: repositoryID)

    case .workspaceSaved(_, let cleanupFailures):
      analyticsClient.capture("workspace_edited", [String: Any]?.none)
      state.workspaceEditor = nil
      if !cleanupFailures.isEmpty {
        state.alert = messageAlert(
          title: String(localized: "Some folders were left in place"),
          message: cleanupFailures.map { "\($0.entryName): \($0.message)" }
            .joined(separator: "\n")
        )
      }
      return .merge(
        .send(.showToast(.success(String(localized: "Workspace saved")))),
        loadRepositories(fallbackRoots: state.repositoryRoots, animated: true)
      )

    case .workspaceSaveFailed(let message):
      guard state.workspaceEditor != nil else {
        // The sheet went away mid-save; the error still needs a home.
        state.alert = messageAlert(title: String(localized: "Unable to save workspace"), message: message)
        return .none
      }
      state.workspaceEditor?.isSaving = false
      state.workspaceEditor?.validationMessage = message
      return .none
    }
  }

  /// Not cancellable on purpose: member cleanup runs after the metadata is
  /// committed, so an interrupted save could leave folders the metadata no
  /// longer references.
  private func saveWorkspaceEffect(
    _ request: ProjectWorkspaceUpdateRequest,
    repositoryID: Repository.ID
  ) -> Effect<Action> {
    let gitRunner = Self.workspaceGitRunner(shellClient: shellClient)
    let gitClient = gitClient
    return .run { send in
      do {
        let result = try await ProjectWorkspace.update(request, gitRunner: gitRunner)
        // The save is committed at this point. Branch deletion goes through
        // the guarded entry point so protected branches survive, exactly like
        // workspace removal; a refused deletion is reported with the other
        // cleanup failures rather than hidden behind the success toast.
        var cleanupFailures = result.cleanupFailures
        for removal in result.completedRemovals where removal.deleteBranch {
          guard let sourceLocation = removal.entry.sourceLocation,
            let branchName = removal.entry.branchName
          else {
            continue
          }
          do {
            let outcome = try await gitClient.deleteLocalBranch(
              branchName,
              URL(fileURLWithPath: sourceLocation),
              true
            )
            if case .protected = outcome {
              workspaceEditingLog.warning(
                "Skipped deleting protected branch \(branchName) in \(sourceLocation)")
            }
          } catch {
            workspaceEditingLog.warning(
              "Could not delete branch \(branchName) in \(sourceLocation): \(error.localizedDescription)")
            cleanupFailures.append(
              ProjectWorkspaceCleanupFailure(
                entryID: removal.entry.id,
                entryName: removal.entry.name,
                message: String(
                  localized: "Branch \(branchName) was not deleted: \(error.localizedDescription)")
              ))
          }
        }
        await send(.workspaceEditing(.workspaceSaved(repositoryID, cleanupFailures: cleanupFailures)))
      } catch {
        workspaceEditingLog.warning("Workspace save failed: \(error.localizedDescription)")
        await send(.workspaceEditing(.workspaceSaveFailed(error.localizedDescription)))
      }
    }
  }

  var workspaceEditingReducer: some Reducer<State, Action> {
    Reduce { state, action in
      guard case .workspaceEditing(let action) = action else {
        return .none
      }
      return reduceWorkspaceEditing(state: &state, action: action)
    }
  }
}
