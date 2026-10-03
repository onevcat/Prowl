import Foundation

/// User-pinned visual identity for a single repository: an optional
/// icon source and an optional color choice, both freely combinable.
/// Both fields are independently optional so a user can color-tag a
/// repo without picking an icon (and vice versa).
///
/// Persisted as part of a global `[Repository.ID: RepositoryAppearance]`
/// dictionary — not nested in `Repository` or `RepositorySettings` —
/// because the sidebar / shelf / canvas all need O(1) cross-repo
/// lookups during render and a single `@Shared` dict is the lightest
/// way to give every renderer the same view.
nonisolated struct RepositoryAppearance: Equatable, Hashable, Sendable {
  var icon: RepositoryIconSource?
  var color: RepositoryColorChoice?
  /// Set when the user explicitly clears the icon. A suppressed
  /// repository never accepts an automatic detection result — this is
  /// what stops an in-flight detector from resurrecting an icon the
  /// user just removed. Removing the repository resets the flag so a
  /// future re-add starts fresh.
  var iconDetectionSuppressed: Bool

  static let empty = RepositoryAppearance(icon: nil, color: nil)

  init(
    icon: RepositoryIconSource? = nil,
    color: RepositoryColorChoice? = nil,
    iconDetectionSuppressed: Bool = false
  ) {
    self.icon = icon
    self.color = color
    self.iconDetectionSuppressed = iconDetectionSuppressed
  }

  var isEmpty: Bool {
    icon == nil && color == nil && !iconDetectionSuppressed
  }
}

extension RepositoryAppearance: Codable {
  private enum CodingKeys: String, CodingKey {
    case icon
    case color
    case iconDetectionSuppressed
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    icon = try container.decodeIfPresent(RepositoryIconSource.self, forKey: .icon)
    color = try container.decodeIfPresent(RepositoryColorChoice.self, forKey: .color)
    iconDetectionSuppressed =
      try container.decodeIfPresent(Bool.self, forKey: .iconDetectionSuppressed) ?? false
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(icon, forKey: .icon)
    try container.encodeIfPresent(color, forKey: .color)
    // Omit the default so pre-existing files stay byte-identical until
    // a repo actually uses suppression.
    if iconDetectionSuppressed {
      try container.encode(iconDetectionSuppressed, forKey: .iconDetectionSuppressed)
    }
  }
}
