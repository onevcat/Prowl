import ComposableArchitecture
import Foundation
import ProwlCLIShared

@Reducer
struct WorkflowSettingsDetailFeature {
  @ObservableState
  struct State: Equatable {
    let rowID: String
    var row: WorkflowSettingsRow?
    var runTargets: [WorkflowSettingsRunTarget]
    var bundleReview: WorkflowBundleReview?
    @Presents var alert: AlertState<Alert>?

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
    case reviewBundleTapped
    case reviewFileSelected(String)
    case approveBundleTapped
    case dismissBundleReview
    case revealInFinderTapped
    case runTapped(worktreeID: String, forceSheet: Bool)
    case manageProfilesTapped
    case deleteTapped
    case alert(PresentationAction<Alert>)
    case delegate(Delegate)
  }

  enum Alert: Equatable {
    case confirmDeletion(URL)
  }

  @CasePathable
  enum Delegate: Equatable {
    case setEnabled(settingsKey: String, enabled: Bool)
    case setRunSetup(settingsKey: String, mode: WorkflowBindModeOverride.Mode?)
    case setPreferredProfile(WorkflowBindingMemoryKey, UUID?)
    case runWorkflow(workflowKey: String, worktreeID: String, forceSheet: Bool)
    case manageProfiles
    case deleted
  }

  @Dependency(OpenURLClient.self) var openURLClient
  @Dependency(WorkflowSettingsClient.self) var client
  @Dependency(WorkflowBundleReviewClient.self) var bundleClient

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

      case .reviewBundleTapped:
        guard let row = state.row else { return .none }
        do { state.bundleReview = try bundleClient.load(row.url, row.scope) } catch {
          state.alert = AlertState {
            TextState("Cannot Review Bundle")
          } message: {
            TextState(String(describing: error))
          }
        }
        return .none

      case .reviewFileSelected(let path):
        guard state.bundleReview?.filePaths.contains(path) == true else { return .none }
        state.bundleReview?.selectedFile = path
        return .none

      case .approveBundleTapped:
        guard let review = state.bundleReview, !review.approved, !review.scripts.isEmpty else { return .none }
        do {
          try bundleClient.approve(review.snapshot)
          state.bundleReview?.approved = true
          state.bundleReview?.error = nil
        } catch { state.bundleReview?.error = "\(error)" }
        return .none

      case .dismissBundleReview:
        state.bundleReview = nil
        return .none

      case .openWorkflowTapped:
        guard let row = state.row else { return .none }
        openURLClient.open(row.url.appending(path: "workflow.yaml"))
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

      case .deleteTapped:
        guard let row = state.row, row.scope != .bundle else { return .none }
        state.alert = AlertState {
          TextState("Delete Workflow?")
        } actions: {
          ButtonState(role: .cancel) { TextState("Cancel") }
          ButtonState(role: .destructive, action: .confirmDeletion(row.url)) {
            TextState("Move to Trash")
          }
        } message: {
          TextState("“\(row.name)” (\(row.fileName)) will be moved to Trash. You can restore it in Finder.")
        }
        return .none

      case .alert(.presented(.confirmDeletion(let url))):
        guard let row = state.row, row.scope != .bundle, row.url == url else { return .none }
        do {
          try client.trashWorkflow(url)
          return .send(.delegate(.deleted))
        } catch {
          let message = (error as? WorkflowSettingsError)?.message ?? error.localizedDescription
          state.alert = AlertState {
            TextState("Could Not Delete Workflow")
          } actions: {
            ButtonState { TextState("OK") }
          } message: {
            TextState(message)
          }
          return .none
        }

      case .alert:
        return .none

      case .delegate:
        return .none
      }
    }
    .ifLet(\.$alert, action: \.alert)
  }
}
