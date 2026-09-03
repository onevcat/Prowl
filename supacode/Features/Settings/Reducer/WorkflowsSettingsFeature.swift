import ComposableArchitecture
import Foundation
import Sharing

/// Settings › Agents › Workflows (docs-ai 063 D1): every workflow definition Prowl can see —
/// bundled, `~/.prowl/workflows`, and each open repository's `.prowl/workflows` — with its
/// validation status, the enable toggle (`disabledWorkflowIDs`), the per-workflow bind-mode
/// override, and the remembered `launch`-role bindings, plus the CLI dependency banner, a
/// starter file, and the agent authoring prompt. Filesystem access stays in
/// `WorkflowSettingsClient`; row derivation is `WorkflowSettingsCatalog`.
@Reducer
struct WorkflowsSettingsFeature {
  @ObservableState
  struct State: Equatable {
    /// The last scan, kept so a settings write can rebuild the rows without touching the disk.
    var scan: WorkflowSettingsScan?
    var catalog: WorkflowSettingsCatalog
    /// Why the sources could not be read (an unreadable folder); the lists are then stale or empty.
    var loadError: String?
    var cliInstallStatus: CLIInstallStatus = .notInstalled
    var cliServiceStatus: CLIServiceStatus = .stopped
    var isAuthoringPromptPresented = false
    @Presents var alert: AlertState<Alert>?

    init(userDirectory: URL = WorkflowSources.userDirectory(home: FileManager.default.homeDirectoryForCurrentUser)) {
      catalog = .empty(userDirectory: userDirectory)
    }

    /// The banner's reason, in the same precedence as the start sheet: an app that is not
    /// listening cannot be fixed by installing the CLI, and a dangling link needs a repair.
    var cliBlocker: CLIBlocker? {
      if let reason = cliServiceStatus.unreachableDescription { return .socketUnavailable(reason) }
      guard cliInstallStatus.isUsable else {
        if case .broken = cliInstallStatus { return .notInstalled(repair: true) }
        return .notInstalled(repair: false)
      }
      return nil
    }

    var hasNoWorkflows: Bool {
      catalog.bundle.isEmpty && catalog.user.isEmpty && catalog.repositories.isEmpty
    }

    var allRows: [WorkflowSettingsRow] {
      catalog.bundle + catalog.user + catalog.repositories.flatMap(\.rows)
    }

    /// Everything whose change must re-derive the rows: the source directories (files appear,
    /// disappear, get renamed) and every discovered file (an in-place save touches only the
    /// file's vnode). A directory that does not exist yet is watched through its parent.
    var watchedPaths: [URL] {
      guard let scan else { return [catalog.userDirectory] }
      let directories = [scan.userDirectory] + scan.repositories.map(\.directory)
      let files = scan.entries.map(\.file.url) + scan.repositories.flatMap { $0.entries.map(\.file.url) }
      var seen: Set<String> = []
      return (directories + files).filter { seen.insert($0.path(percentEncoded: false)).inserted }
    }
  }

  enum CLIBlocker: Equatable {
    /// `repair` = the slot holds a dangling link, so the action reads Repair.
    case notInstalled(repair: Bool)
    case socketUnavailable(String)
  }

  enum Action: Equatable {
    case task
    /// The page went away (the Settings window closed on it): stop watching until it appears again.
    case teardown
    case reload
    /// A watched directory changed; coalesced into one `reload` after a short quiet period.
    case directoriesChanged
    case setEnabled(settingsKey: String, isEnabled: Bool)
    case setBindMode(settingsKey: String, mode: WorkflowBindModeOverride.Mode?)
    /// nil forgets the remembered profile ("Ask at start").
    case setRememberedBinding(WorkflowBindingMemoryKey, profileID: UUID?)
    case revealTapped(rowID: String)
    case revealUserFolderTapped
    case newWorkflowTapped
    case askAgentTapped
    case setAuthoringPromptPresented(Bool)
    case installCLITapped
    case cliInstallCompleted(Result<String, CLIInstallError>)
    case manageProfilesTapped
    case alert(PresentationAction<Alert>)
    case delegate(Delegate)
  }

  enum Alert: Equatable {
    case dismiss
  }

  @CasePathable
  enum Delegate: Equatable {
    case notice(WorkflowsSettingsNotice)
    case openProfiles
  }

  private nonisolated enum CancelID {
    case watch
    case debounce
  }

  static let reloadDebounce: Duration = .milliseconds(300)

  @Dependency(WorkflowSettingsClient.self) private var client
  @Dependency(CLIInstallClient.self) private var cliInstallClient
  @Dependency(CLIServiceStatusClient.self) private var cliServiceStatusClient
  @Dependency(\.continuousClock) private var clock

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .task, .reload:
        reload(&state)
        return watch(state)

      case .teardown:
        return .merge(.cancel(id: CancelID.watch), .cancel(id: CancelID.debounce))

      case .directoriesChanged:
        return .run { send in
          try await clock.sleep(for: Self.reloadDebounce)
          await send(.reload)
        }
        .cancellable(id: CancelID.debounce, cancelInFlight: true)

