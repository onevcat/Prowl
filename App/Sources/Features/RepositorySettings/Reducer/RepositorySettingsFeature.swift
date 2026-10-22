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
    /// The repository. Folder-based parts of the pane (worktree folder
    /// example, icon images, symbol suggestions, workflows) work only for a
    /// local repository until the remote pane is designed (docs-ai 084 C1).
    var location: RepositoryLocation
    /// Persistence key for `@Shared(.repositoryAppearances)`. Defaults
    /// to empty so legacy test fixtures that only construct the four
    /// originally-required fields keep compiling — production
    /// callers (AppFeature) always pass the canonical `repository.id`.
    var repositoryID: Repository.ID = ""
    var repositoryKind: Repository.Kind
    var workspace: ProjectWorkspace?
    var settings: RepositorySettings
    var userSettings: UserRepositorySettings
    /// The global appearances store, read live rather than copied when the
    /// pane is built: automatic icon detection commits into the same dict
    /// while the pane is open, and a stale copy would both show the wrong
    /// icon and clobber the detected one on the next edit.
    @Shared(.repositoryAppearances) var appearances
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
    var isSymbolPickerPresented = false
    var symbolSuggestions: SymbolSuggestionsPhase = .idle
    var workflows = WorkflowsSettingsFeature.State()

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

    var appearance: RepositoryAppearance {
      appearances[repositoryID] ?? .empty
    }

    /// The folder name, for the custom title placeholder.
    var folderName: String { Repository.name(for: location) }

    /// The root on this Mac. Nil for a remote repository, whose pane skips the
    /// folder-based parts (docs-ai 084 C1).
    var localRootURL: URL? { location.localURL }

    var exampleWorktreePath: String {
      guard let rootURL = location.localURL else { return "" }
      return ProwlPaths.exampleWorktreePath(
        for: rootURL,
        globalDefaultPath: globalDefaultWorktreeBaseDirectoryPath,
        repositoryOverridePath: settings.worktreeBaseDirectoryPath
      )
    }
  }

  enum Action: BindableAction {
    case task
    case workflowsAppeared
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
    case setAppearanceColor(RepositoryColorChoice?)
    case setAppearanceIcon(RepositoryIconSource?)
    case chooseSymbolTapped
    case suggestIconTapped
    case regenerateSuggestionsTapped
    case symbolPickerDismissed
    case symbolSuggestionsLoaded(RepositorySymbolSuggestions)
    case symbolSuggestionsFailed(String)
    case importUserImage(URL)
    case userImageImportFailed(String)
    case dismissAppearanceImportError
    case resetAppearance
    case setGlobalCommandEnabled(UserCustomCommand.ID, Bool)
    case setDefaultAgentProfileID(AgentProfile.ID?)
    case branchDataLoaded([String], defaultBaseRef: String)
    case editWorkspaceTapped
    case workflows(WorkflowsSettingsFeature.Action)
    case delegate(Delegate)
    case binding(BindingAction<State>)
  }

  @CasePathable
  enum Delegate: Equatable {
    case settingsChanged(RepositoryLocation)
    /// The workspace editor lives on the main window; the app surfaces it.
    case editWorkspace(Repository.ID)
  }

  @Dependency(GitClientDependency.self) private var gitClient
  @Dependency(\.repositoryIconAssetStore) private var repositoryIconAssetStore
  @Dependency(\.repositorySymbolSuggestionClient) private var symbolSuggestionClient

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .task:
        let location = state.location
        guard state.capabilities.supportsRepositoryGitSettings else {
          return .run { send in
            @Shared(.repositorySettings(location)) var repositorySettings
            @Shared(.userRepositorySettings(location)) var userRepositorySettings
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
        let repositoryHost = RepositoryHost(local: gitClient)
        return .run { send in
          let isBareRepository = (try? await repositoryHost.isBareRepository(location)) ?? false
          @Shared(.repositorySettings(location)) var repositorySettings
          @Shared(.userRepositorySettings(location)) var userRepositorySettings
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
            branches = try await repositoryHost.branchRefs(in: location)
          } catch is RepositoryHostError {
            // A remote repository has no host connection yet (B3); nothing failed.
            branches = []
          } catch {
            let rootPath = location.id
            ProwlLogger("Settings").warning(
              "Branch refs failed for \(rootPath): \(error.localizedDescription)"
            )
            branches = []
          }
          let defaultBaseRef = await repositoryHost.automaticWorktreeBaseRef(in: location) ?? "HEAD"
          await send(.branchDataLoaded(branches, defaultBaseRef: defaultBaseRef))
        }

      case .workflowsAppeared:
        // Workflows run only in local repositories (docs-ai 084 A4a).
        guard let rootURL = state.localRootURL else { return .none }
        state.workflows.settingsScope = .repository(
          WorkflowSettingsRepositoryContext(
            repositoryID: state.repositoryID,
            name: state.settings.customTitle ?? rootURL.lastPathComponent,
            rootURL: rootURL))
        return .none

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
        if let rootURL = state.localRootURL {
          // A remote path stays as the user wrote it: `~` and relative paths
          // belong to the remote host, not to this Mac.
          updatedSettings.worktreeBaseDirectoryPath =
            ProwlPaths.normalizedWorktreeBaseDirectoryPath(
              updatedSettings.worktreeBaseDirectoryPath,
              repositoryRootURL: rootURL
            )
        }
        if isBareRepository {
          updatedSettings.copyIgnoredOnWorktreeCreate = nil
          updatedSettings.copyUntrackedOnWorktreeCreate = nil
        }
        state.settings = updatedSettings
        state.userSettings = userSettings.normalized()
        state.globalDefaultWorktreeBaseDirectoryPath =
          ProwlPaths.normalizedWorktreeBaseDirectoryPath(globalDefaultWorktreeBaseDirectoryPath)
        state.globalCopyIgnoredOnWorktreeCreate = globalCopyIgnoredOnWorktreeCreate
        state.globalCopyUntrackedOnWorktreeCreate = globalCopyUntrackedOnWorktreeCreate
        state.globalPullRequestMergeStrategy = globalPullRequestMergeStrategy
        state.isBareRepository = isBareRepository
        state.keybindingUserOverrides = keybindingUserOverrides
        guard updatedSettings != settings else { return .none }
        let location = state.location
        @Shared(.repositorySettings(location)) var repositorySettings
        $repositorySettings.withLock { $0 = updatedSettings }
        return .send(.delegate(.settingsChanged(location)))

      case .setGlobalCommandEnabled(let commandID, let isEnabled):
        guard state.userSettings.isGlobalCommandEnabled(commandID) != isEnabled else {
          return .none
        }
        state.userSettings.setGlobalCommandEnabled(isEnabled, id: commandID)
        let location = state.location
        // Targeted write: `state.userSettings` is a load-time snapshot, and
        // `lastLaunchedAgentProfileID` is written externally by profile
        // launches — a whole-struct writeback would clobber it.
        @Shared(.userRepositorySettings(location)) var userRepositorySettings
        $userRepositorySettings.withLock { $0.setGlobalCommandEnabled(isEnabled, id: commandID) }
        return .send(.delegate(.settingsChanged(location)))

      case .setDefaultAgentProfileID(let profileID):
        guard state.userSettings.defaultAgentProfileID != profileID else { return .none }
        state.userSettings.defaultAgentProfileID = profileID
        let location = state.location
        @Shared(.userRepositorySettings(location)) var userRepositorySettings
        $userRepositorySettings.withLock { $0.defaultAgentProfileID = profileID }
        return .send(.delegate(.settingsChanged(location)))

      case .setAppearanceColor(let color):
        guard state.appearance.color != color else { return .none }
        let repositoryID = state.repositoryID
        state.$appearances.withLock {
          Self.updateAppearance(in: &$0, repositoryID: repositoryID) { $0.color = color }
        }
        return .none

      case .setAppearanceIcon(let newIcon):
        guard state.appearance.icon != newIcon else { return .none }
        let previousIcon = Self.commitIcon(newIcon, to: state.$appearances, repositoryID: state.repositoryID)
        return removeAbandonedImage(previous: previousIcon, new: newIcon, location: state.location)

      case .importUserImage(let sourceURL):
        // Icon images live under a local repository's settings folder (C1 for remote).
        guard let rootURL = state.localRootURL else {
          state.appearanceImportError = String(localized: "Images are not available for remote folders yet.")
          return .none
        }
        let repositoryID = state.repositoryID
        let appearances = state.$appearances
        let store = repositoryIconAssetStore
        return .run { send in
          let filename: String
          do {
            filename = try store.importImage(sourceURL, rootURL)
          } catch {
            // Delivered only while the pane is alive; after a teardown
            // there is nowhere to show it, and nothing was imported.
            await send(.userImageImportFailed(error.localizedDescription))
            return
          }
          // Commit straight into the shared store instead of sending an
          // action back: the pane can be torn down (Settings sidebar
          // switch) while the copy runs, and an action delivered to the
          // missing pane would be dropped, orphaning the imported file.
          // The commit runs on the main actor so it serializes with the
          // reducers that also write this dict (edits, icon detection).
          let newIcon = RepositoryIconSource.userImage(filename: filename)
          let previousIcon = await MainActor.run {
            Self.commitIcon(newIcon, to: appearances, repositoryID: repositoryID)
          }
          if let abandoned = Self.abandonedImageFilename(previous: previousIcon, new: newIcon) {
            try? store.remove(abandoned, rootURL)
          }
        }

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
        guard !state.appearance.isEmpty else { return .none }
        let repositoryID = state.repositoryID
        let previousIcon = state.$appearances.withLock { appearances in
          let previousIcon = appearances[repositoryID]?.icon
          // Removing an icon via reset counts as an explicit clear for
          // detection purposes; a reset that only dropped a color does not.
          Self.updateAppearance(in: &appearances, repositoryID: repositoryID) {
            $0 = RepositoryAppearance(iconDetectionSuppressed: previousIcon != nil)
          }
          return previousIcon
        }
        return removeAbandonedImage(previous: previousIcon, new: nil, location: state.location)

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

      case .editWorkspaceTapped:
        guard state.workspace != nil else { return .none }
        return .send(.delegate(.editWorkspace(state.repositoryID)))

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
        let location = state.location
        var normalizedSettings = state.settings
        if let rootURL = location.localURL {
          normalizedSettings.worktreeBaseDirectoryPath =
            ProwlPaths.normalizedWorktreeBaseDirectoryPath(
              normalizedSettings.worktreeBaseDirectoryPath,
              repositoryRootURL: rootURL
            )
        }
        let trimmedCustomTitle =
          normalizedSettings.customTitle?
          .trimmingCharacters(in: .whitespacesAndNewlines)
        normalizedSettings.customTitle =
          (trimmedCustomTitle?.isEmpty ?? true) ? nil : trimmedCustomTitle
        normalizedSettings.githubAccountOverride =
          normalizedSettings.githubAccountOverride?.normalized
        @Shared(.repositorySettings(location)) var repositorySettings
        @Shared(.userRepositorySettings(location)) var userRepositorySettings
        $repositorySettings.withLock { $0 = normalizedSettings }
        // `state.userSettings` is a load-time snapshot; preserve the
        // externally-written launch memory instead of clobbering it with the
        // stale copy (profile launches update it while Settings stays open).
        let lastLaunched = userRepositorySettings.lastLaunchedAgentProfileID
        state.userSettings.lastLaunchedAgentProfileID = lastLaunched
        $userRepositorySettings.withLock { $0 = state.userSettings }
        return .send(.delegate(.settingsChanged(location)))

      case .workflows:
        return .none

      case .delegate:
        return .none
      }
    }
    Scope(state: \.workflows, action: \.workflows) {
      WorkflowsSettingsFeature()
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
    // Suggestions read the repository's files on this Mac (C1 for remote).
    guard let rootURL = state.localRootURL else {
      return .send(
        .symbolSuggestionsFailed(String(localized: "Suggestions are not available for remote folders yet.")))
    }
    let displayName: String =
      if let custom = state.settings.customTitle, !custom.isEmpty {
        custom
      } else {
        rootURL.lastPathComponent
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

  /// Read-modify-write of one repository's entry, touching only what
  /// `update` changes so concurrent writers (automatic icon detection)
  /// keep their fields. Drops the entry once it's empty so the on-disk
  /// file stays tight.
  nonisolated private static func updateAppearance(
    in appearances: inout [Repository.ID: RepositoryAppearance],
    repositoryID: Repository.ID,
    _ update: (inout RepositoryAppearance) -> Void
  ) {
    var appearance = appearances[repositoryID] ?? .empty
    update(&appearance)
    appearances[repositoryID] = appearance.isEmpty ? nil : appearance
  }

  /// Stores `newIcon` and returns the icon it replaced, read under the
  /// same lock. An explicit clear also suppresses automatic detection so
  /// an in-flight detector can't restore the icon the user removed.
  nonisolated private static func commitIcon(
    _ newIcon: RepositoryIconSource?,
    to appearances: Shared<[Repository.ID: RepositoryAppearance]>,
    repositoryID: Repository.ID
  ) -> RepositoryIconSource? {
    appearances.withLock { appearances in
      let previousIcon = appearances[repositoryID]?.icon
      updateAppearance(in: &appearances, repositoryID: repositoryID) {
        $0.icon = newIcon
        if newIcon == nil {
          $0.iconDetectionSuppressed = true
        }
      }
      return previousIcon
    }
  }

  /// When the icon transitions away from a file-backed source (user
  /// import or automatic detection), the old asset on disk is no longer
  /// referenced and should be cleaned up. `nil` when the previous icon
  /// wasn't file-backed or when the new icon keeps the same file.
  nonisolated private static func abandonedImageFilename(
    previous: RepositoryIconSource?,
    new: RepositoryIconSource?
  ) -> String? {
    guard let oldFilename = previous?.storedImageFilename,
      new?.storedImageFilename != oldFilename
    else { return nil }
    return oldFilename
  }

  private func removeAbandonedImage(
    previous: RepositoryIconSource?,
    new: RepositoryIconSource?,
    location: RepositoryLocation
  ) -> Effect<Action> {
    guard let oldFilename = Self.abandonedImageFilename(previous: previous, new: new),
      let rootURL = location.localURL
    else {
      return .none
    }
    let store = repositoryIconAssetStore
    return .run { _ in
      try? store.remove(oldFilename, rootURL)
    }
  }

}
