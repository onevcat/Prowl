import ComposableArchitecture
import Foundation

/// The folder browser of the Add Remote Folder sheet: it lists the subfolders of a folder
/// on the host, one folder at a time, so the path does not have to be typed. The sheet adds
/// `chosenPath`.
@Reducer
struct RemoteFolderBrowserFeature {
  /// The host to browse, as the sheet names it when the browser opens.
  struct Host: Equatable {
    var existing: HostProfile?
    var destination: String
    var knownProfiles: [HostProfile]
  }

  @ObservableState
  struct State: Equatable {
    let host: Host
    /// The folder shown; nil until the first listing arrives.
    var listing: RemoteFolderListing?
    var selectedName: String?
    var showsHiddenFolders = false
    /// The folder that is loading; nil when no listing is in flight.
    var loadingPath: String?
    var errorMessage: String?
    /// The folder that failed to load, for Retry.
    var failedPath: String?
    /// The folders listed while the sheet is open, by requested and resolved path, so going
    /// back to one does not ask the host again.
    var cache: [String: RemoteFolderListing] = [:]

    init(host: Host) {
      self.host = host
    }

    var isLoading: Bool { loadingPath != nil }

    var visibleEntries: [RemoteFolderListing.Entry] {
      guard let listing else { return [] }
      return showsHiddenFolders ? listing.entries : listing.entries.filter { !$0.isHidden }
    }

    /// The selected subfolder, or the folder shown, with the home written as `~`.
    var chosenPath: String? {
      guard let listing else { return nil }
      let path = selectedName.map { Self.path(of: $0, in: listing.path) } ?? listing.path
      return Self.displayPath(path, home: listing.home)
    }

    var parentPath: String? {
      guard let path = listing?.path, path != "/" else { return nil }
      let parent = path.split(separator: "/").dropLast().joined(separator: "/")
      return "/" + parent
    }

    /// The folders from the home (or from `/`) down to the folder shown.
    var pathComponents: [PathComponent] {
      guard let listing else { return [] }
      var components: [PathComponent]
      var remainder: Substring
      if let home = listing.home, home != "/", listing.path == home || listing.path.hasPrefix(home + "/") {
        components = [PathComponent(title: "~", path: home)]
        remainder = listing.path.dropFirst(home.count)
      } else {
        components = [PathComponent(title: "/", path: "/")]
        remainder = Substring(listing.path)
      }
      var path = components[0].path
      for name in remainder.split(separator: "/") {
        path = Self.path(of: String(name), in: path)
        components.append(PathComponent(title: String(name), path: path))
      }
      return components
    }

    static func path(of name: String, in folder: String) -> String {
      folder == "/" ? "/" + name : folder + "/" + name
    }

    static func displayPath(_ path: String, home: String?) -> String {
      guard let home, home != "/" else { return path }
      if path == home { return "~" }
      if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
      return path
    }
  }

  struct PathComponent: Equatable, Identifiable {
    let title: String
    let path: String
    var id: String { path }
  }

  enum Action: Equatable {
    /// Opens the browser at `path`, or at the home when `path` is empty or cannot be listed.
    case start(path: String)
    case selectionChanged(String?)
    /// Shows a subfolder of the folder shown.
    case entryOpened(String)
    case parentFolderOpened
    case folderOpened(String)
    case showsHiddenFoldersToggled
    case retryButtonTapped
    case listingLoaded(requestedPath: String, RemoteFolderListing, selecting: String?)
    case listingFailed(requestedPath: String, message: String, fallsBackToHome: Bool)
  }

  private nonisolated enum CancelID { case listing }

  @Dependency(RemoteFolderValidatorClient.self) var validator

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .start(let path):
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return load(path.isEmpty ? "~" : path, in: &state, fallsBackToHome: !path.isEmpty && path != "~")

      case .selectionChanged(let name):
        state.selectedName = name
        return .none

      case .entryOpened(let name):
        guard let listing = state.listing,
          let entry = listing.entries.first(where: { $0.name == name }), entry.isAccessible
        else { return .none }
        return load(State.path(of: name, in: listing.path), in: &state)

      case .parentFolderOpened:
        guard let listing = state.listing, let parent = state.parentPath else { return .none }
        // Finder selects the folder that was left.
        let name = listing.path.split(separator: "/").last.map(String.init)
        return load(parent, in: &state, selecting: name)

      case .folderOpened(let path):
        return load(path, in: &state)

      case .showsHiddenFoldersToggled:
        state.showsHiddenFolders.toggle()
        if !state.showsHiddenFolders, state.selectedName?.hasPrefix(".") == true {
          state.selectedName = nil
        }
        return .none

      case .retryButtonTapped:
        guard let path = state.failedPath ?? state.listing?.path else { return .none }
        return load(path, in: &state)

      case .listingLoaded(let requestedPath, let listing, let selecting):
        guard state.loadingPath == requestedPath else { return .none }
        state.cache[requestedPath] = listing
        state.cache[listing.path] = listing
        show(listing, in: &state, selecting: selecting)
        return .none

      case .listingFailed(let requestedPath, let message, let fallsBackToHome):
        guard state.loadingPath == requestedPath else { return .none }
        if fallsBackToHome {
          return load("~", in: &state)
        }
        state.loadingPath = nil
        state.errorMessage = message
        state.failedPath = requestedPath
        return .none
      }
    }
  }

  private func load(
    _ path: String, in state: inout State, selecting: String? = nil, fallsBackToHome: Bool = false
  ) -> Effect<Action> {
    if let cached = state.cache[path] {
      show(cached, in: &state, selecting: selecting)
      return .cancel(id: CancelID.listing)
    }
    state.loadingPath = path
    let host = state.host
    let validator = validator
    return .run { send in
      do {
        let listing = try await validator.listFolder(host.existing, host.destination, path, host.knownProfiles)
        await send(.listingLoaded(requestedPath: path, listing, selecting: selecting))
      } catch is CancellationError {
        return
      } catch {
        await send(
          .listingFailed(requestedPath: path, message: error.localizedDescription, fallsBackToHome: fallsBackToHome))
      }
    }
    .cancellable(id: CancelID.listing, cancelInFlight: true)
  }

  private func show(_ listing: RemoteFolderListing, in state: inout State, selecting: String?) {
    state.listing = listing
    state.loadingPath = nil
    state.errorMessage = nil
    state.failedPath = nil
    state.selectedName = selecting.flatMap { name in
      state.visibleEntries.contains { $0.name == name } ? name : nil
    }
  }
}
