/// Selection state for a profile field that offers suggestions without
/// discarding a user-provided literal value.
nonisolated enum AgentProfileSuggestionSelection: Hashable, Sendable {
  case runtimeDefault
  case suggestion(String)
  case custom(String)

  init(value: String?, suggestions: [String]) {
    guard let value else {
      self = .runtimeDefault
      return
    }
    self = suggestions.contains(value) ? .suggestion(value) : .custom(value)
  }

  var value: String? {
    switch self {
    case .runtimeDefault:
      return nil
    case .suggestion(let value), .custom(let value):
      return value
    }
  }
}
