import ComposableArchitecture
import Foundation
import ProwlCLIShared
import Sharing

/// Shared workflow Settings domain for the global Built-in/personal index and one repository's
/// direct Workflows section (docs-ai 063.014). The root exposes compact navigation rows; pushed
/// details own enablement, Run Setup, role preferences, validation, Run, and source-file actions.
/// Filesystem access stays in `WorkflowSettingsClient`; row derivation is `WorkflowSettingsCatalog`.
@Reducer
struct WorkflowsSettingsFeature {
  @ObservableState
  struct State: Equatable {
    var settingsScope: WorkflowSettingsScope
    /// The last scan, kept so a settings write can rebuild the rows without touching the disk.
    var scan: WorkflowSettingsScan?
    var catalog: WorkflowSettingsCatalog
    /// Why the sources could not be read (an unreadable folder); the lists are then stale or empty.
    var loadError: String?
    var cliInstallStatus: CLIInstallStatus = .notInstalled
    /// Whether a shell can run `prowl` from the install path (the gate); `cliInstallStatus`
    /// only names what occupies it (the banner's button and copy).
    var cliUsable = false
    var cliServiceStatus: CLIServiceStatus = .stopped
    var runTargets: [WorkflowSettingsRunTarget] = []
    var path = StackState<WorkflowSettingsDetailFeature.State>()
    var isAuthoringPromptPresented = false
    /// The New Workflow form while it is open.
    var newWorkflow: NewWorkflowDraft?
    @Presents var alert: AlertState<Alert>?

    init(
      scope: WorkflowSettingsScope = .global,
      userDirectory: URL = WorkflowSources.userDirectory(
        home: FileManager.default.homeDirectoryForCurrentUser)
    ) {
      settingsScope = scope
      catalog = .empty(userDirectory: userDirectory)
    }

    /// The banner's reason, in the same precedence as the start sheet: an app that is not
    /// listening cannot be fixed by installing the CLI.
    var cliBlocker: CLIBlocker? {
      if let reason = cliServiceStatus.unreachableDescription { return .socketUnavailable(reason) }
      guard cliUsable else { return .cliUnusable(cliInstallStatus) }
      return nil
    }

    var displayedRows: [WorkflowSettingsRow] {
      switch settingsScope {
      case .global:
        return catalog.bundle + catalog.user
      case .repository(let repository):
        return catalog.repositories.first { $0.repositoryID == repository.repositoryID }?.rows ?? []
      }
    }

    var hasNoWorkflows: Bool { displayedRows.isEmpty }

    /// Why the form's Create button is disabled, or nil when the draft can be written.
    var newWorkflowProblem: String? {
      guard let draft = newWorkflow else { return nil }
      if draft.name.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a name." }
      if draft.id.isEmpty { return "Enter an ID." }
      guard WorkflowSchema.isWorkflowID(draft.id) else {
        return "IDs use lowercase letters, digits, dots, dashes, and underscores, and start with a letter or digit."
      }
      if draft.id.hasPrefix(WorkflowSchema.reservedIDPrefix) {
        return "IDs starting with “\(WorkflowSchema.reservedIDPrefix)” are reserved for built-in workflows."
      }
      let fileName = draft.request.fileName
      if displayedRows.contains(where: { $0.workflowID == draft.id || $0.fileName == fileName })
        || FileManager.default.fileExists(
          atPath: workflowDirectory.appending(path: fileName).path(percentEncoded: false))
      {
        return "A workflow with this ID already exists here."
      }
      return nil
    }

    var allRows: [WorkflowSettingsRow] { displayedRows }

    var workflowDirectory: URL {
      switch settingsScope {
      case .global: catalog.userDirectory
      case .repository(let repository): repository.directory
      }
    }

    /// Everything whose change must re-derive the rows: the source directories (files appear,
    /// disappear, get renamed) and every discovered file (an in-place save touches only the
    /// file's vnode). A directory that does not exist yet is watched through its parent.
    func detailState(for row: WorkflowSettingsRow) -> WorkflowSettingsDetailFeature.State {
      WorkflowSettingsDetailFeature.State(row: row, runTargets: runTargets)
    }

