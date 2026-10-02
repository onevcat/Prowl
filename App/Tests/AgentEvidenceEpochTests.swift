import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

@MainActor
struct AgentEvidenceEpochTests {
  @Test func dispatchEpochAttachesFirstProcessButRejectsReplacementProcess() {
    let store = AgentObservationStore(bufferCapacity: 8)
    let surfaceID = UUID()
    let first = AgentProcessGeneration(pid: 42, startedAt: Date(timeIntervalSince1970: 1))
    let replacement = AgentProcessGeneration(pid: 43, startedAt: Date(timeIntervalSince1970: 2))
    let dispatchEpoch = store.beginDispatchEpoch(surfaceID: surfaceID)

    store.updateEvidenceEpoch(surfaceID: surfaceID, processGeneration: first, sessionID: nil)
    #expect(store.currentEvidenceEpoch(surfaceID: surfaceID) == dispatchEpoch)

    store.updateEvidenceEpoch(surfaceID: surfaceID, processGeneration: replacement, sessionID: nil)
    #expect(store.currentEvidenceEpoch(surfaceID: surfaceID) != dispatchEpoch)
  }

  @Test func dispatchEpochRejectsFirstGenerationThatStartedAfterAcquisitionWindow() {
    let launchTime = Date(timeIntervalSince1970: 1_000)
    let store = AgentObservationStore(
      bufferCapacity: 8,
      now: { launchTime },
      dispatchGenerationWindow: 10
    )
    let surfaceID = UUID()
    let dispatchEpoch = store.beginDispatchEpoch(surfaceID: surfaceID)
    let unrelatedLaterProcess = AgentProcessGeneration(
      pid: 42,
      startedAt: launchTime.addingTimeInterval(11)
    )

    store.updateEvidenceEpoch(
      surfaceID: surfaceID,
      processGeneration: unrelatedLaterProcess,
      sessionID: nil
    )

    #expect(store.currentEvidenceEpoch(surfaceID: surfaceID) != dispatchEpoch)
  }

