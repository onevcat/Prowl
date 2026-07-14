import Foundation

enum DetectedAgent: String, CaseIterable, Equatable, Identifiable, Sendable {
  // swiftlint:disable:next identifier_name
  case pi
  case claude
  case codex
  case gemini
  case cursor = "cursor-agent"
  case cline
  case opencode
  case copilot
  case kimi
  case droid
  case amp
  case qwen
  case grok

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .cursor:
      return "cursor"
    default:
      return rawValue
    }
  }

  var iconLookupToken: String {
    switch self {
    case .claude:
      return "claude"
    case .copilot:
      return "copilot"
    case .cursor:
      return "cursor"
    default:
      return rawValue
    }
  }
}
