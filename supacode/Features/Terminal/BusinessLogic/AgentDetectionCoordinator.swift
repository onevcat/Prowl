import Foundation

/// Serializes optional provider observations into one pure decision per pane.
/// The terminal's existing adaptive loop supplies ticks and remains the only timer.
@MainActor
final class AgentDetectionCoordinator {
  private var machine = AgentStateMachine()
  private var process: AgentProcessGeneration?
  private var agent: DetectedAgent?
  private var logProvider: CodexLogProvider?
  private var revision: UInt64 = 0
  typealias Sample = (AgentProcessGeneration, URL?) async -> [AgentDetectionEvent]
  private let sampleOverride: Sample?
  private let time: () -> TimeInterval
  private var interactionRevision: UInt64 = 0
  private var now: TimeInterval { time() }

  init(sample: Sample? = nil, time: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
    sampleOverride = sample
    self.time = time
  }

  func invalidate() {
    revision &+= 1
    logProvider = nil
    process = nil
    machine = AgentStateMachine()
  }

  func interacted() {
    interactionRevision &+= 1
    machine.receive(.interaction, now: now)
  }

  func observe(
    agent: DetectedAgent,
    process: AgentProcessGeneration?,
    screen: AgentScreenDetection,
    screenContentID: Int? = nil,
    configRoot: URL?
  ) async -> AgentStateDecision? {
    if self.agent != agent || (agent == .codex && self.process != process) {
      invalidate()
      self.agent = agent
      self.process = process
      if agent == .codex, process != nil { logProvider = CodexLogProvider() }
    }
    revision &+= 1
    let expectedRevision = revision
    let inputRevision = interactionRevision
    // Screen capture precedes the file read. A completion can fence this frame;
    // the next poll observes whether the UI has actually changed.
    machine.receive(.screen(screen, contentID: screenContentID), now: now)
    if let logProvider, let process {
      let events: [AgentDetectionEvent]
      if let sampleOverride {
        events = await sampleOverride(process, configRoot)
      } else {
        events = await logProvider.sample(process: process, configRoot: configRoot)
      }
      guard revision == expectedRevision else { return nil }
      for event in events { machine.receive(event, now: now) }
    }
    if inputRevision != interactionRevision { machine.receive(.interaction, now: now) }
    return machine.receive(.tick, now: now)
  }
}