    var watchedPaths: [URL] {
      guard let scan else { return [workflowDirectory] }
      let directories = [scan.userDirectory] + scan.repositories.map(\.directory)
      let files =
        (scan.entries + scan.repositories.flatMap(\.entries)).flatMap { entry in
          [entry.file.url]
            + (entry.file.snapshot?.files.keys.flatMap { path -> [URL] in
              var urls: [URL] = []
              var relative = path
              while !relative.isEmpty {
                urls.append(entry.file.url.appending(path: relative))
                relative = relative.split(separator: "/").dropLast().joined(separator: "/")
              }
              return urls
            } ?? [])
        }
      var seen: Set<String> = []
      return (directories + files).filter { seen.insert($0.path(percentEncoded: false)).inserted }
    }
  }

  enum CLIBlocker: Equatable {
    /// No runnable `prowl` at the install path; the status says what is there instead.
    case cliUnusable(CLIInstallStatus)
    case socketUnavailable(String)
  }

  enum Action: Equatable {
    case task
    /// The page went away (the Settings window closed on it): stop watching until it appears again.
    case teardown
    case reload
    /// A watched directory changed; coalesced into one `reload` after a short quiet period.
    case directoriesChanged
    case showDetails(rowID: String)
    case setEnabled(settingsKey: String, isEnabled: Bool)
    case setBindMode(settingsKey: String, mode: WorkflowBindModeOverride.Mode?)
    /// nil forgets the remembered profile ("Ask at start").
    case setRememberedBinding(WorkflowBindingMemoryKey, profileID: UUID?)
    case revealTapped(rowID: String)
    case revealUserFolderTapped
    case newWorkflowTapped
    case newWorkflowNameChanged(String)
    case newWorkflowIDChanged(String)
    case newWorkflowIconChanged(String)
    case newWorkflowKindChanged(WorkflowStarterTemplate.Kind)
    case createWorkflowTapped
    case dismissNewWorkflow
    case askAgentTapped
    case setAuthoringPromptPresented(Bool)
    case installCLITapped
    case cliInstallCompleted(Result<String, CLIInstallError>)
    case manageProfilesTapped
    case path(StackActionOf<WorkflowSettingsDetailFeature>)
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
    case runWorkflow(workflowKey: String, worktreeID: String, forceSheet: Bool)
  }

  private nonisolated enum CancelID {
    case watch
    case debounce
  }

  static let reloadDebounce: Duration = .milliseconds(300)

  @Dependency(WorkflowSettingsClient.self) private var client
  @Dependency(OpenURLClient.self) private var openURLClient
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

      case .showDetails(let rowID):
        guard let row = state.allRows.first(where: { $0.id == rowID }) else { return .none }
        state.path.removeAll()
        state.path.append(state.detailState(for: row))
        return .none

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
        let directory = state.workflowDirectory
        return .run { [client] _ in
          // Finder cannot select a folder that does not exist; create it so the drop target is real.
          try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
          client.reveal(directory)
        }

      case .newWorkflowTapped:
        state.newWorkflow = NewWorkflowDraft()
        return .none

      case .newWorkflowNameChanged(let name):
        guard var draft = state.newWorkflow else { return .none }
        draft.name = name
        if !draft.idEdited { draft.id = WorkflowStarterTemplate.suggestedID(for: name) }
        state.newWorkflow = draft
        return .none

      case .newWorkflowIDChanged(let id):
        guard var draft = state.newWorkflow else { return .none }
        draft.id = id.trimmingCharacters(in: .whitespaces)
        // An emptied field goes back to following the name.
        draft.idEdited = !draft.id.isEmpty
        if !draft.idEdited { draft.id = WorkflowStarterTemplate.suggestedID(for: draft.name) }
        state.newWorkflow = draft
        return .none

      case .newWorkflowIconChanged(let icon):
        state.newWorkflow?.icon = icon.trimmingCharacters(in: .whitespaces)
        return .none

      case .newWorkflowKindChanged(let kind):
        state.newWorkflow?.kind = kind
        return .none

      case .createWorkflowTapped:
        guard let draft = state.newWorkflow, state.newWorkflowProblem == nil else { return .none }
        do {
          let url = try client.createWorkflow(state.workflowDirectory, draft.request)
          state.newWorkflow = nil
          reload(&state)
          openURLClient.open(url.appending(path: "workflow.yaml"))
          return .merge(
            watch(state),
            .send(.delegate(.notice(.workflowCreated(path: url.path(percentEncoded: false)))))
          )
        } catch let error as WorkflowSettingsError {
          state.alert = Self.errorAlert(error.message)
          return .send(.delegate(.notice(.failed(message: error.message))))
        } catch {
          state.alert = Self.errorAlert(error.localizedDescription)
          return .send(.delegate(.notice(.failed(message: error.localizedDescription))))
        }

      case .dismissNewWorkflow:
        state.newWorkflow = nil
        return .none

