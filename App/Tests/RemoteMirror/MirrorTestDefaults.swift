import Foundation

extension UserDefaults {
  /// The endpoint store for Mirror Host tests. `MirrorHost` saves each valid address and port
  /// edit, so a test that used `.standard` would change the Debug app's own listener settings.
  @MainActor static let mirrorTests: UserDefaults = {
    let name = "ProwlTests.RemoteMirror"
    // The suite name is a constant; the initializer fails only for the global domain.
    let defaults = UserDefaults(suiteName: name) ?? .standard
    defaults.removePersistentDomain(forName: name)
    return defaults
  }()
}
