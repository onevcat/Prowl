import ComposableArchitecture
import Foundation

@Reducer
struct WorkflowSettingsDetailFeature {
  @ObservableState
  struct State: Equatable {
    let rowID: String
    var row: WorkflowSettingsRow?
    var runTargets: [WorkflowSettingsRunTarget]

    init(row: WorkflowSettingsRow, runTargets: [WorkflowSettingsRunTarget]) {
      rowID = row.id
      self.row = row
      self.runTargets = runTargets
    }

    var preferredRunTarget: WorkflowSettingsRunTarget? {
      runTargets.first(where: \.isPreferred) ?? runTargets.first
    }
  }

  enum Action: Equatable {
    case enabledChanged(Bool)
    case runSetupChanged(WorkflowBindModeOverride.Mode?)
    case preferredProfileChanged(WorkflowBindingMemoryKey, UUID?)
    case openWorkflowTapped
    case revealInFinderTapped
    case runTapped(worktreeID: String, forceSheet: Bool)
    case manageProfilesTapped
    case delegate(Delegate)
  }

  @CasePathable
  enum Delegate: Equatable {
    case setEnabled(settingsKey: String, enabled: Bool)
    case setRunSetup(settingsKey: String, mode: WorkflowBindModeOverride.Mode?)
    case setPreferredProfile(WorkflowBindingMemoryKey, UUID?)
    case runWorkflow(workflowKey: String, worktreeID: String, forceSheet: Bool)
    case manageProfiles
  }

  @Dependency(OpenURLClient.self) var openURLClient
  @Dependency(WorkflowSettingsClient.self) var client

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .enabledChanged(let enabled):
        guard let settingsKey = state.row?.settingsKey else { return .none }
        return .send(.delegate(.setEnabled(settingsKey: settingsKey, enabled: enabled)))

      case .runSetupChanged(let mode):
        guard let settingsKey = state.row?.settingsKey else { return .none }
        return .send(.delegate(.setRunSetup(settingsKey: settingsKey, mode: mode)))

      case .preferredProfileChanged(let key, let profileID):
        return .send(.delegate(.setPreferredProfile(key, profileID)))

      case .openWorkflowTapped:
        guard let row = state.row else { return .none }
        openURLClient.open(row.url)
        return .none

      case .revealInFinderTapped:
        guard let row = state.row else { return .none }
        client.reveal(row.url)
        return .none

      case .runTapped(let worktreeID, let forceSheet):
        guard
          let row = state.row,
          let workflowKey = row.settingsKey,
          row.isValid,
          row.isEnabled,
          row.shadowNote == nil
        else { return .none }
        return .send(
          .delegate(
            .runWorkflow(
              workflowKey: workflowKey,
              worktreeID: worktreeID,
              forceSheet: forceSheet)))

      case .manageProfilesTapped:
        return .send(.delegate(.manageProfiles))

      case .delegate:
        return .none
      }
    }
  }
}
