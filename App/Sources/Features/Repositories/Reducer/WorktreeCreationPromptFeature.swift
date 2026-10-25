import ComposableArchitecture
import Foundation

@Reducer
struct WorktreeCreationPromptFeature {
  @ObservableState
  struct State: Equatable {
    let repositoryID: Repository.ID
    /// How the repository places worktrees: the canonical local root, or the remote
    /// repository's path and its host's home. The preview resolves overrides the same way
    /// the reducer does.
    let placement: WorktreePlacement
    let repositoryName: String
    let automaticBaseRef: String
    let baseRefOptions: [String]
    var branchName: String
    var selectedBaseRef: String?
    var fetchRemote: Bool
    /// Resolved default base directory, used to compute the location preview.
    let defaultWorktreeBaseDirectory: String
    /// Leaf folder name override; empty falls back to the branch name.
    var worktreeNameOverride: String = ""
    /// Parent directory override; empty falls back to `defaultWorktreeBaseDirectory`.
    var worktreePathOverride: String = ""
    /// Disclosure state for the advanced placement section. Collapsed by default.
    var showAdvancedOptions: Bool = false
    var validationMessage: String?
    var isValidating = false
    var isSuggestingName = false
    var suggestedBranchName: String?
    let randomPlaceholder: String

    var effectiveBranchName: String {
      let trimmed = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? randomPlaceholder : trimmed
    }

    var automaticBaseRefLabel: String {
      automaticBaseRef.isEmpty
        ? String(localized: "Automatic") : String(localized: "Automatic (\(automaticBaseRef))")
    }

    /// Default leaf folder name shown as the name-override placeholder.
    var worktreeNamePlaceholder: String {
      effectiveBranchName
    }

    /// Live validity of the current name override, so the footer can flag an
    /// invalid leaf instead of previewing a destination submit will reject.
    var worktreeNameValidationError: String? {
      WorktreePlacementOverride.nameValidationError(worktreeNameOverride)
    }

    /// Full destination path the worktree will be created at, mirroring the
    /// reducer's resolution.
    var resolvedWorktreeLocationPreview: String {
      placement.previewDirectory(
        defaultBaseDirectory: URL(filePath: defaultWorktreeBaseDirectory, directoryHint: .isDirectory),
        nameOverride: worktreeNameOverride,
        pathOverride: worktreePathOverride,
        branchName: effectiveBranchName
      )
      .path(percentEncoded: false)
    }
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    case cancelButtonTapped
    case createButtonTapped
    case setValidationMessage(String?)
    case setValidating(Bool)
    case branchNameSuggestionReceived(String?)
    case useSuggestedBranchName
    case delegate(Delegate)
  }

  @CasePathable
  enum Delegate: Equatable {
    case cancel
    case submit(
      repositoryID: Repository.ID,
      branchName: String,
      baseRef: String?,
      placement: WorktreePlacementOverride
    )
  }

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        state.validationMessage = nil
        return .none

      case .cancelButtonTapped:
        return .send(.delegate(.cancel))

      case .createButtonTapped:
        let effective = state.effectiveBranchName
        guard !effective.contains(where: \.isWhitespace) else {
          state.validationMessage = String(localized: "Branch names can't contain spaces.")
          return .none
        }
        let nameOverride = state.worktreeNameOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if let nameError = WorktreePlacementOverride.nameValidationError(nameOverride) {
          state.validationMessage = nameError
          return .none
        }
        state.validationMessage = nil
        let pathOverride = state.worktreePathOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        return .send(
          .delegate(
            .submit(
              repositoryID: state.repositoryID,
              branchName: effective,
              baseRef: state.selectedBaseRef,
              placement: WorktreePlacementOverride(
                name: nameOverride.isEmpty ? nil : nameOverride,
                path: pathOverride.isEmpty ? nil : pathOverride
              )
            )
          )
        )

      case .setValidationMessage(let message):
        state.validationMessage = message
        return .none

      case .setValidating(let isValidating):
        state.isValidating = isValidating
        return .none

      case .branchNameSuggestionReceived(let name):
        state.isSuggestingName = false
        state.suggestedBranchName = name
        return .none

      case .useSuggestedBranchName:
        if let name = state.suggestedBranchName {
          state.branchName = name
        }
        return .none

      case .delegate:
        return .none
      }
    }
  }
}

extension WorktreeCreationPromptFeature.State {
  /// A prompt for a local repository.
  init(
    repositoryID: Repository.ID,
    repositoryRootURL: URL,
    repositoryName: String,
    automaticBaseRef: String,
    baseRefOptions: [String],
    branchName: String,
    selectedBaseRef: String?,
    fetchRemote: Bool,
    defaultWorktreeBaseDirectory: String,
    worktreeNameOverride: String = "",
    worktreePathOverride: String = "",
    validationMessage: String?,
    isSuggestingName: Bool = false,
    randomPlaceholder: String
  ) {
    self.init(
      repositoryID: repositoryID,
      placement: .local(repositoryRootURL: repositoryRootURL),
      repositoryName: repositoryName,
      automaticBaseRef: automaticBaseRef,
      baseRefOptions: baseRefOptions,
      branchName: branchName,
      selectedBaseRef: selectedBaseRef,
      fetchRemote: fetchRemote,
      defaultWorktreeBaseDirectory: defaultWorktreeBaseDirectory,
      worktreeNameOverride: worktreeNameOverride,
      worktreePathOverride: worktreePathOverride,
      validationMessage: validationMessage,
      isSuggestingName: isSuggestingName,
      randomPlaceholder: randomPlaceholder
    )
  }
}
