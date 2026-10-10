import Dependencies
import Foundation
import Sharing

nonisolated struct UserRepositorySettingsKeyID: Hashable, Sendable {
  let repositoryID: String
}

nonisolated struct UserRepositorySettingsKey: SharedKey {
  let repositoryID: String
  let rootURL: URL
  private let file: UserSettingsFile<UserRepositorySettings>

  init(rootURL: URL) {
    @Dependency(\.repositoryLocalSettingsStorage) var storage
    let rootURL = rootURL.standardizedFileURL
    self.rootURL = rootURL
    repositoryID = rootURL.path(percentEncoded: false)
    file = UserSettingsFile(
      url: ProwlPaths.userRepositorySettingsURL(for: rootURL),
      legacyURLs: ProwlPaths.legacyUserRepositorySettingsURLs(for: rootURL),
      loadData: storage.load,
      saveData: storage.save,
      createData: storage.create
    )
  }

  var id: UserRepositorySettingsKeyID {
    UserRepositorySettingsKeyID(repositoryID: repositoryID)
  }

  func load(
    context: LoadContext<UserRepositorySettings>,
    continuation: LoadContinuation<UserRepositorySettings>
  ) {
    do {
      let settings = try file.load(initialValue: (context.initialValue ?? .default).normalized())
      continuation.resume(returning: settings.normalized())
    } catch {
      ProwlLogger("Settings").warning("Unable to load user repository settings: \(error.localizedDescription)")
      continuation.resume(throwing: error)
    }
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
    do {
      try file.save(value.normalized())
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
