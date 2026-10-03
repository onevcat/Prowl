struct AgentScreenSnapshot: Equatable, Sendable {
  let text: String
  let lines: [String]

  /// `text` must be the exact detector input for the agent consuming this
  /// snapshot. Production call sites go through
  /// `DetectedAgent.detectionSnapshot(from:)` so state detection and blocker
  /// extraction always read the same slice; constructing one directly is for
  /// tests feeding already-sliced synthetic screens.
  nonisolated init(text: String) {
    self.text = text
    self.lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
  }
}
