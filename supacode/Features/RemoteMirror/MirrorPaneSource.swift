import Foundation

@MainActor
protocol MirrorPaneSource {
  func panes() -> [MirrorPaneDescriptor]
  func snapshot(_ id: UUID) throws -> MirrorFrame
  func write(_ bytes: Data, to id: UUID) throws
  func retainedText(_ id: UUID) throws -> String
  func activeText(_ id: UUID) throws -> String
  var supportsSubmission: Bool { get }
  func submissionState(_ id: UUID) -> MirrorAgentState
  // Revalidate the exact Agent and observation before delivery. Once delivery
  // starts, keep canSubmit false until new runtime evidence permits another turn.
  func submit(_ text: String, to id: UUID, expected: MirrorAgentState) async -> MirrorSubmitOutcome
  func submit(
    _ text: String, to id: UUID, expected: MirrorAgentState,
    canContinue: @escaping @MainActor () -> Bool
  ) async -> MirrorSubmitOutcome
  var supportsBoundedHistory: Bool { get }
  func boundedRetainedText(_ id: UUID) throws -> MirrorRetainedText
}

extension MirrorPaneSource {
  var supportsSubmission: Bool { false }
  func submissionState(_ id: UUID) -> MirrorAgentState {
    .init(
      generation: nil, revision: 0, canSubmit: false, reason: "This Agent does not support message submission.",
      observedAt: 0)
  }
  func submit(_ text: String, to id: UUID, expected: MirrorAgentState) -> MirrorSubmitOutcome {
    .init(status: .rejected, detail: "Submission is unavailable.")
  }
  func submit(
    _ text: String, to id: UUID, expected: MirrorAgentState,
    canContinue: @escaping @MainActor () -> Bool
  ) async -> MirrorSubmitOutcome {
    guard canContinue() else { return .init(status: .rejected, detail: "The pane ownership changed.") }
    return await submit(text, to: id, expected: expected)
  }
  var supportsBoundedHistory: Bool { false }
  func boundedRetainedText(_ id: UUID) throws -> MirrorRetainedText { throw MirrorProtocolError.invalidMessage }
  func activeText(_ id: UUID) throws -> String { throw MirrorProtocolError.invalidMessage }
}
