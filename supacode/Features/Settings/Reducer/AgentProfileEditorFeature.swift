import ComposableArchitecture
import Foundation
import Sharing
import SwiftUI

/// Settings → Agents → Profiles → drill-in editor for one profile (docs-ai 053). Owns
/// every profile-scoped mutation gate (unrestricted confirmation, removal
/// confirmation) and its own alert: the presentation state lives inside the
/// pushed page's state, so an alert can only ever fire while the page that
/// hosts its modifier is mounted.
@Reducer
struct AgentProfileEditorFeature {
  @ObservableState
  struct State: Equatable {
    var profile: AgentProfile
    /// Passive filesystem check for the bound profile's home; never invokes a
    /// CLI (docs-ai 053: no login-status probing).
    var homeInitialized = false
    @Presents var alert: AlertState<Alert>?

    init(profile: AgentProfile) {
      self.profile = profile
    }
  }

  enum Action: BindableAction {
    case task
    case runtimeChanged(AgentProfileRuntime)
    case setIcon(String?)
    case addEnvironmentOverride
    case removeEnvironmentOverride(AgentProfileEnvironmentOverride.ID)
    case binding(BindingAction<State>)
    case removeTapped
    case revealProfileFiles
    case homeStatusRefreshed(Bool)
    case alert(PresentationAction<Alert>)
    case delegate(Delegate)
  }

  enum Alert: Equatable {
    case confirmUnrestricted
    case removeKeepingFiles
    case removeTrashingFiles
  }

  @CasePathable
  enum Delegate: Equatable {
    case profileEdited(AgentProfile)
    /// Removal is delegated to the parent: it survives this page's dismissal,
    /// so the trash effect cannot be cancelled mid-flight.
    case removeProfile(AgentProfile.ID, trashFiles: Bool)
  }

  @Dependency(AgentProfileHomeClient.self) var homeClient
  @Dependency(\.uuid) var uuid

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .task:
        refreshHomeStatus(&state)
        return .none

      case .runtimeChanged(let runtime):
        guard state.profile.runtime != runtime else { return .none }
        // Model, effort, literal CLI arguments, environment overrides, and
        // unrestricted approval belong to the selected runtime. The target CLI
        // requires its own explicit confirmation before it can bypass
        // safeguards.
        state.profile.runtime = runtime
        state.profile.model = nil
        state.profile.reasoningEffort = nil
        state.profile.extraArguments = ""
        state.profile.environmentOverrides = []
        state.profile.executionMode = .standard
        if AgentRuntimeAdapterRegistry.profileAdapter(for: runtime)?.supportsAccountIsolation != true {
          state.profile.bindsDedicatedHome = false
        }
        refreshHomeStatus(&state)
        return .send(.delegate(.profileEdited(state.profile)))

      case .setIcon(let icon):
        guard state.profile.icon != icon else { return .none }
        state.profile.icon = icon
        return .send(.delegate(.profileEdited(state.profile)))

      case .addEnvironmentOverride:
        state.profile.environmentOverrides.append(AgentProfileEnvironmentOverride(id: uuid()))
        return .send(.delegate(.profileEdited(state.profile)))

      case .removeEnvironmentOverride(let id):
        state.profile.environmentOverrides.removeAll { $0.id == id }
        return .send(.delegate(.profileEdited(state.profile)))
      case .binding:
        // `.unrestricted` is never applied silently: the change reverts until
        // the user explicitly confirms it (docs-ai 053).
        if newlyUnrestricted(state.profile) {
          state.profile.executionMode = persistedExecutionMode(for: state.profile.id)
          state.alert = Self.unrestrictedAlert()
          return .none
        }
        refreshHomeStatus(&state)
        return .send(.delegate(.profileEdited(state.profile)))

      case .removeTapped:
        // A previously bound profile can still own credentials on disk after
        // being unbound, so its removal must preserve the trash choice.
        let hasProfileHome = state.profile.bindsDedicatedHome || homeClient.homeExists(state.profile.id)
        state.alert = Self.removalAlert(profile: state.profile, hasProfileHome: hasProfileHome)
        return .none

      case .revealProfileFiles:
        guard state.profile.bindsDedicatedHome else { return .none }
        let id = state.profile.id
        let client = homeClient
        return .run { send in
          // Reveal provisions the home when missing; report the fresh status
          // so the passive indicator doesn't keep saying "Not initialized".
          client.revealHome(id)
          await send(.homeStatusRefreshed(client.homeExists(id)))
        }

      case .homeStatusRefreshed(let initialized):
        state.homeInitialized = initialized
        return .none

      case .alert(.presented(.confirmUnrestricted)):
        state.profile.executionMode = .unrestricted
        return .send(.delegate(.profileEdited(state.profile)))

      case .alert(.presented(.removeKeepingFiles)):
        return .send(.delegate(.removeProfile(state.profile.id, trashFiles: false)))

      case .alert(.presented(.removeTrashingFiles)):
        return .send(.delegate(.removeProfile(state.profile.id, trashFiles: true)))

      case .alert:
        return .none

      case .delegate:
        return .none
      }
    }
    .ifLet(\.$alert, action: \.alert)
  }

  /// "Newly" is judged against the persisted settings, exactly like the
  /// pre-split reducer did: confirming once persists `.unrestricted`, so
  /// re-toggling after an intermediate `.standard` asks again.
  private func newlyUnrestricted(_ profile: AgentProfile) -> Bool {
    guard profile.executionMode == .unrestricted else { return false }
    return persistedExecutionMode(for: profile.id) != .unrestricted
  }

  private func persistedExecutionMode(for id: AgentProfile.ID) -> AgentExecutionMode {
    @Shared(.userGlobalSettings) var persisted
    return persisted.agentProfiles.first { $0.id == id }?.executionMode ?? .standard
  }

  private func refreshHomeStatus(_ state: inout State) {
    guard state.profile.bindsDedicatedHome else {
      state.homeInitialized = false
      return
    }
    state.homeInitialized = homeClient.homeExists(state.profile.id)
  }

  static func unrestrictedAlert() -> AlertState<Alert> {
    AlertState {
      TextState(String(localized: "Allow Unrestricted Execution?"))
    } actions: {
      ButtonState(role: .destructive, action: .confirmUnrestricted) {
        TextState(String(localized: "Allow Unrestricted"))
      }
      ButtonState(role: .cancel) {
        TextState(String(localized: "Cancel"))
      }
    } message: {
      TextState(
        String(
          localized: """
            The agent will use the runtime's least-restricted mode. It may execute commands and modify files \
            without prompting; managed or user-defined runtime policies can still apply.
            """
        )
      )
    }
  }

  static func removalAlert(profile: AgentProfile, hasProfileHome: Bool) -> AlertState<Alert> {
    AlertState {
      TextState(String(localized: "Remove “\(profile.name)”?"))
    } actions: {
      ButtonState(role: .destructive, action: .removeKeepingFiles) {
        TextState(String(localized: "Remove Profile"))
      }
      if hasProfileHome {
        ButtonState(role: .destructive, action: .removeTrashingFiles) {
          TextState(String(localized: "Remove and Trash Files"))
        }
      }
      ButtonState(role: .cancel) {
        TextState(String(localized: "Cancel"))
      }
    } message: {
      TextState(
        hasProfileHome
          ? String(
            localized:
              "“Remove Profile” keeps the profile folder on disk; “Remove and Trash Files” moves it to the Trash.")
          : String(localized: "This removes the profile from Prowl. No files will be deleted.")
      )
    }
  }
}
