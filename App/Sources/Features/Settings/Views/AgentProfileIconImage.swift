import SwiftUI

/// The persisted override and its runtime fallback. Keeping this value separate
/// from `TabIconSource` leaves `AgentProfile` free of terminal-view concerns.
struct AgentProfileIconSource: Equatable, Hashable, Sendable {
  let overrideSymbol: String?
  let runtime: AgentProfileRuntime

  init(profile: AgentProfile) {
    overrideSymbol = profile.icon
    runtime = profile.runtime
  }
}

extension AgentProfile {
  var iconSource: AgentProfileIconSource {
    AgentProfileIconSource(profile: self)
  }
}
enum AgentProfileIconResolver {
  static func source(for iconSource: AgentProfileIconSource) -> TabIconSource {
    if let overrideSymbol = iconSource.overrideSymbol?.trimmingCharacters(in: .whitespacesAndNewlines),
      !overrideSymbol.isEmpty
    {
      return TabIconSource(systemSymbol: overrideSymbol)
    }

    return CommandIconMap.iconForFirstToken(iconSource.runtime.iconLookupToken)
      ?? TabIconSource(systemSymbol: "sparkles")
  }
}

struct AgentProfileIconImage: View {
  let source: AgentProfileIconSource
  let pointSize: CGFloat

  var body: some View {
    TabIconImage(
      rawName: AgentProfileIconResolver.source(for: source).storageString,
      pointSize: pointSize
    )
  }
}
