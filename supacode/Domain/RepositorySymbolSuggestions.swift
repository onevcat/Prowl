import Foundation

/// Result of a user-invoked "Suggest an Icon" run for one repository:
/// GlyphonKit's best SF Symbol pick, its alternates, and the reasoning
/// line, plus enough provenance for honest labeling in the picker.
nonisolated struct RepositorySymbolSuggestions: Equatable, Sendable {
  /// Which local input produced the suggestion text, disclosed in the
  /// picker (`Based on README`, …). Sources are tried in this order and
  /// never blindly concatenated.
  enum Source: Equatable, Sendable {
    case readme
    case manifestDescription
    case repositoryName

    var disclosureLabel: String {
      switch self {
      case .readme:
        String(localized: "Based on README")
      case .manifestDescription:
        String(localized: "Based on the package description")
      case .repositoryName:
        String(localized: "Based on the repository name")
      }
    }
  }

  var primary: String
  var alternates: [String]
  var reason: String
  var source: Source
  /// `false` marks a retrieval-only fallback (Foundation Models
  /// unavailable or degraded) — the UI must label those as keyword
  /// suggestions, never as model recommendations.
  var usedAI: Bool

  var allSymbols: [String] {
    [primary] + alternates
  }
}
