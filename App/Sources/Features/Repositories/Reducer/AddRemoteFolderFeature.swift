import ComposableArchitecture
import Foundation
import Sharing

/// The Add Remote Folder sheet (docs-ai 084 C1, D7): a host (an existing profile or a new
/// destination) and a path, checked on the host before the folder is added. Adding a
/// folder is consent for its host profile (D2): the sheet says that Prowl keeps a
/// background connection to the host.
@Reducer
struct AddRemoteFolderFeature {
  @ObservableState
  struct State: Equatable {
    /// The known host profiles, newest last.
    var hostProfiles: [HostProfile]
    /// The chosen profile; nil for a new host.
    var selectedProfileID: HostProfile.ID?
    var destination = ""
    var path = ""
    var isValidating = false
    var errorMessage: String?
    /// A known host whose SSH configuration now reaches another target; the sheet offers to
    /// rebind it and add the folder (C1b).
    var pendingRebind: RemoteHostTarget?

    init(hostProfiles: [HostProfile]) {
      self.hostProfiles = hostProfiles
      selectedProfileID = hostProfiles.last?.id
    }

    var selectedProfile: HostProfile? {
      hostProfiles.first { $0.id == selectedProfileID }
    }

    var canAdd: Bool {
      !isValidating && !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && (selectedProfile != nil || !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    case addButtonTapped
    case cancelButtonTapped
    case validationFinished(ValidatedRemoteFolder)
    case validationFailed(String)
    case validationNeedsRebind(RemoteHostTarget, message: String)
    case rebindButtonTapped
    case rebound(RemoteHostTarget)
    case delegate(Delegate)
  }

  @CasePathable
  enum Delegate: Equatable {
    case added(RepositoryLocation, kind: Repository.Kind)
    /// The host profile has a new target; its other folders connect again.
    case hostRebound(HostProfile.ID)
    case cancel
  }

  @Dependency(RemoteFolderValidatorClient.self) var validator

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        state.errorMessage = nil
        state.pendingRebind = nil
        return .none

      case .addButtonTapped:
        guard state.canAdd else { return .none }
        state.isValidating = true
        state.errorMessage = nil
        state.pendingRebind = nil
        let (existing, destination, path, known) = (
          state.selectedProfile, state.destination, state.path, state.hostProfiles
        )
        let validator = validator
        return .run { send in
          do {
            let folder = try await validator.validate(existing, destination, path, known)
            if folder.isNewProfile { try await Self.save(folder.profile) }
            await send(.validationFinished(folder))
          } catch RemoteFolderValidationError.authorityChanged(let profile, let resolved) {
            let error = RemoteFolderValidationError.authorityChanged(profile, resolved: resolved)
            await send(
              .validationNeedsRebind(
                RemoteHostTarget(profile: profile, resolved: resolved), message: error.localizedDescription))
          } catch {
            await send(.validationFailed(error.localizedDescription))
          }
        }

      case .validationNeedsRebind(let target, let message):
        state.isValidating = false
        state.errorMessage = message
        state.pendingRebind = target
        return .none

      case .rebindButtonTapped:
        guard let target = state.pendingRebind, !state.isValidating else { return .none }
        state.isValidating = true
        return .run { send in
          do {
            try await RepositoriesFeature.storeHostTarget(target.resolved, for: target.profile.id)
            await send(.rebound(target))
          } catch {
            await send(.validationFailed(error.localizedDescription))
          }
        }

      case .rebound(let target):
        state.isValidating = false
        state.pendingRebind = nil
        if let index = state.hostProfiles.firstIndex(where: { $0.id == target.profile.id }) {
          state.hostProfiles[index].connectionKey = target.resolved
        }
        return .merge(.send(.delegate(.hostRebound(target.profile.id))), .send(.addButtonTapped))

      case .cancelButtonTapped:
        // The check stores a new host profile before it ends; closing in between would
        // leave a consented host without its folder.
        guard !state.isValidating else { return .none }
        return .send(.delegate(.cancel))

      case .validationFinished(let folder):
        state.isValidating = false
        return .send(.delegate(.added(folder.location, kind: folder.kind)))

      case .validationFailed(let message):
        state.isValidating = false
        state.errorMessage = message
        return .none

      case .delegate:
        return .none
      }
    }
  }

  /// Stores a new host profile before its folder is added, so the entry never refers to a
  /// host that `hosts.json` lacks. A file that changed since it was loaded is read again
  /// first (B2b), and nothing is added when it cannot be written.
  private static func save(_ profile: HostProfile) async throws {
    @Shared(.hostProfiles) var hostProfiles: [HostProfile]
    $hostProfiles.withLock { $0.append(profile) }
    if case .unreadableFile? = $hostProfiles.saveError as? HostProfilesFileError {
      try? await $hostProfiles.load()
      throw RemoteFolderValidationError.hostsFileUnreadable
    }
    if case .changedSinceLoad? = $hostProfiles.saveError as? HostProfilesFileError {
      try await $hostProfiles.load()
      $hostProfiles.withLock { profiles in
        if !profiles.contains(where: { $0.id == profile.id }) { profiles.append(profile) }
      }
    }
    guard $hostProfiles.saveError == nil else {
      // Keep the in-memory list as the file has it.
      try? await $hostProfiles.load()
      throw RemoteFolderValidationError.hostsFileNotSaved
    }
  }
}
