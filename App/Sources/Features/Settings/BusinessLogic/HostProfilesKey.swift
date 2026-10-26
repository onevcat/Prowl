import Dependencies
import Foundation
import Sharing

/// `~/.prowl/hosts.json`: the SSH host profiles that remote folders refer to by ID
/// (docs-ai 084 D1, D6). The version leaves room for the rebind state of C1.
nonisolated struct HostProfilesFile: Codable, Equatable, Sendable {
  static let currentVersion = 1

  var version: Int
  var hosts: [HostProfile]

  init(hosts: [HostProfile]) {
    version = Self.currentVersion
    self.hosts = hosts
  }
}

nonisolated enum HostProfilesFileURLKey: DependencyKey {
  static var liveValue: URL { ProwlPaths.hostProfilesURL }
  static var previewValue: URL { ProwlPaths.hostProfilesURL }
  static var testValue: URL { ProwlPaths.hostProfilesURL }
}

extension DependencyValues {
  nonisolated var hostProfilesFileURL: URL {
    get { self[HostProfilesFileURLKey.self] }
    set { self[HostProfilesFileURLKey.self] = newValue }
  }
}

nonisolated struct HostProfilesKeyID: Hashable, Sendable {}

nonisolated struct HostProfilesKey: SharedKey {
  var id: HostProfilesKeyID { HostProfilesKeyID() }

  /// A missing file means no hosts. A file this build cannot read (a newer version, damage,
  /// or a read error such as a link into an unmounted volume) also loads as no hosts, but it
  /// is never written over: the remote folders that refer to it then show as unavailable
  /// instead of losing their host for good.
  func load(context _: LoadContext<[HostProfile]>, continuation: LoadContinuation<[HostProfile]>) {
    @Dependency(\.settingsFileStorage) var storage
    @Dependency(\.hostProfilesFileURL) var url
    let stored = Self.storedFile(storage: storage, url: url)
    Self.loadedStates.set(stored, for: url)
    switch stored {
    case .missing:
      continuation.resume(returning: [])
    case .readable(let file):
      continuation.resume(returning: file.hosts)
    case .unreadable:
      ProwlLogger("Hosts").warning("Unable to read \(url.lastPathComponent); remote folders stay unavailable")
      continuation.resume(returning: [])
    }
  }

  func subscribe(
    context _: LoadContext<[HostProfile]>, subscriber _: SharedSubscriber<[HostProfile]>
  ) -> SharedSubscription {
    SharedSubscription {}
  }

  /// Writes only over the file the shared value was loaded from (compare and swap). It
  /// refuses a file it cannot read, and a file that changed since the last load: a file
  /// that became readable again after a failed load, a link target that appeared, or an
  /// edit from another Prowl. Otherwise an edit of the empty fallback list would erase the
  /// hosts that the file holds. The caller reloads (`$hostProfiles.load()`) and edits again.
  /// The shared value keeps a refused change in memory, so a caller that must not proceed
  /// without a saved host (C1's Add Remote Folder) checks the save error first.
  func save(_ value: [HostProfile], context _: SaveContext, continuation: SaveContinuation) {
    @Dependency(\.settingsFileStorage) var storage
    @Dependency(\.hostProfilesFileURL) var url
    let current = Self.storedFile(storage: storage, url: url)
    if case .unreadable = current {
      continuation.resume(throwing: HostProfilesFileError.unreadableFile)
      return
    }
    guard Self.loadedStates.state(for: url) == current else {
      continuation.resume(throwing: HostProfilesFileError.changedSinceLoad)
      return
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
      let file = HostProfilesFile(hosts: value)
      try storage.save(try encoder.encode(file), url)
      Self.loadedStates.set(.readable(file), for: url)
      continuation.resume()
    } catch {
      continuation.resume(throwing: error)
    }
  }

  /// What each hosts file held when it was last loaded or saved by this process.
  private static let loadedStates = LoadedStates()

  private final class LoadedStates: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [URL: StoredFile] = [:]

    func state(for url: URL) -> StoredFile? { lock.withLock { states[url] } }
    func set(_ state: StoredFile, for url: URL) { lock.withLock { states[url] = state } }
  }

  enum StoredFile: Equatable {
    case missing
    case readable(HostProfilesFile)
    /// Present, but this build cannot read it.
    case unreadable
  }

  /// Only a file that does not exist counts as missing; every other read error makes the
  /// file unreadable.
  static func storedFile(storage: SettingsFileStorage, url: URL) -> StoredFile {
    let data: Data
    do {
      data = try storage.load(url)
    } catch {
      return isMissingFile(error) ? .missing : .unreadable
    }
    guard let file = try? JSONDecoder().decode(HostProfilesFile.self, from: data),
      file.version <= HostProfilesFile.currentVersion
    else { return .unreadable }
    return .readable(file)
  }

  private static func isMissingFile(_ error: Error) -> Bool {
    if case SettingsFileStorageError.missing? = error as? SettingsFileStorageError { return true }
    if let error = error as? CocoaError, error.code == .fileReadNoSuchFile { return true }
    let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
    return (error as NSError).domain == NSPOSIXErrorDomain && (error as NSError).code == Int(ENOENT)
      || underlying?.domain == NSPOSIXErrorDomain && underlying?.code == Int(ENOENT)
  }
}

nonisolated enum HostProfilesFileError: Error, Equatable, LocalizedError {
  /// `hosts.json` exists but this build cannot read it, so it is not overwritten.
  case unreadableFile
  /// `hosts.json` is not what the shared value was loaded from; reload before editing.
  case changedSinceLoad

  var errorDescription: String? {
    switch self {
    case .unreadableFile:
      String(localized: "This version of Prowl cannot read ~/.prowl/hosts.json, so it does not change it.")
    case .changedSinceLoad:
      String(localized: "~/.prowl/hosts.json changed while Prowl saved it. Try again.")
    }
  }
}

nonisolated extension SharedReaderKey where Self == HostProfilesKey.Default {
  static var hostProfiles: Self {
    Self[HostProfilesKey(), default: []]
  }
}
