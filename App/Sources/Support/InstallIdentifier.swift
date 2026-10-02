import Foundation

/// A per-install UUID persisted in UserDefaults. Regenerates after reset or
/// on a fresh install — does not leak a stable hardware identifier.
nonisolated enum InstallIdentifier {
  private static let userDefaultsKey = "com.onevcat.prowl.installIdentifier"

  static var current: String {
    let defaults = UserDefaults.standard
    if let existing = defaults.string(forKey: userDefaultsKey), !existing.isEmpty {
      return existing
    }
    let generated = UUID().uuidString
    defaults.set(generated, forKey: userDefaultsKey)
    return generated
  }

  static func reset() {
    UserDefaults.standard.removeObject(forKey: userDefaultsKey)
  }
}
