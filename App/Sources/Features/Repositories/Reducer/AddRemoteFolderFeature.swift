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
    /// The folder browser; nil while it is hidden. It fills `path` as it moves.
    var browser: RemoteFolderBrowserFeature.State?
    /// False after a path is typed, until the browser is used again: a listing that arrives
    /// later must not replace the typed path.
    var pathFollowsBrowser = false
    /// The last path that the browser wrote. While `path` is still that path, it is the
    /// exact name of a folder on the host and is sent as it is, not trimmed as typed text.
    var browserPath: String?

    init(hostProfiles: [HostProfile]) {
      self.hostProfiles = hostProfiles
      selectedProfileID = hostProfiles.last?.id
    }

    var selectedProfile: HostProfile? {
      hostProfiles.first { $0.id == selectedProfileID }
    }

    /// Whether the sheet still names the host that the browser lists.
    func names(_ host: RemoteFolderBrowserFeature.Host) -> Bool {
      guard let profile = selectedProfile else { return host.existing == nil && host.destination == destination }
      return host.existing?.id == profile.id
    }

    var canBrowse: Bool {
      !isValidating && (selectedProfile != nil || !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// The path to send to the host.
    var requestedPath: String {
      path == browserPath ? path : path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canAdd: Bool {
      !isValidating && !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && (selectedProfile != nil || !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    case addButtonTapped
    case browseButtonTapped
    case browser(RemoteFolderBrowserFeature.Action)
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
      .onChange(of: \.path) { _, _ in
        Reduce { state, _ in
          state.pathFollowsBrowser = false
          return .none
        }
      }
    Reduce { state, action in
      switch action {
      case .binding:
        state.errorMessage = nil
        state.pendingRebind = nil
        // A listing belongs to the host that it was read from. A text field writes its
        // value again when it loses focus, so only a changed host counts.
        if let host = state.browser?.host, !state.names(host) {
          state.browser = nil
        }
        return .none

      case .browseButtonTapped:
        if state.browser != nil {
          state.browser = nil
          return .none
        }
        guard state.canBrowse else { return .none }
        state.browser = RemoteFolderBrowserFeature.State(
          host: .init(
            existing: state.selectedProfile, destination: state.destination, knownProfiles: state.hostProfiles))
        state.pathFollowsBrowser = true
        return .send(.browser(.start(path: state.requestedPath)))

      case .browser(let action):
        if action.isMove { state.pathFollowsBrowser = true }
        return .none

      case .addButtonTapped:
        guard state.canAdd else { return .none }
        state.isValidating = true
        state.errorMessage = nil
        state.pendingRebind = nil
        let (existing, destination, path, known) = (
          state.selectedProfile, state.destination, state.requestedPath, state.hostProfiles
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
        // The browser lists through the profile as it was when it opened.
        state.browser = nil
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
    .ifLet(\.browser, action: \.browser) {
      RemoteFolderBrowserFeature()
    }
    Reduce { state, action in
      // After the browser ran, so the field shows where it moved. The choice is recorded
      // also when the field already shows it, so a typed name that the browser confirms is
      // sent as it is.
      if case .browser = action, state.pathFollowsBrowser, let path = state.browser?.chosenPath {
        state.browserPath = path
        if path != state.path {
          state.path = path
          state.errorMessage = nil
        }
      }
      return .none
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
