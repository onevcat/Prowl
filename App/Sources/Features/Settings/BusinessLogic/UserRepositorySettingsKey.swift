import Dependencies
import Foundation
import Sharing

nonisolated struct UserRepositorySettingsKeyID: Hashable, Sendable {
  let repositoryID: String
}

nonisolated struct UserRepositorySettingsKey: SharedKey {
  let repositoryID: String
  let rootURL: URL

  init(rootURL: URL) {
    self.rootURL = rootURL.standardizedFileURL
    repositoryID = self.rootURL.path(percentEncoded: false)
  }

  var id: UserRepositorySettingsKeyID {
    UserRepositorySettingsKeyID(repositoryID: repositoryID)
  }

  func load(
    context: LoadContext<UserRepositorySettings>,
    continuation: LoadContinuation<UserRepositorySettings>
  ) {
    @Dependency(\.repositoryLocalSettingsStorage) var repositoryLocalSettingsStorage
    let settingsURL = SupacodePaths.userRepositorySettingsURL(for: rootURL)
    let decoder = JSONDecoder()
    if let localData = try? repositoryLocalSettingsStorage.load(settingsURL) {
      if let settings = try? decoder.decode(UserRepositorySettings.self, from: localData) {
        continuation.resume(returning: settings.normalized())
        return
      }
      let path = settingsURL.path(percentEncoded: false)
      SupaLogger("Settings").warning(
        "Unable to decode user repository settings at \(path); trying legacy settings."
      )
    }

    let legacySettingsURL = SupacodePaths.legacyUserRepositorySettingsURL(for: rootURL)
    if let legacyData = try? repositoryLocalSettingsStorage.load(legacySettingsURL) {
      if let legacySettings = try? decoder.decode(UserRepositorySettings.self, from: legacyData) {
        let normalized = legacySettings.normalized()
        do {
          let encoder = JSONEncoder()
          encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
          let data = try encoder.encode(normalized)
          try repositoryLocalSettingsStorage.save(data, settingsURL)
        } catch {
          let path = settingsURL.path(percentEncoded: false)
          SupaLogger("Settings").warning(
            "Unable to write user repository settings to \(path): \(error.localizedDescription)"
          )
        }
        continuation.resume(returning: normalized)
        return
      }
      let path = legacySettingsURL.path(percentEncoded: false)
      SupaLogger("Settings").warning(
        "Unable to decode legacy user repository settings at \(path); using defaults."
      )
    }

    let defaultSettings = (context.initialValue ?? .default).normalized()
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(defaultSettings)
      try repositoryLocalSettingsStorage.save(data, settingsURL)
    } catch {
      let path = settingsURL.path(percentEncoded: false)
      SupaLogger("Settings").warning(
        "Unable to write user repository settings to \(path): \(error.localizedDescription)"
      )
    }

    continuation.resume(returning: defaultSettings)
  }

  func subscribe(
    context _: LoadContext<UserRepositorySettings>,
    subscriber _: SharedSubscriber<UserRepositorySettings>
  ) -> SharedSubscription {
    SharedSubscription {}
  }

  func save(
    _ value: UserRepositorySettings,
    context _: SaveContext,
    continuation: SaveContinuation
  ) {
    @Dependency(\.repositoryLocalSettingsStorage) var repositoryLocalSettingsStorage
    let settingsURL = SupacodePaths.userRepositorySettingsURL(for: rootURL)
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(value.normalized())
      try repositoryLocalSettingsStorage.save(data, settingsURL)
      continuation.resume()
    } catch {
      continuation.resume(throwing: error)
    }
  }
}

nonisolated extension SharedReaderKey where Self == UserRepositorySettingsKey.Default {
  static func userRepositorySettings(_ rootURL: URL) -> Self {
    Self[UserRepositorySettingsKey(rootURL: rootURL), default: .default]
  }
}
