import Dependencies
import Foundation
import Sharing

nonisolated struct UserGlobalSettingsKeyID: Hashable, Sendable {
  let url: URL
}

nonisolated enum UserGlobalSettingsURLKey: DependencyKey {
  static var liveValue: URL { ProwlPaths.userGlobalSettingsURL }
  static var previewValue: URL { ProwlPaths.userGlobalSettingsURL }
  static var testValue: URL { ProwlPaths.userGlobalSettingsURL }
}

extension DependencyValues {
  nonisolated var userGlobalSettingsURL: URL {
    get { self[UserGlobalSettingsURLKey.self] }
    set { self[UserGlobalSettingsURLKey.self] = newValue }
  }
}

nonisolated struct UserGlobalSettingsKey: SharedKey {
  let url: URL
  private let file: UserSettingsFile<UserGlobalSettings>

  init(url: URL? = nil) {
    @Dependency(\.userGlobalSettingsURL) var userGlobalSettingsURL
    @Dependency(\.settingsFileStorage) var storage
    let url = url ?? userGlobalSettingsURL
    self.url = url
    file = UserSettingsFile(
      url: url,
      legacyURLs: ProwlPaths.legacyUserGlobalSettingsURLs(for: url),
      loadData: storage.load,
      saveData: storage.save,
      createData: storage.create
    )
  }

  var id: UserGlobalSettingsKeyID { UserGlobalSettingsKeyID(url: url) }

  func load(context: LoadContext<UserGlobalSettings>, continuation: LoadContinuation<UserGlobalSettings>) {
    do {
      let settings = try file.load(initialValue: (context.initialValue ?? .default).normalized())
      continuation.resume(returning: settings.normalized())
    } catch {
      ProwlLogger("Settings").warning("Unable to load user global settings: \(error.localizedDescription)")
      continuation.resume(throwing: error)
    }
  }

  func subscribe(
    context _: LoadContext<UserGlobalSettings>, subscriber _: SharedSubscriber<UserGlobalSettings>
  ) -> SharedSubscription {
    SharedSubscription {}
  }

  func save(_ value: UserGlobalSettings, context _: SaveContext, continuation: SaveContinuation) {
    do {
      try file.save(value.normalized())
      continuation.resume()
    } catch {
      continuation.resume(throwing: error)
    }
  }

}

nonisolated extension SharedReaderKey where Self == UserGlobalSettingsKey.Default {
  static var userGlobalSettings: Self { Self[UserGlobalSettingsKey(), default: .default] }
}
