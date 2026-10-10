import Foundation

/// Serializes optional provider observations into one pure decision per pane.
/// The terminal's existing adaptive loop supplies ticks and remains the only timer.
@MainActor
final class AgentDetectionCoordinator {
  /// What a pushed OSC 7501 report did (docs-ai 079).
  enum ProgramStatusPush: Equatable {
    /// A verified producer's eligible root changed the decision: publish it now.
    case decision(AgentStateDecision)
    /// The evidence was withdrawn; the machine re-resolved, but publication waits for
    /// an observe that starts after `lastProgramStatusWithdrawalAt`.
    case withdrawn
    /// Nothing to publish: no binding, an unverified producer, or no eligible root.
    case none
  }

  private var machine = AgentStateMachine()
  private var process: AgentProcessGeneration?
  private var agent: DetectedAgent?
  private var logProvider: CodexLogProvider?
  private var nativeProvider: ClaudeRuntimeProvider?
  private var configRoot: URL?
  private var revision: UInt64 = 0
  private var lastCapturedAt: TimeInterval?
  private var observationInFlight = false
  private var observationWaiters: [CheckedContinuation<Void, Never>] = []
  typealias Sample = (AgentProcessGeneration, URL?) async -> [AgentDetectionEvent]
  private let sampleOverride: Sample?
  private let time: () -> TimeInterval
  private var interactionRevision: UInt64 = 0
  private var now: TimeInterval { time() }

  private let surfaceID: UUID?
  private let support: (DetectedAgent) -> ProgramStatusSupport
  private let log: (String) -> Void
  /// The latest record store snapshot the owner handed over; re-derived against the
  /// bound process generation whenever the binding changes.
  private var programStatusStore = ProgramStatusRecordStore()
  /// Bumped when OSC evidence takes authority. A provider sample that was already in
  /// flight at that moment is discarded when it lands: applying it would recreate the
  /// native snapshot and completed-frame fence the transition just retired.
  private var authorityEpoch: UInt64 = 0
  private var shadowLogged: [String: TimeInterval] = [:]
  private var lastShadowKey: String?
  private static let shadowThrottle: TimeInterval = 30
  /// Monotonic time of the latest OSC withdrawal, so the owner can withhold the
  /// publication of an observe whose capture predates it.
  private(set) var lastProgramStatusWithdrawalAt: TimeInterval?

  init(
    surfaceID: UUID? = nil,
    sample: Sample? = nil,
    time: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    support: @escaping (DetectedAgent) -> ProgramStatusSupport = ProgramStatusSupport.level(for:),
    log: @escaping (String) -> Void = { ProwlLogger("AgentDetection").debug($0) }
  ) {
    self.surfaceID = surfaceID
    sampleOverride = sample
    self.time = time
    self.support = support
    self.log = log
  }

  /// The machine's latest resolution; `nil` until an agent is bound. Readiness reads
  /// this rather than the published pane decision, which a withdrawal holds back.
  var decision: AgentStateDecision? {
    agent == nil ? nil : machine.decision
  }

  var boundAgent: DetectedAgent? { agent }

  /// The engine generation the evidence is bound to; the owner delegates a tick only
  /// when the probe confirmed this generation again.
  var boundProcess: AgentProcessGeneration? { process }

  /// A verified producer's eligible root decides the state: the owner's schedule
  /// drops the screen read and the provider sample.
  var isDelegated: Bool {
    guard let agent, support(agent) == .verified else { return false }
    return machine.hasProgramStatusAuthority
  }

  func invalidate() {
    revision &+= 1
    lastCapturedAt = nil
    reset()
    agent = nil
  }

  private func reset() {
    logProvider = nil
    nativeProvider = nil
    process = nil
    machine = AgentStateMachine()
    authorityEpoch &+= 1
  }

  private func acquireObservation() async {
    if observationInFlight {
      await withCheckedContinuation { observationWaiters.append($0) }
    } else {
      observationInFlight = true
    }
  }

