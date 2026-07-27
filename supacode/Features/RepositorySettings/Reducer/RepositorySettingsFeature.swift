import ComposableArchitecture
import Foundation

@Reducer
struct RepositorySettingsFeature {
  private enum CancelID {
    static let symbolSuggestions = "repositorySettings.symbolSuggestions"
  }

  /// Lifecycle of the "Suggested for this repository" section inside
  /// the symbol picker sheet. Successful results also live in the
  /// session cache owned by `RepositorySymbolSuggestionClient`, so
  /// `.idle` on a fresh State still resolves instantly when a cached
  /// run exists.
  enum SymbolSuggestionsPhase: Equatable {
    case idle
    case loading
    case loaded(RepositorySymbolSuggestions)
    case failed(String)
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
    var settings: RepositorySettings
    var userSettings: UserRepositorySettings
    var appearance: RepositoryAppearance = .empty
    var globalDefaultWorktreeBaseDirectoryPath: String?
    var globalCopyIgnoredOnWorktreeCreate: Bool = false
    var globalCopyUntrackedOnWorktreeCreate: Bool = false
    var globalPullRequestMergeStrategy: PullRequestMergeStrategy = .merge
    var globalDefaultAgentAccount: String?
    var globalAgentAccountRules: [AgentAccountRule] = []
    var isBareRepository = false
    var branchOptions: [String] = []
    var defaultWorktreeBaseRef = "origin/main"
    var isBranchDataLoaded = false
    var keybindingUserOverrides: KeybindingUserOverrideStore = .empty
    var appearanceImportError: String?
    var isSymbolPickerPresented = false
    var symbolSuggestions: SymbolSuggestionsPhase = .idle

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

    /// Account this repository uses when it has no override of its own.
    var inheritedAgentAccount: String? {
      AgentAccount.resolvedName(
        repositoryRootURL: rootURL,
        repositoryOverride: nil,
        globalDefault: globalDefaultAgentAccount,
        rules: globalAgentAccountRules
      )
    }

    var exampleWorktreePath: String {
      SupacodePaths.exampleWorktreePath(
        for: rootURL,
        globalDefaultPath: globalDefaultWorktreeBaseDirectoryPath,
        repositoryOverridePath: settings.worktreeBaseDirectoryPath
      )
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
      globalDefaultAgentAccount: String?,
      globalAgentAccountRules: [AgentAccountRule],
      keybindingUserOverrides: KeybindingUserOverrideStore
    )
    case appearanceLoaded(RepositoryAppearance)
    case setAppearanceColor(RepositoryColorChoice?)
    case setAppearanceIcon(RepositoryIconSource?)
    case chooseSymbolTapped
    case suggestIconTapped
    case regenerateSuggestionsTapped
    case symbolPickerDismissed
    case symbolSuggestionsLoaded(RepositorySymbolSuggestions)
    case symbolSuggestionsFailed(String)
    case importUserImage(URL)
    case userImageImported(filename: String)
    case userImageImportFailed(String)
    case dismissAppearanceImportError
    case resetAppearance
    case setGlobalCommandEnabled(UserCustomCommand.ID, Bool)
    case branchDataLoaded([String], defaultBaseRef: String)
    case delegate(Delegate)
    case binding(BindingAction<State>)
  }

  @CasePathable
  enum Delegate: Equatable {
    case settingsChanged(URL)
  }

