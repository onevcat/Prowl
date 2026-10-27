import ComposableArchitecture
import ConcurrencyExtras
import DependenciesTestSupport
import Foundation
import Testing

@testable import Prowl

/// The folder browser of the Add Remote Folder sheet.
@MainActor
struct RemoteFolderBrowserFeatureTests {
  private nonisolated static let profile = HostProfile(
    id: UUID(), alias: "mini", recipe: SSHConnectionRecipe(destination: "mini"),
    connectionKey: ConnectionKey(user: "dev", hostname: "mini.local"))

  private nonisolated static func entry(_ name: String, repository: Bool = false, accessible: Bool = true)
    -> RemoteFolderListing.Entry
  {
    RemoteFolderListing.Entry(name: name, isRepository: repository, isAccessible: accessible)
  }

  private nonisolated static let home = RemoteFolderListing(
    path: "/home/dev", home: "/home/dev", entries: [entry(".config"), entry("projects")], omittedCount: 0)
  private nonisolated static let projects = RemoteFolderListing(
    path: "/home/dev/projects", home: "/home/dev",
    entries: [entry("app", repository: true), entry("locked", accessible: false)], omittedCount: 0)
  private nonisolated static let app = RemoteFolderListing(
    path: "/home/dev/projects/app", home: "/home/dev", entries: [entry("src")], omittedCount: 0)

  /// A host with the three folders above; `~` is the home. Records the paths it is asked for.
  private static func host(asked: LockIsolated<[String]>) -> RemoteFolderValidatorClient {
    RemoteFolderValidatorClient(
      validate: { _, _, _, _ in throw RemoteRepositoryHostError.unsupported },
      listFolder: { existing, _, path, _ in
        #expect(existing?.id == profile.id)
        asked.withValue { $0.append(path) }
        switch path {
        case "~", "/home/dev": return home
        case "~/projects", "/home/dev/projects": return projects
        case "/home/dev/projects/app": return app
        default: throw RemoteFolderValidationError.folderNotFound(path)
        }
      })
  }

