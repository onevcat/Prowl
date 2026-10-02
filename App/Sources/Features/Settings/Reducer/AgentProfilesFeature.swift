import ComposableArchitecture
import Foundation
import Sharing
import SwiftUI

/// Settings → Agents → Profiles: the global agent profile list (docs-ai 053). List order
/// is the recommendation fallback order; edits persist to
/// `UserGlobalSettings` the same way global custom commands do. Editing one
/// profile is a native drill-in `AgentProfileEditorFeature` represented by a
/// stack path.
@Reducer
struct AgentProfilesFeature {
  @ObservableState
  struct State: Equatable {
    var settings: UserGlobalSettings = .default
    var path = StackState<AgentProfileEditorFeature.State>()
  }

  enum Action: BindableAction {
    case task
    case settingsLoaded(UserGlobalSettings)
    case binding(BindingAction<State>)
    case addProfile(AgentProfileRuntime)
    case moveProfiles(IndexSet, Int)
    case path(StackActionOf<AgentProfileEditorFeature>)
    case delegate(Delegate)
  }

  @CasePathable
  enum Delegate: Equatable {
    case settingsChanged(UserGlobalSettings)
  }

  @Dependency(AgentProfileHomeClient.self) var homeClient
  @Dependency(\.uuid) var uuid

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .task:
        return .run { send in
          @Shared(.userGlobalSettings) var settings
          await send(.settingsLoaded(settings))
        }

      case .settingsLoaded(let settings):
        state.settings = settings.normalized()
        return .none

      case .binding:
        // Only list-level bindings arrive here (the enabled checkboxes);
        // profile edits flow through the editor's delegate.
        return persist(state.settings)

      case .addProfile(let runtime):
        let profile = AgentProfile(
          id: uuid(),
          name: AgentRuntimeAdapterRegistry.displayName(for: runtime),
          runtime: runtime
        )
        state.settings.agentProfiles.append(profile)
        state.settings = state.settings.normalized()
        state.path.append(AgentProfileEditorFeature.State(profile: profile))
        return persist(state.settings)

      case .moveProfiles(let source, let destination):
        state.settings.agentProfiles.move(fromOffsets: source, toOffset: destination)
        return persist(state.settings)

      case .path(.element(id: _, action: .delegate(.profileEdited(let profile)))):
        guard let index = state.settings.agentProfiles.firstIndex(where: { $0.id == profile.id })
        else { return .none }
        state.settings.agentProfiles[index] = profile
        return persist(state.settings)

      case .path(.element(id: _, action: .delegate(.removeProfile(let profileID, let trashFiles)))):
        state.settings.agentProfiles.removeAll { $0.id == profileID }
        // Dismissing returns the split view to the Agents root before the
        // trash effect runs, so it cannot be cancelled with the destination.
        state.path.removeAll()
        guard trashFiles else { return persist(state.settings) }
        let client = homeClient
        return .merge(
          persist(state.settings),
          .run { _ in
            do {
              try await client.trashHome(profileID)
            } catch {
              SupaLogger("Settings").warning("Unable to trash profile home: \(error)")
            }
          }
        )

      case .path:
        return .none

      case .delegate:
        return .none
      }
    }
    .forEach(\.path, action: \.path) {
      AgentProfileEditorFeature()
    }
  }

  private func persist(_ settings: UserGlobalSettings) -> Effect<Action> {
    // The write happens synchronously in the reducer: this pane's state is
    // removed on every Settings sidebar switch, and `forEach` cancels in-flight
    // child effects — a persist living inside `.run` could be cancelled and
    // silently drop the edit (or resurrect a removed profile).
    @Shared(.userGlobalSettings) var storedSettings
    let sanitized = Self.sanitizedForPersistence(settings, persisted: storedSettings)
    $storedSettings.withLock { $0 = sanitized }
    return .send(.delegate(.settingsChanged(sanitized)))
  }

  /// A blank name must never reach disk: decode-time normalization drops
  /// blank-named profiles, which would silently delete the profile (and
  /// orphan a bound home) on the next load. An in-progress blank name keeps
  /// its last persisted name — standard rename-revert semantics — while the
  /// editor state keeps whatever the user is typing.
  nonisolated static func sanitizedForPersistence(
    _ edited: UserGlobalSettings,
    persisted: UserGlobalSettings
  ) -> UserGlobalSettings {
    var settings = edited
    settings.agentProfiles = settings.agentProfiles.map { profile in
      var profile = profile
      if profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        profile.name =
          persisted.agentProfiles.first { $0.id == profile.id }?.name
          ?? AgentRuntimeAdapterRegistry.displayName(for: profile.runtime)
      }
      return profile
    }
    return settings.normalized()
  }
}