  @Dependency(GitClientDependency.self) private var gitClient
  @Dependency(\.repositoryIconAssetStore) private var repositoryIconAssetStore
  @Dependency(\.repositorySymbolSuggestionClient) private var symbolSuggestionClient

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
                globalDefaultAgentAccount: global.defaultAgentAccount,
                globalAgentAccountRules: global.agentAccountRules,
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
              globalDefaultAgentAccount: global.defaultAgentAccount,
              globalAgentAccountRules: global.agentAccountRules,
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
        let globalDefaultAgentAccount,
        let globalAgentAccountRules,
        let keybindingUserOverrides
      ):
        var updatedSettings = settings
        updatedSettings.worktreeBaseDirectoryPath = SupacodePaths.normalizedWorktreeBaseDirectoryPath(
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
        state.globalDefaultAgentAccount = globalDefaultAgentAccount
        state.globalAgentAccountRules = globalAgentAccountRules
        state.isBareRepository = isBareRepository
        state.keybindingUserOverrides = keybindingUserOverrides
        guard updatedSettings != settings else { return .none }
        let rootURL = state.rootURL
        @Shared(.repositorySettings(rootURL)) var repositorySettings
        $repositorySettings.withLock { $0 = updatedSettings }
        return .send(.delegate(.settingsChanged(rootURL)))

      case .setGlobalCommandEnabled(let commandID, let isEnabled):
        guard state.userSettings.isGlobalCommandEnabled(commandID) != isEnabled else {
          return .none
        }
        state.userSettings.setGlobalCommandEnabled(isEnabled, id: commandID)
        let rootURL = state.rootURL
        @Shared(.userRepositorySettings(rootURL)) var userRepositorySettings
        $userRepositorySettings.withLock { $0 = state.userSettings }
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
        if newIcon == nil {
          // An explicit clear also suppresses automatic detection so an
          // in-flight detector can't restore the icon the user removed.
          state.appearance.iconDetectionSuppressed = true
        }
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

      case .chooseSymbolTapped:
        state.isSymbolPickerPresented = true
        guard case .idle = state.symbolSuggestions else { return .none }
        // Surface a cached run if one exists; otherwise the section
        // stays idle with an explicit Suggest button.
        let repositoryID = state.repositoryID
        let client = symbolSuggestionClient
        return .run { send in
          if let cached = await client.cachedSuggestions(repositoryID) {
            await send(.symbolSuggestionsLoaded(cached))
          }
        }

      case .suggestIconTapped:
        state.isSymbolPickerPresented = true
        switch state.symbolSuggestions {
        case .loading, .loaded:
          return .none
        case .idle, .failed:
          state.symbolSuggestions = .loading
          return suggestionsEffect(state: state, forceRegenerate: false)
        }

      case .regenerateSuggestionsTapped:
        state.symbolSuggestions = .loading
        return suggestionsEffect(state: state, forceRegenerate: true)

      case .symbolSuggestionsLoaded(let suggestions):
        state.symbolSuggestions = .loaded(suggestions)
        return .none

      case .symbolSuggestionsFailed(let message):
        state.symbolSuggestions = .failed(message)
        return .none

      case .resetAppearance:
        let previousIcon = state.appearance.icon
        guard !state.appearance.isEmpty else { return .none }
        // Removing an icon via reset counts as an explicit clear for
        // detection purposes; a reset that only dropped a color does not.
        state.appearance = RepositoryAppearance(iconDetectionSuppressed: previousIcon != nil)
        let persist = persistAppearance(state.appearance, repositoryID: state.repositoryID)
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

      case .symbolPickerDismissed:
        state.isSymbolPickerPresented = false
        return reduceSymbolPickerDismissal(state: &state)

      case .binding(\.isSymbolPickerPresented):
        guard !state.isSymbolPickerPresented else { return .none }
        return reduceSymbolPickerDismissal(state: &state)

      case .binding:
        if state.isBareRepository {
          state.settings.copyIgnoredOnWorktreeCreate = nil
          state.settings.copyUntrackedOnWorktreeCreate = nil
        }
        state.userSettings = state.userSettings.normalized()
        let rootURL = state.rootURL
        var normalizedSettings = state.settings
        normalizedSettings.worktreeBaseDirectoryPath = SupacodePaths.normalizedWorktreeBaseDirectoryPath(
          normalizedSettings.worktreeBaseDirectoryPath,
          repositoryRootURL: rootURL
        )
        let trimmedCustomTitle =
          normalizedSettings.customTitle?
          .trimmingCharacters(in: .whitespacesAndNewlines)
        normalizedSettings.customTitle =
          (trimmedCustomTitle?.isEmpty ?? true) ? nil : trimmedCustomTitle
        normalizedSettings.githubAccountOverride = normalizedSettings.githubAccountOverride?.normalized
        // Lossless part only: an unusable name is kept as typed, not vanished.
        normalizedSettings.agentAccount = AgentAccount.storedName(normalizedSettings.agentAccount)
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

  /// Sheet dismissed: cancel an in-flight generation and reset a
  /// transient loading state so reopening starts cleanly (a finished
  /// run stays visible — it's also session-cached).
  private func reduceSymbolPickerDismissal(state: inout State) -> Effect<Action> {
    if case .loading = state.symbolSuggestions {
      state.symbolSuggestions = .idle
    }
    return .cancel(id: CancelID.symbolSuggestions)
  }

  /// Kicks off (or resolves from cache) one suggestion run. The model
  /// call is cooperatively cancellable; closing the sheet cancels it
  /// via `CancelID.symbolSuggestions`.
  private func suggestionsEffect(state: State, forceRegenerate: Bool) -> Effect<Action> {
    let repositoryID = state.repositoryID
    let rootURL = state.rootURL
    let displayName: String =
      if let custom = state.settings.customTitle, !custom.isEmpty {
        custom
      } else {
        state.rootURL.lastPathComponent
      }
    let client = symbolSuggestionClient
    return .run { send in
      if !forceRegenerate, let cached = await client.cachedSuggestions(repositoryID) {
        await send(.symbolSuggestionsLoaded(cached))
        return
      }
      do {
        let suggestions = try await client.generateSuggestions(repositoryID, rootURL, displayName)
        await send(.symbolSuggestionsLoaded(suggestions))
      } catch is CancellationError {
        // Sheet closed mid-generation — nothing to report.
      } catch {
        await send(.symbolSuggestionsFailed(error.localizedDescription))
      }
    }
    .cancellable(id: CancelID.symbolSuggestions, cancelInFlight: true)
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

  /// When the icon transitions away from a file-backed source (user
  /// import or automatic detection), the old asset on disk is no longer
  /// referenced and should be cleaned up. No-op when the previous icon
  /// wasn't file-backed or when the new icon keeps the same file.
  private func removeAbandonedUserImage(
    previous: RepositoryIconSource?,
    new: RepositoryIconSource?,
    rootURL: URL
  ) -> Effect<Action> {
    guard let oldFilename = previous?.storedImageFilename else { return .none }
    if new?.storedImageFilename == oldFilename {
      return .none
    }
    let store = repositoryIconAssetStore
    return .run { _ in
      try? store.remove(oldFilename, rootURL)
    }
  }

}
