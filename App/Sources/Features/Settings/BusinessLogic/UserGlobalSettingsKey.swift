import Dependencies
import Foundation
import Sharing

nonisolated struct UserGlobalSettingsKeyID: Hashable, Sendable {
  let url: URL
}

nonisolated enum UserGlobalSettingsURLKey: DependencyKey {
  static var liveValue: URL { SupacodePaths.userGlobalSettingsURL }
  static var previewValue: URL { SupacodePaths.userGlobalSettingsURL }
  static var testValue: URL { SupacodePaths.userGlobalSettingsURL }
}

extension DependencyValues {
  nonisolated var userGlobalSettingsURL: URL {
    get { self[UserGlobalSettingsURLKey.self] }
    set { self[UserGlobalSettingsURLKey.self] = newValue }
  }
}

nonisolated struct UserGlobalSettingsKey: SharedKey {
  let url: URL

  init(url: URL? = nil) {
    if let url {
      self.url = url
      return
    }
    @Dependency(\.userGlobalSettingsURL) var userGlobalSettingsURL
    self.url = userGlobalSettingsURL
  }

  var id: UserGlobalSettingsKeyID { UserGlobalSettingsKeyID(url: url) }

  func load(context: LoadContext<UserGlobalSettings>, continuation: LoadContinuation<UserGlobalSettings>) {
    @Dependency(\.settingsFileStorage) var storage
    let decoder = JSONDecoder()
    if let data = try? storage.load(url), let settings = try? decoder.decode(UserGlobalSettings.self, from: data) {
      continuation.resume(returning: settings.normalized())
      return
    }
    let settings = (context.initialValue ?? .default).normalized()
    do {
      try storage.save(try Self.encoder.encode(settings), url)
    } catch {
      SupaLogger("Settings").warning("Unable to write user global settings: \(error.localizedDescription)")
    }
    continuation.resume(returning: settings)
  }

  func subscribe(
    context _: LoadContext<UserGlobalSettings>, subscriber _: SharedSubscriber<UserGlobalSettings>
  ) -> SharedSubscription {
    SharedSubscription {}
  }

  func save(_ value: UserGlobalSettings, context _: SaveContext, continuation: SaveContinuation) {
    @Dependency(\.settingsFileStorage) var storage
    do {
      try storage.save(try Self.encoder.encode(value.normalized()), url)
      continuation.resume()
    } catch {
      continuation.resume(throwing: error)
    }
  }

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }
}

nonisolated extension SharedReaderKey where Self == UserGlobalSettingsKey.Default {
  static var userGlobalSettings: Self { Self[UserGlobalSettingsKey(), default: .default] }
}
