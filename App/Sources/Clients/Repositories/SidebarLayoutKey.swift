import Dependencies
import Foundation
import Sharing

/// The sidebar layout (docs-ai 086): ungrouped repositories and groups in sidebar
/// order. On-disk location: `~/.prowl/sidebar-layout.json`.
///
/// When the file does not exist, the layout comes from the legacy
/// `repositoryOrderIDs` app storage value, with every repository at the top level.
nonisolated struct SidebarLayoutKeyID: Hashable, Sendable {}

nonisolated enum SidebarLayoutFileURLKey: DependencyKey {
  static var liveValue: URL { ProwlPaths.sidebarLayoutURL }
  static var previewValue: URL { ProwlPaths.sidebarLayoutURL }
  static var testValue: URL { ProwlPaths.sidebarLayoutURL }
}

extension DependencyValues {
  nonisolated var sidebarLayoutFileURL: URL {
    get { self[SidebarLayoutFileURLKey.self] }
    set { self[SidebarLayoutFileURLKey.self] = newValue }
  }
}

nonisolated struct SidebarLayoutKey: SharedKey {
  var id: SidebarLayoutKeyID {
    SidebarLayoutKeyID()
  }

  func load(
    context _: LoadContext<SidebarLayout>,
    continuation: LoadContinuation<SidebarLayout>
  ) {
    @Dependency(\.settingsFileStorage) var storage
    @Dependency(\.sidebarLayoutFileURL) var url
    if let data = try? storage.load(url) {
      do {
        let layout = try JSONDecoder().decode(SidebarLayout.self, from: data)
        continuation.resume(returning: layout.normalized())
        return
      } catch {
        // The next save replaces the file, so keep a copy that the user can restore.
        let backupURL = url.appendingPathExtension("unreadable")
        try? storage.save(data, backupURL)
        sidebarLayoutLogger.warning(
          "Cannot read \(url.lastPathComponent); kept a copy at \(backupURL.lastPathComponent): \(error)")
      }
    }
    @Shared(.appStorage("repositoryOrderIDs")) var legacyOrder: [Repository.ID] = []
    continuation.resume(
      returning: SidebarLayout(repositoryIDs: RepositoryOrderNormalizer.normalizeRepositoryIDs(legacyOrder)))
  }

  func subscribe(
    context _: LoadContext<SidebarLayout>,
    subscriber _: SharedSubscriber<SidebarLayout>
  ) -> SharedSubscription {
    SharedSubscription {}
  }

  func save(
    _ value: SidebarLayout,
    context _: SaveContext,
    continuation: SaveContinuation
  ) {
    @Dependency(\.settingsFileStorage) var storage
    @Dependency(\.sidebarLayoutFileURL) var url
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
      try storage.save(try encoder.encode(value.normalized()), url)
      continuation.resume()
    } catch {
      continuation.resume(throwing: error)
    }
  }
}

private nonisolated let sidebarLayoutLogger = ProwlLogger("Repositories")

nonisolated extension SharedReaderKey where Self == SidebarLayoutKey.Default {
  static var sidebarLayout: Self {
    Self[SidebarLayoutKey(), default: SidebarLayout()]
  }
}
