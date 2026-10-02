import Dependencies
import Foundation
import Sharing

nonisolated struct SettingsFileStorage: Sendable {
  var load: @Sendable (URL) throws -> Data
  var save: @Sendable (Data, URL) throws -> Void
}

nonisolated enum SettingsFileStorageKey: DependencyKey {
  static var liveValue: SettingsFileStorage {
    SettingsFileStorage(
      load: { url in
        let data = try Data(contentsOf: url)
        // Files written before saves enforced 0600 migrate on first read
        // (docs-ai 053/005), not on their next save.
        SymlinkPreservingFileWriter.restrictToOwnerOnly(url)
        return data
      },
      // Follows a symlinked destination to its real file so a user who links
      // `~/.prowl/settings.json` (and the repository-entries / appearances
      // files that share this closure) into a dotfiles repo keeps the link
      // instead of having it replaced with a plain file on every save (#478).
      save: { data, url in try SymlinkPreservingFileWriter.write(data, to: url) }
    )
  }
  static var previewValue: SettingsFileStorage { .inMemory() }
  static var testValue: SettingsFileStorage { .inMemory() }
}

nonisolated enum SettingsFileURLKey: DependencyKey {
  static var liveValue: URL { SupacodePaths.settingsURL }
  static var previewValue: URL { SupacodePaths.settingsURL }
  static var testValue: URL { SupacodePaths.settingsURL }
}

extension DependencyValues {
  nonisolated var settingsFileStorage: SettingsFileStorage {
    get { self[SettingsFileStorageKey.self] }
    set { self[SettingsFileStorageKey.self] = newValue }
  }

  nonisolated var settingsFileURL: URL {
    get { self[SettingsFileURLKey.self] }
    set { self[SettingsFileURLKey.self] = newValue }
  }
}

extension SettingsFileStorage {
  nonisolated static func inMemory() -> SettingsFileStorage {
    let storage = InMemorySettingsFileStorage()
    return SettingsFileStorage(
      load: { try storage.load($0) },
      save: { try storage.save($0, $1) }
    )
  }
}

nonisolated enum SettingsFileStorageError: Error {
  case missing
}

nonisolated final class InMemorySettingsFileStorage: @unchecked Sendable {
  private let lock = NSLock()
  private var dataByURL: [URL: Data] = [:]

  func load(_ url: URL) throws -> Data {
    lock.lock()
    defer { lock.unlock() }
    guard let data = dataByURL[url] else {
      throw SettingsFileStorageError.missing
    }
    return data
  }

  func save(_ data: Data, _ url: URL) throws {
    lock.lock()
    defer { lock.unlock() }
    dataByURL[url] = data
  }

}

nonisolated struct SettingsFileKeyID: Hashable, Sendable {
  let url: URL
}

nonisolated struct SettingsFileKey: SharedKey {
  let url: URL

  init(url: URL? = nil) {
    if let url {
      self.url = url
      return
    }
    @Dependency(\.settingsFileURL) var settingsFileURL
    self.url = settingsFileURL
  }

  var id: SettingsFileKeyID {
    SettingsFileKeyID(url: url)
  }

  func load(context: LoadContext<SettingsFile>, continuation: LoadContinuation<SettingsFile>) {
    @Dependency(\.settingsFileStorage) var storage
    let decoder = Self.makeDecoder()
    if let data = try? storage.load(url),
      let settings = try? decoder.decode(SettingsFile.self, from: data)
    {
      continuation.resume(returning: settings)
      return
    }

    let initial = context.initialValue ?? .default
    _ = try? save(initial, storage: storage)
    continuation.resumeReturningInitialValue()
  }

  func subscribe(
    context _: LoadContext<SettingsFile>,
    subscriber _: SharedSubscriber<SettingsFile>
  ) -> SharedSubscription {
    SharedSubscription {}
  }

  func save(_ value: SettingsFile, context _: SaveContext, continuation: SaveContinuation) {
    @Dependency(\.settingsFileStorage) var storage
    do {
      try save(value, storage: storage)
      continuation.resume()
    } catch {
      continuation.resume(throwing: error)
    }
  }

  private func save(_ value: SettingsFile, storage: SettingsFileStorage) throws {
    let data = try Self.makeEncoder().encode(value)
    try storage.save(data, url)
  }

  private static func makeDecoder() -> JSONDecoder {
    JSONDecoder()
  }

  private static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }
}

nonisolated extension SharedReaderKey where Self == SettingsFileKey.Default {
  static var settingsFile: Self {
    Self[SettingsFileKey(), default: .default]
  }
}
