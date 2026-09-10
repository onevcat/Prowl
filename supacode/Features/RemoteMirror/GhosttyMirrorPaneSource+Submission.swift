import CryptoKit
import Darwin
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
    let digest = frame.map { Data(SHA256.hash(data: $0.bytes)) } ?? Data()
    shellSubmissions = shellSubmissions.filter { manager.isSurfaceLive($0.key) }
    if condition.agent == nil, condition.isLive, let terminal = view(id),
      let pid = terminal.bridge.childPID(), let started = ProcessDetection.processStartDate(pid: pid),
      let name = ProcessDetection.processArgv0Name(pid: pid),
      ["sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh"].contains(name)
    {
      var shell = shellSubmissions[id] ?? MirrorShellSubmission(pid: pid, started: started)
      shell.observe(pid: pid, started: started, digest: digest)
      shellSubmissions[id] = shell
    } else {
      shellSubmissions.removeValue(forKey: id)
    }
    let shell = shellSubmissions[id]
    let refusal: String?
    if let shell, let terminal = view(id) {
      if terminal.bridge.foregroundProcessGroupID() != getpgid(shell.pid) {
        refusal = "Waiting for the foreground command to return to the shell."
      } else if terminal.markedText.length != 0 {
        refusal = "The Host is composing text."
      } else {
        refusal = parsed == nil ? "Waiting for the shell screen." : nil
      }
    } else {
      refusal = submissionRefusal(id, condition: condition, screen: parsed)
    }
    var gate = readiness[id] ?? MirrorSubmissionReadiness()
    let state = gate.observe(
      .init(
        generation: shell?.generation ?? manager.agentEvidenceEpoch(surfaceID: id),
        runtimeRevision: shell?.revision ?? condition.revision, screenDigest: digest,
        lastEditingAt: view(id)?.lastEditingAt, refusal: refusal,
        allowsIdleRecovery: condition.agent?.agent == .claude),
      now: ProcessInfo.processInfo.systemUptime)
    readiness[id] = gate
    return MirrorAgentState(
      generation: state.generation, revision: state.revision, canSubmit: state.canSubmit,
      reason: state.reason, observedAt: Date().timeIntervalSince1970)
  }

  func submit(_ text: String, to id: UUID, expected: MirrorAgentState) async -> MirrorSubmitOutcome {
    await submit(text, to: id, expected: expected, canContinue: { true })
  }

  func submit(
    _ text: String, to id: UUID, expected: MirrorAgentState,
    canContinue: @escaping @MainActor () -> Bool
  ) async -> MirrorSubmitOutcome {
    guard MirrorSubmissionLedger.validText(text) else {
      return .init(status: .rejected, detail: "The message contains unsupported input.")
    }
    let current = submissionState(id)
    let shell = shellSubmissions[id] != nil
    let bracketed = !shell || (try? snapshot(id)).flatMap(MirrorSnapshotEvidence.read)?.bracketedPaste == true
    guard bracketed || !text.contains("\n") else {
      return .init(status: .rejected, detail: "This shell does not support multiline paste. Send one line at a time.")
    }
    guard canContinue(), current.canSubmit, current.generation == expected.generation,
      current.revision == expected.revision,
      var gate = readiness[id], gate.claim(expected)
    else {
      return .init(status: .rejected, detail: "The Agent or its input changed. Refresh before sending.")
    }
    readiness[id] = gate
    // Validate before pasting, and again before Claude's delayed Enter.
    do {
      let isClaude = manager.agentObservationSnapshot(surfaceID: id)?.agent?.agent == .claude
      if isClaude {
        guard let foreground = view(id)?.bridge.foregroundProcessGroupID(),
          let processStarted = ProcessDetection.processStartDate(pid: foreground)
        else { return .init(status: .rejected, detail: "The Claude process is no longer available.") }
        // Claude processes bracketed paste asynchronously; Enter in the same
        // read can be consumed before the composer has committed the paste.
        try write(Data(("\u{1B}[200~" + text + "\u{1B}[201~").utf8), to: id)
        let editedAt = view(id)?.lastEditingAt
        try await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled, canContinue(), manager.isSurfaceLive(id),
          manager.agentEvidenceEpoch(surfaceID: id) == expected.generation,
          let terminal = view(id), terminal.lastEditingAt == editedAt,
          terminal.markedText.length == 0,
          terminal.bridge.foregroundProcessGroupID() == foreground,
          ProcessDetection.processStartDate(pid: foreground) == processStarted,
          terminal.sendCLIKeyToken("enter")
        else {
          return .init(
            status: .unknown, detail: "Text was pasted but Enter was not sent. Check the Host before retrying.")
        }
      } else {
        let input = bracketed ? "\u{1B}[200~" + text + "\u{1B}[201~\r" : text + "\r"
        try write(Data(input.utf8), to: id)
      }
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

/// Shells have no Agent event revision. Output changes release the previous input
/// claim; a restarted shell gets a new generation so old requests cannot be reused.
nonisolated struct MirrorShellSubmission {
  var pid: pid_t
  var started: Date
  private(set) var generation = UUID()
  private(set) var revision: UInt64 = 0
  private var digest: Data?

  init(pid: pid_t, started: Date) {
    self.pid = pid
    self.started = started
  }

  mutating func observe(pid: pid_t, started: Date, digest: Data) {
    if self.pid != pid || self.started != started {
      self = MirrorShellSubmission(pid: pid, started: started)
    }
    if self.digest != digest {
      revision &+= 1
      self.digest = digest
    }
  }
}
