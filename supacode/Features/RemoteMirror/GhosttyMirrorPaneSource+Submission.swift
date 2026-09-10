import CryptoKit
import Foundation
import ProwlCLIShared

extension GhosttyMirrorPaneSource {
  var supportsSubmission: Bool { true }

  func submissionState(_ id: UUID) -> MirrorAgentState {
    readiness = readiness.filter { manager.isSurfaceLive($0.key) }
    let signals = manager.agentSignalsPayload(surfaceID: id)
    let observation = manager.agentObservationSnapshot(surfaceID: id)
    let evidence = manager.currentAgentSignalEvidence(surfaceID: id)
    let condition = AgentConditionSnapshot(
      agent: observation?.agent, signal: evidence.activeTerminal, changedSignal: evidence.latest,
      revision: observation?.revision ?? 0, isLive: manager.isSurfaceLive(id), signals: signals)
    let frame = try? snapshot(id)
    let parsed = frame.flatMap(MirrorSnapshotEvidence.read)
    let refusal = submissionRefusal(id, condition: condition, screen: parsed)
    var gate = readiness[id] ?? MirrorSubmissionReadiness()
    let state = gate.observe(
      .init(
        generation: manager.agentEvidenceEpoch(surfaceID: id), runtimeRevision: condition.revision,
        screenDigest: frame.map { Data(SHA256.hash(data: $0.bytes)) } ?? Data(),
        lastEditingAt: view(id)?.lastEditingAt, refusal: refusal),
      now: ProcessInfo.processInfo.systemUptime)
    readiness[id] = gate
    return MirrorAgentState(
      generation: state.generation, revision: state.revision, canSubmit: state.canSubmit,
      reason: state.reason, observedAt: Date().timeIntervalSince1970)
  }

  func submit(_ text: String, to id: UUID, expected: MirrorAgentState) -> MirrorSubmitOutcome {
    guard MirrorSubmissionLedger.validText(text) else {
      return .init(status: .rejected, detail: "The message contains unsupported input.")
    }
    let current = submissionState(id)
    guard current.canSubmit, current.generation == expected.generation, current.revision == expected.revision,
      var gate = readiness[id], gate.claim(expected)
    else {
      return .init(status: .rejected, detail: "The Agent or its input changed. Refresh before sending.")
    }
    readiness[id] = gate
    // One length-delimited write keeps multiline paste and Return ordered. No
    // suspension occurs between the last observation and this PTY enqueue.
    do {
      try write(Data(("\u{1B}[200~" + text + "\u{1B}[201~\r").utf8), to: id)
      return .init(status: .accepted, detail: "Message queued to the Host terminal.")
    } catch {
      return .init(status: .unknown, detail: "Terminal delivery could not be confirmed. Check the Host output.")
    }
  }

  private func submissionRefusal(
    _ id: UUID, condition: AgentConditionSnapshot, screen: MirrorSnapshotEvidence?
  ) -> String? {
    guard condition.isLive, let terminal = view(id), let agent = condition.agent else {
      return "Waiting for an identified Agent process."
    }
    guard agent.agent == .codex || agent.agent == .claude else {
      return "Message submission for this Agent is not available yet."
    }
    guard
      let pane = manager.activeWorktreeStates.lazy.compactMap({ $0.surfaceAgentStates[id] }).first,
      let pid = pane.launchProcessID ?? pane.agentProcessID,
      ProcessDetection.processStartDate(pid: pid) != nil
    else { return "The Agent process is no longer available." }
    guard terminal.markedText.length == 0 else { return "The Host is composing text." }
    return Self.inputRefusal(condition: condition, screen: screen)
  }

  static func inputRefusal(condition: AgentConditionSnapshot, screen: MirrorSnapshotEvidence?) -> String? {
    guard condition.isLive, let agent = condition.agent,
      agent.agent == .codex || agent.agent == .claude
    else { return "Waiting for a supported Agent process." }
    let text = screen?.lines.map { $0.map(\.text).joined() }.joined(separator: "\n") ?? ""
    guard !text.contains("[Image #") else {
      return "Check the Host for attached images before sending."
    }
    guard !text.contains("Starting MCP servers"), !text.contains("Shutting down...") else {
      return "The Agent is starting or stopping."
    }
    // Either source can enable input. Runtime idle intentionally does not prove
    // the Host draft is empty; remote text may append to a local draft.
    if AgentConditionEvidence.detectorReports(
      .idle, normalizedState: AgentConditionEvidence.normalizedState(condition))
    {
      return nil
    }
    guard let screen, screen.bracketedPaste,
      agent.agent == .codex ? screen.codexPlaceholder != nil : screen.hasEmptyClaudeComposer
    else {
      return "Waiting for Prowl idle or an empty Agent composer."
    }
    let snapshot = AgentScreenSnapshot(text: text)
    let detectedState =
      agent.agent == .codex
      ? CodexScreenProfile.detect(in: snapshot).state
      : ClaudeScreenProfile.detect(in: snapshot).state
    return detectedState == .idle ? nil : "The Agent is working or needs attention."
  }
}
