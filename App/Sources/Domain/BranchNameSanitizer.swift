import Foundation

nonisolated enum BranchNameSanitizer {
  static let maxLength = 50

  static func sanitize(_ raw: String) -> String? {
    var name =
      raw
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()

    // Multi-line output is garbage
    if name.contains(where: { $0.isNewline }) {
      name = name.components(separatedBy: .newlines).first ?? ""
    }

    name =
      name
      .replacing(/\s+/, with: "-")
      .replacing("_", with: "-")
      .replacing(/[~^:?*\[\]\\@{}\x00-\x1f\x7f]/, with: "")
      .replacing("..", with: ".")
      .replacing(/-{2,}/, with: "-")
      .replacing(/\.{2,}/, with: ".")

    while name.hasPrefix("-") || name.hasPrefix(".") { name.removeFirst() }
    while name.hasSuffix("-") || name.hasSuffix(".") || name.hasSuffix(".lock") {
      if name.hasSuffix(".lock") {
        name = String(name.dropLast(5))
      } else {
        name.removeLast()
      }
    }

    if name.count > maxLength {
      name = String(name.prefix(maxLength))
      while name.hasSuffix("-") || name.hasSuffix(".") { name.removeLast() }
    }

    guard name.count >= 3 else { return nil }
    return name
  }

  static func detectConventionPrefix(from branches: [String]) -> String? {
    let knownPrefixes = [
      "feature/", "fix/", "bugfix/", "hotfix/", "chore/",
      "refactor/", "docs/", "test/", "ci/",
    ]
    let found = branches.compactMap { branch -> String? in
      guard let slashIndex = branch.firstIndex(of: "/") else { return nil }
      let prefix = String(branch[...slashIndex])
      return knownPrefixes.contains(prefix) ? prefix : nil
    }
    guard !found.isEmpty else { return nil }
    let counts = Dictionary(grouping: found, by: { $0 }).mapValues(\.count)
    return counts.max(by: { $0.value < $1.value })?.key
  }

  static func ensurePrefix(_ name: String, conventionPrefix: String?) -> String {
    if name.contains("/") { return name }
    let prefix = conventionPrefix ?? "worktree/"
    return prefix + name
  }

  static func validate(
    _ name: String,
    existingBranches: [String]
  ) -> String? {
    guard var sanitized = sanitize(name) else { return nil }
    sanitized = ensurePrefix(sanitized, conventionPrefix: detectConventionPrefix(from: existingBranches))

    // Re-check length after prefix
    if sanitized.count > maxLength {
      return nil
    }

    // Reject duplicates (case-insensitive)
    let lowered = sanitized.lowercased()
    if existingBranches.contains(where: { $0.lowercased() == lowered }) {
      return nil
    }

    return sanitized
  }
}
