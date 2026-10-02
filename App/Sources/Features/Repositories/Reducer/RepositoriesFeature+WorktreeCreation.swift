import ComposableArchitecture
import Foundation

extension RepositoriesFeature {
  // swiftlint:disable:next cyclomatic_complexity function_body_length
  func reduceWorktreeCreation(
    state: inout State,
    action: WorktreeCreationAction
  ) -> Effect<Action> {
    switch action {
    case .promptCanceled, .promptDismissed:
      state.worktreeCreationPrompt = nil
      return .merge(
        .cancel(id: CancelID.worktreePromptLoad),
        .cancel(id: CancelID.worktreePromptValidation),
        .cancel(id: CancelID.branchNameSuggestion)
      )

    case .createRandomWorktree:
      if let selectedRepository = state.selectedRepository,
        !selectedRepository.capabilities.supportsWorktrees
      {
        state.alert = messageAlert(
          title: String(localized: "Unable to create worktree"),
          message: String(localized: "This folder doesn't support worktrees.")
        )
        return .none
      }
      guard let repository = repositoryForWorktreeCreation(state) else {
        let message: String
        if state.repositories.isEmpty {
          message = String(localized: "Open a repository to create a worktree.")
        } else if state.selectedWorktreeID == nil && state.repositories.count > 1 {
          message = String(localized: "Select a worktree to choose which repository to use.")
        } else {
          message = String(localized: "Unable to resolve a repository for the new worktree.")
        }
        state.alert = messageAlert(title: String(localized: "Unable to create worktree"), message: message)
        return .none
      }
      return .send(.worktreeCreation(.createRandomWorktreeInRepository(repository.id)))

    case .createRandomWorktreeInRepository(let repositoryID):
      guard let repository = state.repositories[id: repositoryID] else {
        state.alert = messageAlert(
          title: String(localized: "Unable to create worktree"),
          message: String(localized: "Unable to resolve a repository for the new worktree.")
        )
        return .none
      }
      guard repository.capabilities.supportsWorktrees else {
        state.alert = messageAlert(
          title: String(localized: "Unable to create worktree"),
          message: String(localized: "This folder doesn't support worktrees.")
        )
        return .none
      }
      if state.removingRepositoryIDs.contains(repository.id) {
        state.alert = messageAlert(
          title: String(localized: "Unable to create worktree"),
          message: String(localized: "This repository is being removed.")
        )
        return .none
      }
      @Shared(.settingsFile) var settingsFile
      if !settingsFile.global.promptForWorktreeCreation {
        return .merge(
          .cancel(id: CancelID.worktreePromptLoad),
          .send(
            .worktreeCreation(
              .createWorktreeInRepository(
                repositoryID: repository.id,
                nameSource: .random,
                baseRefSource: .repositorySetting,
                fetchRemote: settingsFile.global.fetchOriginBeforeWorktreeCreation
              )
            )
          )
        )
      }
      @Shared(.repositorySettings(repository.rootURL)) var repositorySettings
      let selectedBaseRef = repositorySettings.worktreeBaseRef
      let gitClient = gitClient
      let rootURL = repository.rootURL
      return .run { send in
        let automaticBaseRef = await gitClient.automaticWorktreeBaseRef(rootURL) ?? "HEAD"
        guard !Task.isCancelled else {
          return
        }
        let baseRefOptions: [String]
        do {
          let refs = try await gitClient.branchRefs(rootURL)
          guard !Task.isCancelled else {
            return
          }
          var options = refs
          if !automaticBaseRef.isEmpty, !options.contains(automaticBaseRef) {
            options.append(automaticBaseRef)
          }
          if let selectedBaseRef, !selectedBaseRef.isEmpty, !options.contains(selectedBaseRef) {
            options.append(selectedBaseRef)
          }
          baseRefOptions = options.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        } catch {
          guard !Task.isCancelled else {
            return
          }
          var options: [String] = []
          if !automaticBaseRef.isEmpty {
            options.append(automaticBaseRef)
          }
          if let selectedBaseRef, !selectedBaseRef.isEmpty, !options.contains(selectedBaseRef) {
            options.append(selectedBaseRef)
          }
          baseRefOptions = options
        }
        guard !Task.isCancelled else {
          return
        }
        await send(
          .worktreeCreation(
            .promptedWorktreeCreationDataLoaded(
              repositoryID: repositoryID,
              baseRefOptions: baseRefOptions,
              automaticBaseRef: automaticBaseRef,
              selectedBaseRef: selectedBaseRef
            )
          )
        )
      }
      .cancellable(id: CancelID.worktreePromptLoad, cancelInFlight: true)

    case .promptedWorktreeCreationDataLoaded(
      let repositoryID,
      let baseRefOptions,
      let automaticBaseRef,
      let selectedBaseRef
    ):
      guard let repository = state.repositories[id: repositoryID] else {
        return .none
      }
      @Shared(.settingsFile) var settingsFile
      @Shared(.repositorySettings(repository.rootURL)) var repositorySettings
      let defaultWorktreeBaseDirectory = SupacodePaths.worktreeBaseDirectory(
        for: repository.rootURL,
        globalDefaultPath: settingsFile.global.defaultWorktreeBaseDirectoryPath,
        repositoryOverridePath: repositorySettings.worktreeBaseDirectoryPath
      )
      let existingNames = Set(
        repository.worktrees.map(\.name) + baseRefOptions
      )
      let randomPlaceholder =
        WorktreeNameGenerator.nextName(excluding: existingNames)
        ?? "new-worktree"
      state.worktreeCreationPrompt = WorktreeCreationPromptFeature.State(
        repositoryID: repository.id,
        repositoryRootURL: repository.rootURL,
        repositoryName: repository.name,
        automaticBaseRef: automaticBaseRef,
        baseRefOptions: baseRefOptions,
        branchName: "",
        selectedBaseRef: selectedBaseRef,
        fetchRemote: settingsFile.global.fetchOriginBeforeWorktreeCreation,
        defaultWorktreeBaseDirectory: defaultWorktreeBaseDirectory.path(percentEncoded: false),
        validationMessage: nil,
        isSuggestingName: true,
        randomPlaceholder: randomPlaceholder
      )
      let branchNameSuggestionClient = branchNameSuggestionClient
      let repositoryName = repository.name
      let repositoryRootURL = repository.rootURL
      return .run { send in
        let context = await branchNameSuggestionClient.gatherContext(
          repositoryName,
          repositoryRootURL,
          baseRefOptions
        )
        let suggestion = await branchNameSuggestionClient.suggest(context)
        await send(.worktreeCreationPrompt(.presented(.branchNameSuggestionReceived(suggestion))))
      }
      .cancellable(id: CancelID.branchNameSuggestion, cancelInFlight: true)

    case .startPromptedWorktreeCreation(let repositoryID, let branchName, let baseRef, let placement):
      guard let repository = state.repositories[id: repositoryID] else {
        state.worktreeCreationPrompt = nil
        state.alert = messageAlert(
          title: String(localized: "Unable to create worktree"),
          message: String(localized: "Unable to resolve a repository for the new worktree.")
        )
        return .none
      }
      @Shared(.settingsFile) var settingsFile
      let fetchRemote =
        state.worktreeCreationPrompt?.fetchRemote ?? settingsFile.global.fetchOriginBeforeWorktreeCreation
      state.worktreeCreationPrompt?.validationMessage = nil
      state.worktreeCreationPrompt?.isValidating = true
      let normalizedBranchName = branchName.lowercased()
      if repository.worktrees.contains(where: { $0.name.lowercased() == normalizedBranchName }) {
        state.worktreeCreationPrompt?.isValidating = false
        state.worktreeCreationPrompt?.validationMessage = String(localized: "Branch name already exists.")
        return .none
      }
      let gitClient = gitClient
      let rootURL = repository.rootURL
      return .run { send in
        let localBranchNames = (try? await gitClient.localBranchNames(rootURL)) ?? []
        let duplicateMessage =
          localBranchNames.contains(normalizedBranchName)
          ? String(localized: "Branch name already exists.")
          : nil
        await send(
          .worktreeCreation(
            .promptedWorktreeCreationChecked(
              repositoryID: repositoryID,
              branchName: branchName,
              baseRef: baseRef,
              fetchRemote: fetchRemote,
              placement: placement,
              duplicateMessage: duplicateMessage
            )
          )
        )
      }
      .cancellable(id: CancelID.worktreePromptValidation, cancelInFlight: true)

    case .promptedWorktreeCreationChecked(
      let repositoryID,
      let branchName,
      let baseRef,
      let fetchRemote,
      let placement,
      let duplicateMessage
    ):
      guard let prompt = state.worktreeCreationPrompt, prompt.repositoryID == repositoryID else {
        return .none
      }
      state.worktreeCreationPrompt?.isValidating = false
      if let duplicateMessage {
        state.worktreeCreationPrompt?.validationMessage = duplicateMessage
        return .none
      }
      state.worktreeCreationPrompt = nil
      return .send(
        .worktreeCreation(
          .createWorktreeInRepository(
            repositoryID: repositoryID,
            nameSource: .explicit(branchName),
            baseRefSource: .explicit(baseRef),
            fetchRemote: fetchRemote,
            placement: placement
          )
        )
      )

    case .createWorktreeInRepository(
      let repositoryID, let nameSource, let baseRefSource, let fetchRemote, let placement):
      guard let repository = state.repositories[id: repositoryID] else {
        state.alert = messageAlert(
          title: String(localized: "Unable to create worktree"),
          message: String(localized: "Unable to resolve a repository for the new worktree.")
        )
        return .none
      }
      if state.removingRepositoryIDs.contains(repository.id) {
        state.alert = messageAlert(
          title: String(localized: "Unable to create worktree"),
          message: String(localized: "This repository is being removed.")
        )
        return .none
      }
      let previousSelection = state.selectedWorktreeID
      let pendingID = "pending:\(uuid().uuidString)"
      @Shared(.settingsFile) var settingsFile
      @Shared(.repositorySettings(repository.rootURL)) var repositorySettings
      let globalDefaultWorktreeBaseDirectoryPath = settingsFile.global.defaultWorktreeBaseDirectoryPath
      let worktreeBaseDirectory = SupacodePaths.worktreeBaseDirectory(
        for: repository.rootURL,
        globalDefaultPath: globalDefaultWorktreeBaseDirectoryPath,
        repositoryOverridePath: repositorySettings.worktreeBaseDirectoryPath
      )
      let selectedBaseRef = repositorySettings.worktreeBaseRef
      let copyIgnoredOnWorktreeCreate =
        repositorySettings.copyIgnoredOnWorktreeCreate ?? settingsFile.global.copyIgnoredOnWorktreeCreate
      let copyUntrackedOnWorktreeCreate =
        repositorySettings.copyUntrackedOnWorktreeCreate ?? settingsFile.global.copyUntrackedOnWorktreeCreate
      state.pendingWorktrees.append(
        PendingWorktree(
          id: pendingID,
          repositoryID: repository.id,
          progress: WorktreeCreationProgress(stage: .loadingLocalBranches)
        )
      )
      setSingleWorktreeSelection(pendingID, state: &state, recordHistory: true)
      let existingNames = Set(repository.worktrees.map { $0.name.lowercased() })
      let createWorktreeStream = gitClient.createWorktreeStream
      let isValidBranchName = gitClient.isValidBranchName
      return .run { send in
        var newWorktreeName: String?
        var progress = WorktreeCreationProgress(stage: .loadingLocalBranches)
        var progressUpdateThrottle = WorktreeCreationProgressUpdateThrottle(
          stride: worktreeCreationProgressUpdateStride
        )
        do {
          await send(
            .worktreeCreation(
              .pendingWorktreeProgressUpdated(
                id: pendingID,
                progress: progress
              )
            )
          )
          let branchNames = try await gitClient.localBranchNames(repository.rootURL)
          let existing = existingNames.union(branchNames)
          let name: String
          switch nameSource {
          case .random:
            progress.stage = .choosingWorktreeName
            await send(
              .worktreeCreation(
                .pendingWorktreeProgressUpdated(
                  id: pendingID,
                  progress: progress
                )
              )
            )
            let generatedName = await MainActor.run {
              WorktreeNameGenerator.nextName(excluding: existing)
            }
            guard let generatedName else {
              let message = String(
                localized: """
                  All default adjective-animal names are already in use. \
                  Delete a worktree or rename a branch, then try again.
                  """
              )
              await send(
                .worktreeCreation(
                  .createRandomWorktreeFailed(
                    title: String(localized: "No available worktree names"),
                    message: message,
                    pendingID: pendingID,
                    previousSelection: previousSelection,
                    repositoryID: repository.id,
                    name: nil,
                    baseDirectory: worktreeBaseDirectory
                  )
                )
              )
              return
            }
            name = generatedName
          case .explicit(let explicitName):
            let trimmed = explicitName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
              await send(
                .worktreeCreation(
                  .createRandomWorktreeFailed(
                    title: String(localized: "Branch name required"),
                    message: String(localized: "Enter a branch name to create a worktree."),
                    pendingID: pendingID,
                    previousSelection: previousSelection,
                    repositoryID: repository.id,
                    name: nil,
                    baseDirectory: worktreeBaseDirectory
                  )
                )
              )
              return
            }
            guard !trimmed.contains(where: \.isWhitespace) else {
              await send(
                .worktreeCreation(
                  .createRandomWorktreeFailed(
                    title: String(localized: "Branch name invalid"),
                    message: String(localized: "Branch names can't contain spaces."),
                    pendingID: pendingID,
                    previousSelection: previousSelection,
                    repositoryID: repository.id,
                    name: nil,
                    baseDirectory: worktreeBaseDirectory
                  )
                )
              )
              return
            }
            guard await isValidBranchName(trimmed, repository.rootURL) else {
              await send(
                .worktreeCreation(
                  .createRandomWorktreeFailed(
                    title: String(localized: "Branch name invalid"),
                    message: String(localized: "Enter a valid git branch name and try again."),
                    pendingID: pendingID,
                    previousSelection: previousSelection,
                    repositoryID: repository.id,
                    name: nil,
                    baseDirectory: worktreeBaseDirectory
                  )
                )
              )
              return
            }
            guard !existing.contains(trimmed.lowercased()) else {
              await send(
                .worktreeCreation(
                  .createRandomWorktreeFailed(
                    title: String(localized: "Branch name already exists"),
                    message: String(localized: "Choose a different branch name and try again."),
                    pendingID: pendingID,
                    previousSelection: previousSelection,
                    repositoryID: repository.id,
                    name: nil,
                    baseDirectory: worktreeBaseDirectory
                  )
                )
              )
              return
            }
            name = trimmed
          }
          newWorktreeName = name
          progress.worktreeName = name
          progress.stage = .checkingRepositoryMode
          await send(
            .worktreeCreation(
              .pendingWorktreeProgressUpdated(
                id: pendingID,
                progress: progress
              )
            )
          )
          let isBareRepository = (try? await gitClient.isBareRepository(repository.rootURL)) ?? false
          let copyIgnored = isBareRepository ? false : copyIgnoredOnWorktreeCreate
          let copyUntracked = isBareRepository ? false : copyUntrackedOnWorktreeCreate
          progress.stage = .resolvingBaseReference
          await send(
            .worktreeCreation(
              .pendingWorktreeProgressUpdated(
                id: pendingID,
                progress: progress
              )
            )
          )
          let resolvedBaseRef: String
          switch baseRefSource {
          case .repositorySetting:
            if (selectedBaseRef ?? "").isEmpty {
              resolvedBaseRef = await gitClient.automaticWorktreeBaseRef(repository.rootURL) ?? ""
            } else {
              resolvedBaseRef = selectedBaseRef ?? ""
            }
          case .explicit(let explicitBaseRef):
            if let explicitBaseRef, !explicitBaseRef.isEmpty {
              resolvedBaseRef = explicitBaseRef
            } else {
              resolvedBaseRef = await gitClient.automaticWorktreeBaseRef(repository.rootURL) ?? ""
            }
          }
          progress.baseRef = resolvedBaseRef
          if fetchRemote, !resolvedBaseRef.isEmpty {
            do {
              let remotes = try await gitClient.remoteNames(repository.rootURL)
              if let matchedRemote = GitRemoteMatcher.matchingRemote(for: resolvedBaseRef, from: remotes) {
                progress.fetchRemoteName = matchedRemote
                progress.stage = .fetchingRemote
                await send(
                  .worktreeCreation(
                    .pendingWorktreeProgressUpdated(
                      id: pendingID,
                      progress: progress
                    )
                  )
                )
                try await gitClient.fetchRemote(matchedRemote, repository.rootURL)
              }
            } catch {
              let errorMessage = "git fetch failed: \(error.localizedDescription)"
              worktreeCreationLogger.warning(errorMessage)
              progress.appendOutputLine(errorMessage, maxLines: worktreeCreationProgressLineLimit)
            }
          }
          progress.copyIgnored = copyIgnored
          progress.copyUntracked = copyUntracked
          progress.ignoredFilesToCopyCount =
            copyIgnored ? ((try? await gitClient.ignoredFileCount(repository.rootURL)) ?? 0) : 0
          progress.untrackedFilesToCopyCount =
            copyUntracked ? ((try? await gitClient.untrackedFileCount(repository.rootURL)) ?? 0) : 0
          // Resolve an explicit destination from the dialog's name / parent-folder
          // overrides; nil keeps `wt`'s default `base/<branch>` placement.
          let directoryOverride = SupacodePaths.resolvedWorktreeDirectory(
            defaultBaseDirectory: worktreeBaseDirectory,
            repositoryRootURL: repository.rootURL,
            nameOverride: placement.name,
            pathOverride: placement.path,
            branchName: name
          )
          progress.stage = .creatingWorktree
          progress.commandText = worktreeCreateCommand(
            baseDirectoryURL: worktreeBaseDirectory,
            name: name,
            copyIgnored: copyIgnored,
            copyUntracked: copyUntracked,
            baseRef: resolvedBaseRef,
            directoryOverride: directoryOverride
          )
          await send(
            .worktreeCreation(
              .pendingWorktreeProgressUpdated(
                id: pendingID,
                progress: progress
              )
            )
          )
          let stream = createWorktreeStream(
            GitWorktreeCreateRequest(
              name: name,
              repoRoot: repository.rootURL,
              baseDirectory: worktreeBaseDirectory,
              copyFiles: GitWorktreeCreateRequest.CopyFiles(ignored: copyIgnored, untracked: copyUntracked),
              baseRef: resolvedBaseRef,
              directoryOverride: directoryOverride
            )
          )
          for try await event in stream {
            switch event {
            case .outputLine(let outputLine):
              let line = outputLine.text.trimmingCharacters(in: .whitespacesAndNewlines)
              guard !line.isEmpty else {
                continue
              }
              progress.appendOutputLine(line, maxLines: worktreeCreationProgressLineLimit)
              if progressUpdateThrottle.recordLine() {
                await send(
                  .worktreeCreation(
                    .pendingWorktreeProgressUpdated(
                      id: pendingID,
                      progress: progress
                    )
                  )
                )
              }
            case .finished(let newWorktree):
              if progressUpdateThrottle.flush() {
                await send(
                  .worktreeCreation(
                    .pendingWorktreeProgressUpdated(
                      id: pendingID,
                      progress: progress
                    )
                  )
                )
              }
              await send(
                .worktreeCreation(
                  .createRandomWorktreeSucceeded(
                    newWorktree,
                    repositoryID: repository.id,
                    pendingID: pendingID
                  )
                )
              )
              return
            }
          }
          throw GitClientError.commandFailed(
            command: "wt sw",
            message: String(localized: "Worktree creation finished without a result.")
          )
        } catch {
          if progressUpdateThrottle.flush() {
            await send(
              .worktreeCreation(
                .pendingWorktreeProgressUpdated(
                  id: pendingID,
                  progress: progress
                )
              )
            )
          }
          await send(
            .worktreeCreation(
              .createRandomWorktreeFailed(
                title: String(localized: "Unable to create worktree"),
                message: error.localizedDescription,
                pendingID: pendingID,
                previousSelection: previousSelection,
                repositoryID: repository.id,
                name: newWorktreeName,
                baseDirectory: worktreeBaseDirectory
              )
            )
          )
        }
      }

    case .pendingWorktreeProgressUpdated(let id, let progress):
      updatePendingWorktreeProgress(id, progress: progress, state: &state)
      return .none

    case .createRandomWorktreeSucceeded(
      let worktree,
      let repositoryID,
      let pendingID
    ):
      analyticsClient.capture("worktree_created", [String: Any]?.none)
      state.pendingSetupScriptWorktreeIDs.insert(worktree.id)
      state.pendingTerminalFocusWorktreeIDs.insert(worktree.id)
      state.$prowlCreatedWorktreeIDs.withLock {
        if !$0.contains(worktree.id) {
          $0.append(worktree.id)
        }
      }
      removePendingWorktree(pendingID, state: &state)
      if state.selection == .worktree(pendingID) {
        setSingleWorktreeSelection(worktree.id, state: &state, recordHistory: false)
      }
      insertWorktree(worktree, repositoryID: repositoryID, state: &state)
      return .merge(
        .send(.reloadRepositories(animated: false)),
        .send(.delegate(.repositoriesChanged(state.repositories))),
        .send(.delegate(.selectedWorktreeChanged(state.worktree(for: state.selectedWorktreeID)))),
        .send(.delegate(.worktreeCreated(worktree)))
      )

    case .createRandomWorktreeFailed(
      let title,
      let message,
      let pendingID,
      let previousSelection,
      let repositoryID,
      let name,
      let baseDirectory
    ):
      let previousSelectedWorktree = state.worktree(for: previousSelection)
      removePendingWorktree(pendingID, state: &state)
      restoreSelection(previousSelection, pendingID: pendingID, state: &state)
      let cleanup = cleanupFailedWorktree(
        repositoryID: repositoryID,
        name: name,
        baseDirectory: baseDirectory,
        state: &state
      )
      state.alert = messageAlert(title: title, message: message)
      let selectedWorktree = state.worktree(for: state.selectedWorktreeID)
      let selectionChanged = selectionDidChange(
        previousSelectionID: previousSelection,
        previousSelectedWorktree: previousSelectedWorktree,
        selectedWorktreeID: state.selectedWorktreeID,
        selectedWorktree: selectedWorktree
      )
      var effects: [Effect<Action>] = []
      if cleanup.didRemoveWorktree {
        effects.append(.send(.delegate(.repositoriesChanged(state.repositories))))
      }
      if selectionChanged {
        effects.append(.send(.delegate(.selectedWorktreeChanged(selectedWorktree))))
      }
      if cleanup.didUpdatePinned {
        let pinnedWorktreeIDs = state.pinnedWorktreeIDs
        effects.append(
          .run { _ in
            await repositoryPersistence.savePinnedWorktreeIDs(pinnedWorktreeIDs)
          }
        )
      }
      if cleanup.didUpdateOrder {
        let worktreeOrderByRepository = state.worktreeOrderByRepository
        effects.append(
          .run { _ in
            await repositoryPersistence.saveWorktreeOrderByRepository(worktreeOrderByRepository)
          }
        )
      }
      if let cleanupWorktree = cleanup.worktree {
        let repositoryRootURL = cleanupWorktree.repositoryRootURL
        effects.append(
          .run { send in
            _ = try? await gitClient.removeWorktree(cleanupWorktree, false)
            _ = try? await gitClient.pruneWorktrees(repositoryRootURL)
            await send(.reloadRepositories(animated: true))
          }
        )
      }
      return .merge(effects)

    case .consumeSetupScript(let id):
      state.pendingSetupScriptWorktreeIDs.remove(id)
      return .none

    case .consumeTerminalFocus(let id):
      state.pendingTerminalFocusWorktreeIDs.remove(id)
      return .none
    }
  }

  var worktreeCreationReducer: some ReducerOf<Self> {
    Reduce { state, action in
      guard case .worktreeCreation(let action) = action else {
        return .none
      }
      return reduceWorktreeCreation(state: &state, action: action)
    }
  }
}

private nonisolated let worktreeCreationLogger = SupaLogger("WorktreeCreation")