      case .askAgentTapped:
        // From the form the prompt opens on top of it; from the index it stands alone.
        if state.newWorkflow != nil {
          state.newWorkflow?.showsAuthoringPrompt = true
        } else {
          state.isAuthoringPromptPresented = true
        }
        return .none

      case .setAuthoringPromptPresented(let isPresented):
        if state.newWorkflow != nil {
          state.newWorkflow?.showsAuthoringPrompt = isPresented
        } else {
          state.isAuthoringPromptPresented = isPresented
        }
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
            await send(
              .cliInstallCompleted(.failure(CLIInstallError(message: error.localizedDescription))))
          }
        }

      case .cliInstallCompleted(.success(let path)):
        state.cliInstallStatus = cliInstallClient.installationStatus(cliDefaultInstallPath)
        state.cliUsable = cliInstallClient.isUsable(cliDefaultInstallPath)
        return .send(.delegate(.notice(.cliInstalled(path: path))))

      case .cliInstallCompleted(.failure(let error)):
        state.cliInstallStatus = cliInstallClient.installationStatus(cliDefaultInstallPath)
        state.cliUsable = cliInstallClient.isUsable(cliDefaultInstallPath)
        state.alert = Self.errorAlert(error.message)
        return .send(.delegate(.notice(.failed(message: error.message))))

      case .manageProfilesTapped:
        return .send(.delegate(.openProfiles))

      case .path(.element(id: _, action: .appeared)):
        state.runTargets = client.runTargets(state.settingsScope)
        synchronizePath(&state)
        return .none

      case .path(.element(id: _, action: .delegate(.setEnabled(let rowID, let enabled)))):
        return .send(.setEnabled(settingsKey: rowID, isEnabled: enabled))

      case .path(.element(id: _, action: .delegate(.setRunSetup(let rowID, let mode)))):
        return .send(.setBindMode(settingsKey: rowID, mode: mode))

      case .path(.element(id: _, action: .delegate(.setPreferredProfile(let key, let profileID)))):
        return .send(.setRememberedBinding(key, profileID: profileID))

      case .path(
        .element(id: _, action: .delegate(.runWorkflow(let key, let worktreeID, let forceSheet)))):
        return .send(
          .delegate(.runWorkflow(workflowKey: key, worktreeID: worktreeID, forceSheet: forceSheet)))

      case .path(.element(id: _, action: .delegate(.manageProfiles))):
        return .send(.delegate(.openProfiles))

      case .path(.element(id: let id, action: .delegate(.deleted))):
        state.path.pop(from: id)
        return .send(.reload)

      case .path:
        return .none

      case .alert:
        return .none

      case .delegate:
        return .none
      }
    }
    .ifLet(\.$alert, action: \.alert)
    .forEach(\.path, action: \.path) {
      WorkflowSettingsDetailFeature()
    }
  }

  private func reload(_ state: inout State) {
    state.cliInstallStatus = cliInstallClient.installationStatus(cliDefaultInstallPath)
    state.cliUsable = cliInstallClient.isUsable(cliDefaultInstallPath)
    state.cliServiceStatus = cliServiceStatusClient.current()
    state.runTargets = client.runTargets(state.settingsScope)
    do {
      let scan = try client.scan(state.settingsScope)
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
    synchronizePath(&state)
  }

  private func synchronizePath(_ state: inout State) {
    let rows = state.allRows
    let runTargets = state.runTargets
    for id in state.path.ids {
      guard let rowID = state.path[id: id]?.rowID else { continue }
      state.path[id: id]?.row = rows.first { $0.id == rowID }
      state.path[id: id]?.runTargets = runTargets
    }
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

/// What the New Workflow form collects before a starter bundle is written.
struct NewWorkflowDraft: Equatable {
  var name = ""
  var id = ""
  var icon = ""
  var kind: WorkflowStarterTemplate.Kind = .singleAgent
  /// Once the user typed an ID it stops following the name.
  var idEdited = false
  /// "Create with Agent…" inside the form: the prompt sheet opens over it.
  var showsAuthoringPrompt = false

  var request: WorkflowStarterTemplate.Request {
    WorkflowStarterTemplate.Request(
      name: name.trimmingCharacters(in: .whitespaces),
      id: id,
      icon: icon.isEmpty ? nil : icon,
      kind: kind)
  }
}

enum WorkflowsSettingsNotice: Equatable {
  case workflowCreated(path: String)
  case cliInstalled(path: String)
  case failed(message: String)
}
