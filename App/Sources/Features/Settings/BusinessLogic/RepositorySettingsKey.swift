import Dependencies
import Foundation
import Sharing

nonisolated struct RepositorySettingsKeyID: Hashable, Sendable {
  let repositoryID: String
}

nonisolated struct RepositorySettingsKey: SharedKey {
  let repositoryID: String
  let rootURL: URL

  init(rootURL: URL) {
    self.rootURL = rootURL.standardizedFileURL
    repositoryID = self.rootURL.path(percentEncoded: false)
  }

  var id: RepositorySettingsKeyID {
    RepositorySettingsKeyID(repositoryID: repositoryID)
  }

  func load(
    context: LoadContext<RepositorySettings>,
    continuation: LoadContinuation<RepositorySettings>
  ) {
    @Dependency(\.repositoryLocalSettingsStorage) var repositoryLocalSettingsStorage
    let repositorySettingsURL = SupacodePaths.repositorySettingsURL(for: rootURL)
    let decoder = JSONDecoder()
    if let localData = try? repositoryLocalSettingsStorage.load(repositorySettingsURL) {
      if let settings = try? decoder.decode(RepositorySettings.self, from: localData) {
        continuation.resume(returning: settings)
        return
      }
      let path = repositorySettingsURL.path(percentEncoded: false)
      SupaLogger("Settings").warning(
        "Unable to decode repository settings at \(path); trying legacy and global migrations."
      )
    }

    let legacySettingsURL = SupacodePaths.legacyRepositorySettingsURL(for: rootURL)
    if let legacyData = try? repositoryLocalSettingsStorage.load(legacySettingsURL) {
      if let legacySettings = try? decoder.decode(RepositorySettings.self, from: legacyData) {
        do {
          let encoder = JSONEncoder()
          encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
          let data = try encoder.encode(legacySettings)
          try repositoryLocalSettingsStorage.save(data, repositorySettingsURL)
        } catch {
          let path = repositorySettingsURL.path(percentEncoded: false)
          SupaLogger("Settings").warning(
            "Unable to write migrated repository settings to \(path): \(error.localizedDescription)"
          )
        }
        continuation.resume(returning: legacySettings)
        return
      }
      let path = legacySettingsURL.path(percentEncoded: false)
      SupaLogger("Settings").warning(
        "Unable to decode legacy repository settings at \(path); migrating from global settings."
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
    let repositorySettingsURL = SupacodePaths.repositorySettingsURL(for: rootURL)
    if (try? repositoryLocalSettingsStorage.load(repositorySettingsURL)) != nil {
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
  static func repositorySettings(_ rootURL: URL) -> Self {
    Self[RepositorySettingsKey(rootURL: rootURL), default: .default]
  }
}