  @Test func pidStartTimeAndSessionReplacementInvalidateCurrentChannels() {
    let store = AgentObservationStore(bufferCapacity: 8)
    let surfaceID = UUID()
    let first = AgentProcessGeneration(pid: 42, startedAt: Date(timeIntervalSince1970: 1))
    let reused = AgentProcessGeneration(pid: 42, startedAt: Date(timeIntervalSince1970: 2))
    store.updateEvidenceEpoch(surfaceID: surfaceID, processGeneration: first, sessionID: "A")
    store.publishSignal(signal(.turnEnded, source: .cooperativeCLI), binding: .current, surfaceID: surfaceID)
    store.publishSignal(signal(.needsInput, source: .osc), binding: .current, surfaceID: surfaceID)

    let before = store.signalsPayload(
      surfaceID: surfaceID, formatter: formatter(), includeDiagnosticLast: true)
    #expect(before.channels.map(\.source) == ["cooperative_cli", "osc"])
    #expect(before.lastBinding == .current)

    store.updateEvidenceEpoch(surfaceID: surfaceID, processGeneration: reused, sessionID: "A")
    let afterReuse = store.signalsPayload(
      surfaceID: surfaceID, formatter: formatter(), includeDiagnosticLast: true)
    #expect(afterReuse.channels.isEmpty)
    #expect(afterReuse.lastBinding == .stale)

    store.publishSignal(signal(.turnEnded, source: .cooperativeCLI), binding: .current, surfaceID: surfaceID)
    store.updateEvidenceEpoch(surfaceID: surfaceID, processGeneration: reused, sessionID: "B")
    #expect(
      store.bindingForSignal(
        surfaceID: surfaceID,
        generationMatches: true,
        signalSessionID: nil
      ) == .unbound
    )
    let afterSession = store.signalsPayload(
      surfaceID: surfaceID, formatter: formatter(), includeDiagnosticLast: true)
    #expect(afterSession.channels.isEmpty)
    #expect(afterSession.lastBinding == .stale)
  }

  @Test func workingMetadataChurnDoesNotInvalidateTerminalEvidence() {
    let store = AgentObservationStore(bufferCapacity: 8)
    let surfaceID = UUID()
    let generation = AgentProcessGeneration(pid: 42, startedAt: Date(timeIntervalSince1970: 1))
    store.updateEvidenceEpoch(surfaceID: surfaceID, processGeneration: generation, sessionID: nil)
    store.publishAgentChanged(agentEntry(surfaceID: surfaceID, title: "Working A"))
    let terminal = signal(.turnEnded, source: .cooperativeCLI)
    store.publishSignal(terminal, binding: .current, surfaceID: surfaceID)

    store.publishAgentChanged(agentEntry(surfaceID: surfaceID, title: "Working B"))

    #expect(store.currentSignalEvidence(surfaceID: surfaceID).activeTerminal == terminal)
  }

  @Test func workingRedetectionAfterRemovalInvalidatesTerminalEvidence() {
    let store = AgentObservationStore(bufferCapacity: 8)
    let surfaceID = UUID()
    let generation = AgentProcessGeneration(pid: 42, startedAt: Date(timeIntervalSince1970: 1))
    store.updateEvidenceEpoch(surfaceID: surfaceID, processGeneration: generation, sessionID: nil)
    store.publishAgentChanged(agentEntry(surfaceID: surfaceID, title: "Idle", displayState: .idle))
    let terminal = signal(.turnEnded, source: .cooperativeCLI)
    store.publishSignal(terminal, binding: .current, surfaceID: surfaceID)
    store.publishAgentRemoved(surfaceID: surfaceID)

    let beganWorking = store.publishAgentChanged(
      agentEntry(surfaceID: surfaceID, title: "Working", displayState: .working)
    )

    #expect(beganWorking)
    #expect(store.currentSignalEvidence(surfaceID: surfaceID).activeTerminal == nil)
  }

  @Test func unboundSignalIsDiagnosticAndNeverCreatesObservedCoverage() {
    let store = AgentObservationStore(bufferCapacity: 8)
    let surfaceID = UUID()
    store.publishSignal(signal(.turnEnded, source: .cooperativeCLI), binding: .unbound, surfaceID: surfaceID)

    let payload = store.signalsPayload(
      surfaceID: surfaceID, formatter: formatter(), includeDiagnosticLast: true)
    #expect(payload.channels.isEmpty)
    #expect(payload.last?.event == .turnEnded)
    #expect(payload.lastBinding == .unbound)
  }

  @Test func callerAncestryIncludesProcessGenerationsRatherThanPidAlone() throws {
    let pane = CallerPane(worktreeID: "wt", surfaceID: UUID())
    let dates: [pid_t: Date] = [300: .init(timeIntervalSince1970: 3), 200: .init(timeIntervalSince1970: 2)]
    let resolved = try #require(
      CallerPaneResolver.pane(
        forCallerProcess: 300,
        paneByShellPID: [200: pane],
        parentProcessID: { $0 == 300 ? 200 : nil },
        processStartDate: { dates[$0] }
      ))
    #expect(
      resolved.processAncestry
        == [
          AgentProcessGeneration(pid: 300, startedAt: dates[300]!),
          AgentProcessGeneration(pid: 200, startedAt: dates[200]!),
        ])
  }

  private func agentEntry(
    surfaceID: UUID,
    title: String,
    displayState: AgentDisplayState = .working
  ) -> ActiveAgentEntry {
    ActiveAgentEntry(
      id: surfaceID,
      worktreeID: "wt",
      worktreeName: "main",
      workingDirectory: URL(fileURLWithPath: "/Projects/Prowl"),
      tabID: TerminalTabID(rawValue: UUID()),
      paneTitle: title,
      surfaceID: surfaceID,
      paneIndex: 0,
      iconLookupToken: "pi",
      agent: .pi,
      rawState: displayState == .working ? .working : .idle,
      displayState: displayState,
      lastChangedAt: Date(timeIntervalSince1970: 10)
    )
  }

  private func signal(_ kind: AgentSignal.Kind, source: AgentSignal.Source) -> AgentSignal {
    AgentSignal(
      kind: kind,
      source: source,
      confidence: .exact,
      timestamp: Date(timeIntervalSince1970: 10),
      sessionID: nil,
      detail: nil,
      claimedOrigin: nil
    )
  }

  private func formatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }
}
