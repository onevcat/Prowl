import Dependencies
import Foundation
import Sharing

nonisolated struct RepositorySettingsKeyID: Hashable, Sendable {
  let repositoryID: String
}

nonisolated struct RepositorySettingsKey: SharedKey {
  let repositoryID: String
  let location: RepositoryLocation

  init(location: RepositoryLocation) {
    self.location = location.standardized
    repositoryID = self.location.id
  }

  init(rootURL: URL) {
    self.init(location: .local(rootURL))
  }

  var id: RepositorySettingsKeyID {
    RepositorySettingsKeyID(repositoryID: repositoryID)
  }

  func load(
    context: LoadContext<RepositorySettings>,
    continuation: LoadContinuation<RepositorySettings>
  ) {
    @Dependency(\.repositoryLocalSettingsStorage) var repositoryLocalSettingsStorage
    let repositorySettingsURL = ProwlPaths.repositorySettingsURL(for: location)
    let decoder = JSONDecoder()
    let localData = try? repositoryLocalSettingsStorage.load(repositorySettingsURL)
    if let localData {
      if let settings = try? decoder.decode(RepositorySettings.self, from: localData) {
        continuation.resume(returning: settings)
        return
      }
      let path = repositorySettingsURL.path(percentEncoded: false)
      ProwlLogger("Settings").warning(
        "Unable to decode repository settings at \(path); trying legacy and global migrations."
      )
    }

    for legacySettingsURL in ProwlPaths.legacyRepositorySettingsURLs(for: location) {
      guard let legacyData = try? repositoryLocalSettingsStorage.load(legacySettingsURL) else { continue }
      if let legacySettings = try? decoder.decode(RepositorySettings.self, from: legacyData) {
        do {
          let encoder = JSONEncoder()
          encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
          let data = try encoder.encode(legacySettings)
          // A missing file is created as a copy that keeps a symlink to the
          // user's dotfiles. When that fails, or an unreadable file is in the
          // way, a plain write still keeps later saves out of the global file,
          // which this chain reads last.
          let created =
            localData == nil
            && (try? repositoryLocalSettingsStorage.create?(data, repositorySettingsURL, legacySettingsURL)) != nil
          if !created {
            try repositoryLocalSettingsStorage.save(data, repositorySettingsURL)
          }
        } catch {
          let path = repositorySettingsURL.path(percentEncoded: false)
          ProwlLogger("Settings").warning(
            "Unable to write migrated repository settings to \(path): \(error.localizedDescription)"
          )
        }
        continuation.resume(returning: legacySettings)
        return
      }
      let path = legacySettingsURL.path(percentEncoded: false)
      ProwlLogger("Settings").warning(
        "Unable to decode legacy repository settings at \(path); trying the next source."
      )
    }

    @Shared(.settingsFile) var settingsFile: SettingsFile
    let settings = $settingsFile.withLock { settings in
      if let existing = settings.repositories[repositoryID] {
        return existing
      }
      let defaults = context.initialValue ?? .default
      settings.repositories[repositoryID] = defaults
      return defaults
    }
    continuation.resume(returning: settings)
  }

  func subscribe(
    context _: LoadContext<RepositorySettings>,
    subscriber _: SharedSubscriber<RepositorySettings>
  ) -> SharedSubscription {
    SharedSubscription {}
  }

  func save(
    _ value: RepositorySettings,
    context _: SaveContext,
    continuation: SaveContinuation
  ) {
    @Dependency(\.repositoryLocalSettingsStorage) var repositoryLocalSettingsStorage
    let repositorySettingsURL = ProwlPaths.repositorySettingsURL(for: location)
    // A legacy source also selects the repository file: load reads it before the
    // global file, so an edit stored globally would be lost on the next load
    // (for example, after the first copy failed).
    let usesRepositoryFile = ([repositorySettingsURL] + ProwlPaths.legacyRepositorySettingsURLs(for: location))
      .contains { (try? repositoryLocalSettingsStorage.load($0)) != nil }
    if usesRepositoryFile {
      do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try repositoryLocalSettingsStorage.save(data, repositorySettingsURL)
        continuation.resume()
      } catch {
        continuation.resume(throwing: error)
      }
      return
    }

    @Shared(.settingsFile) var settingsFile: SettingsFile
    $settingsFile.withLock {
      $0.repositories[repositoryID] = value
    }
    continuation.resume()
  }
}

nonisolated extension SharedReaderKey where Self == RepositorySettingsKey.Default {
  static func repositorySettings(_ location: RepositoryLocation) -> Self {
    Self[RepositorySettingsKey(location: location), default: .default]
  }

  /// The settings of the local repository at `rootURL`.
  static func repositorySettings(_ rootURL: URL) -> Self {
    repositorySettings(.local(rootURL))
  }
}