      case .setEnabled(let settingsKey, let isEnabled):
        persist(&state) { settings in
          var keys = Set(settings.disabledWorkflowIDs)
          if isEnabled { keys.remove(settingsKey) } else { keys.insert(settingsKey) }
          settings.disabledWorkflowIDs = UserGlobalSettings.normalizedWorkflowIDs(Array(keys))
        }
        return .none

      case .setBindMode(let settingsKey, let mode):
        persist(&state) { $0.setWorkflowBindMode(mode, for: settingsKey) }
        return .none

      case .setRememberedBinding(let key, let profileID):
        persist(&state) { settings in
          if let profileID {
            settings.remember(workflowBinding: key, profileID: profileID)
          } else {
            settings.forget(workflowBinding: key)
          }
        }
        return .none

      case .revealTapped(let rowID):
        guard let row = state.allRows.first(where: { $0.id == rowID }) else { return .none }
        return .run { [client] _ in client.reveal(row.url) }

      case .revealUserFolderTapped:
        let directory = state.catalog.userDirectory
        return .run { [client] _ in
          // Finder cannot select a folder that does not exist; create it so the drop target is real.
          try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
          client.reveal(directory)
        }

      case .newWorkflowTapped:
        do {
          let url = try client.createWorkflow()
          reload(&state)
          return .merge(
            watch(state),
            .run { [client] _ in client.reveal(url) },
            .send(.delegate(.notice(.workflowCreated(path: url.path(percentEncoded: false)))))
          )
        } catch let error as WorkflowSettingsError {
          state.alert = Self.errorAlert(error.message)
          return .send(.delegate(.notice(.failed(message: error.message))))
        } catch {
          state.alert = Self.errorAlert(error.localizedDescription)
          return .send(.delegate(.notice(.failed(message: error.localizedDescription))))
        }

      case .askAgentTapped:
        state.isAuthoringPromptPresented = true
        return .none

      case .setAuthoringPromptPresented(let isPresented):
        state.isAuthoringPromptPresented = isPresented
        return .none

      case .installCLITapped:
        let installPath = cliDefaultInstallPath
        return .run { [cliInstallClient] send in
          do {
            try await cliInstallClient.install(installPath)
            await send(.cliInstallCompleted(.success(installPath.path(percentEncoded: false))))
          } catch let error as CLIInstallError {
            await send(.cliInstallCompleted(.failure(error)))
          } catch {
            await send(.cliInstallCompleted(.failure(CLIInstallError(message: error.localizedDescription))))
          }
        }

      case .cliInstallCompleted(.success(let path)):
        state.cliInstallStatus = cliInstallClient.installationStatus(cliDefaultInstallPath)
        return .send(.delegate(.notice(.cliInstalled(path: path))))

      case .cliInstallCompleted(.failure(let error)):
        state.cliInstallStatus = cliInstallClient.installationStatus(cliDefaultInstallPath)
        state.alert = Self.errorAlert(error.message)
        return .send(.delegate(.notice(.failed(message: error.message))))

      case .manageProfilesTapped:
        return .send(.delegate(.openProfiles))

      case .alert:
        return .none

      case .delegate:
        return .none
      }
    }
    .ifLet(\.$alert, action: \.alert)
  }

  private func reload(_ state: inout State) {
    state.cliInstallStatus = cliInstallClient.installationStatus(cliDefaultInstallPath)
    state.cliServiceStatus = cliServiceStatusClient.current()
    do {
      let scan = try client.scan()
      state.scan = scan
      state.loadError = nil
      rebuild(&state)
    } catch let error as WorkflowSettingsError {
      state.loadError = error.message
    } catch {
      state.loadError = error.localizedDescription
    }
  }

  /// Rows follow the stored settings, not a local copy: the write lands first, then the rows are
  /// derived from what is on disk, so the page can never show a toggle the file does not hold.
  private func persist(_ state: inout State, _ update: (inout UserGlobalSettings) -> Void) {
    @Shared(.userGlobalSettings) var settings
    $settings.withLock(update)
    rebuild(&state)
  }

  private func rebuild(_ state: inout State) {
    guard let scan = state.scan else { return }
    @Shared(.userGlobalSettings) var settings
    state.catalog = WorkflowSettingsCatalog.build(scan: scan, settings: settings)
  }

  private func watch(_ state: State) -> Effect<Action> {
    let paths = state.watchedPaths
    return .run { [client] send in
      for await _ in client.watch(paths) {
        await send(.directoriesChanged)
      }
    }
    .cancellable(id: CancelID.watch, cancelInFlight: true)
  }

  private static func errorAlert(_ message: String) -> AlertState<Alert> {
    AlertState {
      TextState("Workflows Error")
    } actions: {
      ButtonState(action: .dismiss) { TextState("OK") }
    } message: {
      TextState(message)
    }
  }
}

enum WorkflowsSettingsNotice: Equatable {
  case workflowCreated(path: String)
  case cliInstalled(path: String)
  case failed(message: String)
}