  private func releaseObservation() {
    if observationWaiters.isEmpty {
      observationInFlight = false
    } else {
      observationWaiters.removeFirst().resume()
    }
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
    capturedAt: TimeInterval? = nil,
    configRoot: URL?,
    programStatus: ProgramStatusRecordStore? = nil,
    delegated: Bool = false
  ) async -> AgentStateDecision? {
    let captureTime = capturedAt ?? now
    let queuedRevision = revision
    await acquireObservation()
    defer { releaseObservation() }
    guard queuedRevision == revision, !Task.isCancelled else { return nil }
    guard lastCapturedAt.map({ captureTime >= $0 }) ?? true else { return machine.decision }
    lastCapturedAt = captureTime
    let hasProvider = agent == .codex || agent == .claude
    // An OSC-capable agent rebinds on a relaunch too, so the arrival-time fence
    // compares against the generation the probe actually confirmed.
    let rebindsOnProcessChange = hasProvider || agent.programStatusApp != nil
    if self.agent != agent || (rebindsOnProcessChange && process != nil && self.process != process)
      || (hasProvider && self.configRoot != configRoot)
    {
      reset()
      self.agent = agent
      self.process = process
      self.configRoot = configRoot
      if agent == .codex, process != nil { logProvider = CodexLogProvider(surfaceID: surfaceID) }
      if agent == .claude, process != nil { nativeProvider = ClaudeRuntimeProvider() }
    }
    // A poll's snapshot can be older than a push that arrived while the poll was
    // queued; the newer store stays.
    if let programStatus, programStatus.revision > programStatusStore.revision {
      programStatusStore = programStatus
    }
    let expectedRevision = revision
    let inputRevision = interactionRevision
    // Screen capture precedes the file read. A completion can fence this frame;
    // the next poll observes whether the UI has actually changed.
    if !delegated {
      machine.receive(.screen(screen, contentID: screenContentID), now: now)
    }
    let evidence = applyProgramStatus()
    // Under OSC authority the provider is not sampled at all, including on the tick
    // that takes authority: a native snapshot applied now would recreate the facts
    // the transition just retired and resurface after a withdrawal.
    if hasProvider, !delegated, !machine.hasProgramStatusAuthority, let process = self.process {
      let epoch = authorityEpoch
      let events: [AgentDetectionEvent]
      if let sampleOverride {
        events = await sampleOverride(process, configRoot)
      } else if let logProvider {
        events = await logProvider.sample(process: process, configRoot: configRoot)
      } else if let nativeProvider {
        events = await nativeProvider.sample(process: process, configRoot: configRoot)
      } else {
        events = [.unavailable]
      }
      guard revision == expectedRevision else { return nil }
      if epoch == authorityEpoch {
        for event in events { machine.receive(event, now: now) }
      }
    }
    if inputRevision != interactionRevision { machine.receive(.interaction, now: now) }
    let decision = machine.receive(.tick, now: now)
    compareShadow(evidence, live: decision)
    return decision
  }

  /// The push path: a report arrived for this surface. Consumed only against the
  /// generation the last probe confirmed; the arrival-time fence keeps a predecessor's
  /// records out of it.
  func receive(programStatus store: ProgramStatusRecordStore) -> ProgramStatusPush {
    programStatusStore = store
    guard agent != nil, process != nil else { return .none }
    let hadAuthority = machine.hasProgramStatusAuthority
    let evidence = applyProgramStatus()
    guard isVerified else {
      compareShadow(evidence, live: machine.decision)
      return .none
    }
    if machine.hasProgramStatusAuthority { return .decision(machine.decision) }
    return hadAuthority ? .withdrawn : .none
  }

  private var isVerified: Bool {
    agent.map { support($0) == .verified } ?? false
  }

  /// Derives the evidence for the current binding and, for a verified producer, feeds
  /// it to the machine. Returns the evidence for the shadow comparison.
  @discardableResult
  private func applyProgramStatus() -> ProgramStatusEvidence? {
    guard let agent, let app = agent.programStatusApp, let process else { return nil }
    let evidence = ProgramStatusEvidence(store: programStatusStore, app: app, notBefore: process.startedAt)
    guard support(agent) == .verified else { return evidence }
    let hadAuthority = machine.hasProgramStatusAuthority
    machine.receive(.programStatus(evidence, revision: programStatusStore.revision), now: now)
    if machine.hasProgramStatusAuthority, !hadAuthority {
      authorityEpoch &+= 1
    } else if hadAuthority, !machine.hasProgramStatusAuthority {
      lastProgramStatusWithdrawalAt = now
    }
    return evidence
  }

  /// Unverified producers: log the OSC decision next to the live one on transition,
  /// throttled per pair, never with record text.
  private func compareShadow(_ evidence: ProgramStatusEvidence?, live: AgentStateDecision) {
    guard let agent, support(agent) == .unverified, let evidence else {
      lastShadowKey = nil
      return
    }
    let osc = evidence.decision
    let key =
      "osc=\(osc.state.rawValue)/\(osc.reason.identifier)"
      + " live=\(live.state.rawValue)/\(live.reason.identifier)"
    guard key != lastShadowKey else { return }
    lastShadowKey = key
    let now = now
    if let last = shadowLogged[key], now - last < Self.shadowThrottle { return }
    shadowLogged[key] = now
    let surface = surfaceID.map { String($0.uuidString.prefix(8)) } ?? "-"
    log(
      "[ProgramStatus] shadow surface=\(surface) agent=\(agent.rawValue) \(key)"
        + " agree=\(osc.state == live.state) revision=\(programStatusStore.revision)")
  }
}
