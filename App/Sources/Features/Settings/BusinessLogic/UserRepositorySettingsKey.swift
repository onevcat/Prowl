import Dependencies
import Foundation
import Sharing

nonisolated struct UserRepositorySettingsKeyID: Hashable, Sendable {
  let repositoryID: String
}

nonisolated struct UserRepositorySettingsKey: SharedKey {
  let repositoryID: String
  let location: RepositoryLocation
  private let file: UserSettingsFile<UserRepositorySettings>

  init(location: RepositoryLocation) {
    @Dependency(\.repositoryLocalSettingsStorage) var storage
    self.location = location.standardized
    repositoryID = self.location.id
    file = UserSettingsFile(
      url: ProwlPaths.userRepositorySettingsURL(for: self.location),
      legacyURLs: ProwlPaths.legacyUserRepositorySettingsURLs(for: self.location),
      loadData: storage.load,
      saveData: storage.save,
      createData: storage.create
    )
  }

  init(rootURL: URL) {
    self.init(location: .local(rootURL))
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
  static func userRepositorySettings(_ location: RepositoryLocation) -> Self {
    Self[UserRepositorySettingsKey(location: location), default: .default]
  }

  /// The user settings of the local repository at `rootURL`.
  static func userRepositorySettings(_ rootURL: URL) -> Self {
    userRepositorySettings(.local(rootURL))
  }
}
