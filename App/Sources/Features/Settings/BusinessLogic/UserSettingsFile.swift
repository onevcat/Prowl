import Foundation

/// Strict persistence for the two user settings files. Only missing paths permit
/// fallback; save preflight also protects against automatic edits after a failed load.
nonisolated final class UserSettingsFile<Value: Codable & Sendable>: @unchecked Sendable {
  private let url: URL
  private let legacyURLs: [URL]
  private let loadData: @Sendable (URL) throws -> Data
  private let saveData: @Sendable (Data, URL) throws -> Void
  private let createData: (@Sendable (Data, URL, URL?) throws -> Void)?
  private let lock = NSLock()
  private var loadFailure: (any Error)?

  init(
    url: URL,
    legacyURLs: [URL],
    loadData: @escaping @Sendable (URL) throws -> Data,
    saveData: @escaping @Sendable (Data, URL) throws -> Void,
    createData: (@Sendable (Data, URL, URL?) throws -> Void)?
  ) {
    self.url = url
    self.legacyURLs = legacyURLs
    self.loadData = loadData
    self.saveData = saveData
    self.createData = createData
  }

  func load(initialValue: Value) throws -> Value {
    try lock.withLock {
      do {
        let value = try readValue(initialValue: initialValue)
        loadFailure = nil
        return value
      } catch {
        loadFailure = error
        throw error
      }
    }
  }

  func save(_ value: Value) throws {
    try lock.withLock {
      // A transient load failure can clear before automatic seeding saves.
      // Only an explicit successful load can replace the in-memory defaults.
      if let loadFailure { throw loadFailure }
      _ = try readValue(initialValue: value)
      try saveData(encode(value), url)
    }
  }

  private func readValue(initialValue: Value) throws -> Value {
    for candidate in [url] + legacyURLs {
      guard let data = try read(candidate) else { continue }
      let value = try JSONDecoder().decode(Value.self, from: data)
      if candidate != url {
        try create(data, source: candidate)
      }
      return value
    }
    try create(encode(initialValue), source: nil)
    return initialValue
  }

  private func read(_ candidate: URL) throws -> Data? {
    do {
      return try loadData(candidate)
    } catch SettingsFileStorageError.missing {
      return nil
    } catch RepositoryLocalSettingsStorageError.missing {
      return nil
    } catch {
      let cocoaError = error as NSError
      guard cocoaError.domain == NSCocoaErrorDomain,
        cocoaError.code == NSFileReadNoSuchFileError || cocoaError.code == NSFileNoSuchFileError
      else { throw error }
      // Data(contentsOf:) reports ENOENT for dangling links too. lstat checks
      // the directory entry itself rather than following its target.
      var info = stat()
      guard lstat(candidate.path(percentEncoded: false), &info) != 0, errno == ENOENT else {
        throw error
      }
      return nil
    }
  }

  private func create(_ data: Data, source: URL?) throws {
    if let createData {
      try createData(data, url, source)
    } else {
      // In-memory test stores have no links and serialize their own mutations.
      try saveData(data, url)
    }
  }

  private func encode(_ value: Value) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(value)
  }
}