  private func makeStore(asked: LockIsolated<[String]>, path: String = "") -> TestStoreOf<AddRemoteFolderFeature> {
    var state = AddRemoteFolderFeature.State(hostProfiles: [Self.profile])
    state.path = path
    let store = TestStore(initialState: state) {
      AddRemoteFolderFeature()
    } withDependencies: {
      $0[RemoteFolderValidatorClient.self] = Self.host(asked: asked)
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    return store
  }

  /// The browser opens at the typed path, and the path field follows it: a subfolder that
  /// is selected or opened, and the enclosing folder, which selects the folder that was left.
  @Test(.dependencies) func thePathFieldFollowsTheBrowser() async {
    let asked = LockIsolated<[String]>([])
    let store = makeStore(asked: asked, path: "~/projects")

    await store.send(.browseButtonTapped)
    await store.receive(\.browser.listingLoaded)
    #expect(store.state.browser?.listing == Self.projects)
    #expect(store.state.path == "~/projects")

    await store.send(.browser(.selectionChanged("app")))
    #expect(store.state.path == "~/projects/app")

    await store.send(.browser(.entryOpened("app")))
    await store.receive(\.browser.listingLoaded)
    #expect(store.state.path == "~/projects/app")
    #expect(store.state.browser?.selectedName == nil)

    await store.send(.browser(.parentFolderOpened))
    #expect(store.state.browser?.listing == Self.projects)
    #expect(store.state.browser?.selectedName == "app")
    #expect(store.state.path == "~/projects/app")
    #expect(asked.value == ["~/projects", "/home/dev/projects/app"], "a folder seen before is not asked again")

    await store.send(.browser(.entryOpened("locked")))
    #expect(store.state.browser?.listing == Self.projects, "a folder that cannot be opened stays closed")

    await store.send(.browseButtonTapped)
    #expect(store.state.browser == nil)
    #expect(store.state.path == "~/projects/app")
  }

  /// An empty path starts at the home; a path that cannot be listed falls back to it.
  @Test(.dependencies) func theBrowserStartsAtTheHomeWhenThePathDoesNotHelp() async {
    let asked = LockIsolated<[String]>([])
    let store = makeStore(asked: asked, path: "/srv/none")

    await store.send(.browseButtonTapped)
    await store.receive(\.browser.listingFailed)
    await store.receive(\.browser.listingLoaded)
    #expect(store.state.browser?.listing == Self.home)
    #expect(store.state.browser?.errorMessage == nil)
    #expect(store.state.path == "~")
    #expect(asked.value == ["/srv/none", "~"])

    let empty = makeStore(asked: LockIsolated([]))
    await empty.send(.browseButtonTapped)
    await empty.receive(\.browser.listingLoaded)
    #expect(empty.state.browser?.listing == Self.home)
  }

  /// A failure in the browser shows its reason, and Try Again asks the host again.
  @Test(.dependencies) func aFailedListingShowsItsReasonAndCanBeTriedAgain() async {
    let fails = LockIsolated(true)
    let store = TestStore(initialState: AddRemoteFolderFeature.State(hostProfiles: [Self.profile])) {
      AddRemoteFolderFeature()
    } withDependencies: {
      $0[RemoteFolderValidatorClient.self] = RemoteFolderValidatorClient(
        validate: { _, _, _, _ in throw RemoteRepositoryHostError.unsupported },
        listFolder: { _, _, _, _ in
          if fails.value { throw RemoteFolderValidationError.folderInaccessible("~") }
          return Self.home
        })
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.browseButtonTapped)
    await store.receive(\.browser.listingFailed)
    #expect(store.state.browser?.errorMessage == "Prowl cannot open ~ on the host.")
    #expect(store.state.browser?.isLoading == false)

    fails.setValue(false)
    await store.send(.browser(.retryButtonTapped))
    await store.receive(\.browser.listingLoaded)
    #expect(store.state.browser?.errorMessage == nil)
    #expect(store.state.browser?.listing == Self.home)
  }

  /// A listing belongs to its host: choosing another host closes the browser. A new host
  /// needs a destination before it can be browsed.
  @Test(.dependencies) func anotherHostClosesTheBrowser() async {
    let store = makeStore(asked: LockIsolated([]))
    await store.send(.browseButtonTapped)
    await store.receive(\.browser.listingLoaded)

    await store.send(\.binding.selectedProfileID, Self.profile.id)
    await store.send(\.binding.destination, "")
    #expect(store.state.browser != nil, "a field that writes the same host again keeps the browser")

    await store.send(\.binding.selectedProfileID, nil)
    #expect(store.state.browser == nil)
    #expect(!store.state.canBrowse)
    await store.send(.browseButtonTapped)
    #expect(store.state.browser == nil)
    await store.send(\.binding.destination, "dev@build")
    #expect(store.state.canBrowse)
  }

  /// Hiding hidden folders drops a hidden selection, so the sheet never adds a folder that
  /// the list does not show.
  @Test(.dependencies) func hidingHiddenFoldersDropsAHiddenSelection() async {
    let store = makeStore(asked: LockIsolated([]))
    await store.send(.browseButtonTapped)
    await store.receive(\.browser.listingLoaded)
    #expect(store.state.browser?.visibleEntries.map(\.name) == ["projects"])

    await store.send(.browser(.showsHiddenFoldersToggled))
    #expect(store.state.browser?.visibleEntries.map(\.name) == [".config", "projects"])
    await store.send(.browser(.selectionChanged(".config")))
    #expect(store.state.path == "~/.config")

    await store.send(.browser(.showsHiddenFoldersToggled))
    #expect(store.state.browser?.selectedName == nil)
    #expect(store.state.path == "~")
  }

  /// A typed path takes over from the browser: a listing that arrives later and a change
  /// that the browser makes on its own leave it. The next move in the browser takes the
  /// field back.
  @Test(.dependencies) func aTypedPathIsNotReplacedUntilTheBrowserIsUsedAgain() async {
    let (gate, open) = AsyncStream<Void>.makeStream()
    let store = TestStore(initialState: AddRemoteFolderFeature.State(hostProfiles: [Self.profile])) {
      AddRemoteFolderFeature()
    } withDependencies: {
      $0[RemoteFolderValidatorClient.self] = RemoteFolderValidatorClient(
        validate: { _, _, _, _ in throw RemoteRepositoryHostError.unsupported },
        listFolder: { _, _, path, _ in
          switch path {
          case "~", "/home/dev": return Self.home
          case "/home/dev/projects": return Self.projects
          default:
            for await _ in gate { break }
            return Self.app
          }
        })
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.browseButtonTapped)
    await store.receive(\.browser.listingLoaded)
    await store.send(.browser(.entryOpened("projects")))
    await store.receive(\.browser.listingLoaded)
    await store.send(.browser(.selectionChanged("app")))
    #expect(store.state.path == "~/projects/app")

    await store.send(.browser(.entryOpened("app")))
    await store.send(\.binding.path, "~/typed")
    open.yield()
    open.finish()
    await store.receive(\.browser.listingLoaded)
    #expect(store.state.browser?.listing == Self.app)
    #expect(store.state.path == "~/typed")
    await store.send(.browser(.showsHiddenFoldersToggled))
    #expect(store.state.path == "~/typed")

    await store.send(.browser(.selectionChanged("src")))
    #expect(store.state.path == "~/projects/app/src")
  }

  /// A folder chosen in the browser is added as it is named, also when the name ends with a
  /// space; a typed path is trimmed.
  @Test(.dependencies) func aChosenFolderIsAddedWithItsExactName() async {
    let asked = LockIsolated<[String]>([])
    let spaced = RemoteFolderListing(
      path: "/home/dev", home: "/home/dev", entries: [Self.entry("app"), Self.entry("app ")], omittedCount: 0)
    let store = TestStore(initialState: AddRemoteFolderFeature.State(hostProfiles: [Self.profile])) {
      AddRemoteFolderFeature()
    } withDependencies: {
      $0[RemoteFolderValidatorClient.self] = RemoteFolderValidatorClient(
        validate: { _, _, path, _ in
          asked.withValue { $0.append(path) }
          throw RemoteFolderValidationError.folderNotFound(path)
        },
        listFolder: { _, _, path, _ in
          asked.withValue { $0.append(path) }
          return spaced
        })
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.browseButtonTapped)
    await store.receive(\.browser.listingLoaded)
    await store.send(.browser(.selectionChanged("app ")))
    #expect(store.state.path == "~/app ")
    await store.send(.addButtonTapped)
    await store.receive(\.validationFailed)

    await store.send(.browseButtonTapped)
    await store.send(.browseButtonTapped)
    await store.receive(\.browser.listingLoaded)
    await store.send(\.binding.path, "  ~/typed \n")
    await store.send(.addButtonTapped)
    await store.receive(\.validationFailed)
    #expect(asked.value == ["~", "~/app ", "~/app ", "~/typed"])
  }

  /// The path bar starts at `~` inside the home and at `/` outside it.
  @Test func thePathBarStartsAtTheHomeOrTheRoot() {
    var state = RemoteFolderBrowserFeature.State(host: .init(existing: nil, destination: "mini", knownProfiles: []))
    state.listing = Self.app
    #expect(state.pathComponents.map(\.title) == ["~", "projects", "app"])
    #expect(state.pathComponents.map(\.path) == ["/home/dev", "/home/dev/projects", "/home/dev/projects/app"])
    #expect(state.parentPath == "/home/dev/projects")

    state.listing = RemoteFolderListing(path: "/srv/app", home: "/home/dev", entries: [], omittedCount: 0)
    #expect(state.pathComponents.map(\.title) == ["/", "srv", "app"])
    #expect(state.chosenPath == "/srv/app")

    state.listing = RemoteFolderListing(path: "/", home: nil, entries: [], omittedCount: 0)
    #expect(state.pathComponents.map(\.title) == ["/"])
    #expect(state.parentPath == nil)
    #expect(RemoteFolderBrowserFeature.State.displayPath("/home/devel", home: "/home/dev") == "/home/devel")
  }
}
