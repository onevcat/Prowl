import Foundation
import ProwlCLIShared

private let observationLogger = SupaLogger("AgentObservation")

private struct AgentSignalChannelRecord {
  var state: AgentSignalChannelState
  var confidence: AgentSignal.Confidence
  var events: [AgentSignalEvent]
  var lastSeenAt: Date
  var sessionID: String?
}

private struct PendingManagedHookSignal {
  let input: AgentNativeHookInput
  let callerAncestry: [AgentProcessGeneration]
}

private struct ManagedHookRegistrationRecord {
  let launch: AgentHookLaunchRegistration
  /// Whether the runtime announces a new session with its own start event.
  ///
  /// Such a runtime hands the channel over only on that event, so a late event from a
  /// superseded session is simply rejected. A runtime without a start event (Codex, whose
  /// only native event is a turn edge) can rotate on ordinary events, so its superseded
  /// sessions must be retired explicitly or a late one would silently take the channel back.
  var announcesSessionStarts: Bool { launch.coveredEvents.contains(.sessionStart) }
  var evidenceEpoch: UUID
  var processGeneration: AgentProcessGeneration?
  var sessionID: String?
  /// Sessions the hook itself rotated away from (an authoritative SessionStart moved on). These
  /// are permanent until a fresh SessionStart resumes one; a lagging detector read of one is
  /// ignored, never resurrected.
  var retiredSessionIDs: Set<String> = []
  /// The hook session the detector currently reports having moved away from. Unlike a retired
  /// session this is reversible: it blocks a delayed hook event for that session, but the detector
  /// can self-correct by reporting the session again, and a SessionStart clears it.
  var detectorSupersededSessionID: String?
  /// A detector session a SessionStart has overridden as the arbiter, so a detector that keeps
  /// reporting the same conflicting candidate cannot repeatedly re-supersede the live session.
  var suppressedDetectorSessionID: String?
  var verified = false
  var pendingSignals: [PendingManagedHookSignal] = []
}

enum ManagedHookRecordResult: Equatable, Sendable {
  case rejected
  case pending
  case accepted(signal: AgentSignal, evidenceEpoch: UUID)
}

struct AgentEvidenceEpochUpdate: Equatable, Sendable {
  var activatedSignals: [AgentSignal] = []
  var revokedForwardingRecords: [CodexForwardingRecord] = []
}

struct AgentCurrentSignalEvidence: Sendable {
  let activeTerminal: AgentSignal?
  let latest: AgentSignal?
  var latestManagedHook: AgentSignal?
}

/// Terminal-owned publication state for one multicast observer per surface.
/// The detector remains the producer of agent entries; this store is the
/// canonical replay/stream boundary shared by reducers and CLI observers.
@MainActor
final class AgentObservationStore {
  private struct SurfaceRecord {
    var agent: ActiveAgentEntry?
    var latestSignal: AgentSignal?
    var latestSignalBinding: AgentSignalBinding?
    var latestCurrentSignal: AgentSignal?
    var latestManagedHookSignal: AgentSignal?
    var activeTerminalSignal: AgentSignal?
    var processGeneration: AgentProcessGeneration?
    var sessionID: String?
    var sessionlessSignalsAllowed = true
    var evidenceEpoch = UUID()
    var awaitingFirstProcessGeneration = false
    var firstProcessGenerationStartedBefore: Date?
    var channels: [String: AgentSignalChannelRecord] = [:]
    var managedHook: ManagedHookRegistrationRecord?
    var revision: UInt64 = 0
    var subscribers: [UUID: AgentObservationStream.Continuation] = [:]

    mutating func clearCurrentSignals() {
      latestCurrentSignal = nil
      latestManagedHookSignal = nil
      activeTerminalSignal = nil
    }

    var snapshot: AgentObservationSnapshot {
      AgentObservationSnapshot(
        agent: agent,
        latestSignal: latestSignal,
        revision: revision
      )
    }
  }

  private var records: [UUID: SurfaceRecord] = [:]
  private let bufferCapacity: Int
  private let now: @MainActor () -> Date
  /// The launched process starts immediately; this spans more than three idle detection polls
  /// while refusing a manually started replacement long after a missed short-lived runtime.
  private let dispatchGenerationWindow: TimeInterval

  init(
    bufferCapacity: Int,
    now: @escaping @MainActor () -> Date = Date.init,
    dispatchGenerationWindow: TimeInterval = 10
  ) {
    self.bufferCapacity = max(1, bufferCapacity)
    self.now = now
    self.dispatchGenerationWindow = max(0, dispatchGenerationWindow)
  }

  func observe(surfaceID: UUID, isLive: Bool) -> AgentObservationStream {
    guard isLive else {
      return AgentObservationStream(bufferingPolicy: .unbounded) { continuation in
        continuation.yield(
          .snapshot(
            AgentObservationSnapshot(agent: nil, latestSignal: nil, revision: 0)
          ))
        continuation.yield(.surfaceClosed)
        continuation.finish()
      }
    }

    let subscriberID = UUID()
    var continuation: AgentObservationStream.Continuation?
    let stream = AgentObservationStream(
      bufferingPolicy: .bufferingOldest(bufferCapacity)
    ) { continuation = $0 }
    guard let continuation else { return stream }

    continuation.onTermination = { @Sendable [weak self] _ in
      Task { @MainActor [weak self] in
        self?.removeSubscriber(subscriberID, surfaceID: surfaceID)
      }
    }

    var record = records[surfaceID] ?? SurfaceRecord()
    record.subscribers[subscriberID] = continuation
    let snapshot = record.snapshot
    records[surfaceID] = record
    continuation.yield(.snapshot(snapshot))
    return stream
  }

  /// Callers must establish that the surface is live before publishing. The
  /// manager owns that invariant: detector callbacks come only from live state,
  /// and cooperative signals pass its `containsSurface` guard.
  @discardableResult
  func publishAgentChanged(_ entry: ActiveAgentEntry) -> Bool {
    var record = records[entry.surfaceID] ?? SurfaceRecord()
    guard record.agent != entry else { return false }
    let beganWorking =
      record.agent?.displayState != .working
      && entry.displayState == .working
    record.agent = entry
    if beganWorking {
      record.activeTerminalSignal = nil
    }
    record.revision &+= 1
    records[entry.surfaceID] = record
    publish(.changed(entry), surfaceID: entry.surfaceID)
    return beganWorking
  }

  func publishAgentRemoved(surfaceID: UUID) {
    guard var record = records[surfaceID], record.agent != nil else { return }
    record.agent = nil
    record.revision &+= 1
    records[surfaceID] = record
    publish(.removed, surfaceID: surfaceID)
  }

  /// The manager validates surface liveness before this publication seam.
  func publishSignal(_ signal: AgentSignal, surfaceID: UUID) {
    publishSignal(signal, binding: .unbound, surfaceID: surfaceID)
  }

  func publishSignal(
    _ signal: AgentSignal,
    binding: AgentSignalBinding,
    surfaceID: UUID
  ) {
    var record = records[surfaceID] ?? SurfaceRecord()
    record.latestSignal = signal
    record.latestSignalBinding = binding
    if binding == .current {
      record.latestCurrentSignal = signal
      switch signal.event {
      case .turnEnded, .needsInput, .sessionEnd:
        record.activeTerminalSignal = signal
      case .sessionStart, .progress:
        record.activeTerminalSignal = nil
      }
      let source = signal.source.payloadName
      var channel =
        record.channels[source]
        ?? AgentSignalChannelRecord(
          state: .observed,
          confidence: signal.confidence,
          events: [],
          lastSeenAt: signal.timestamp,
          sessionID: signal.sessionID
        )
      if !channel.events.contains(signal.event) { channel.events.append(signal.event) }
      channel.confidence = signal.confidence
      channel.lastSeenAt = signal.timestamp
      channel.sessionID = signal.sessionID
      record.channels[source] = channel
    }
    record.revision &+= 1
    records[surfaceID] = record
    publish(.signal(signal), surfaceID: surfaceID)
  }

  func publishSurfaceClosed(surfaceID: UUID) {
    guard records[surfaceID] != nil else { return }
    publishAgentRemoved(surfaceID: surfaceID)
    guard let record = records.removeValue(forKey: surfaceID) else { return }
    for continuation in record.subscribers.values {
      switch continuation.yield(.surfaceClosed) {
      case .enqueued:
        continuation.finish()
      case .dropped:
        continuation.finish(throwing: AgentObservationError.bufferOverflow)
      case .terminated:
        continue
      @unknown default:
        continuation.finish(throwing: AgentObservationError.bufferOverflow)
      }
    }
  }

  /// Internal diagnostic seam used by cancellation tests and available to S2
  /// when it exposes per-pane signal capability health.
  func subscriberCount(surfaceID: UUID) -> Int {
    records[surfaceID]?.subscribers.count ?? 0
  }

  func snapshot(surfaceID: UUID) -> AgentObservationSnapshot? {
    records[surfaceID]?.snapshot
  }

  func currentSignalEvidence(surfaceID: UUID) -> AgentCurrentSignalEvidence {
    guard let record = records[surfaceID] else {
      return AgentCurrentSignalEvidence(activeTerminal: nil, latest: nil)
    }
    return AgentCurrentSignalEvidence(
      activeTerminal: record.activeTerminalSignal,
      latest: record.latestCurrentSignal,
      latestManagedHook: record.latestManagedHookSignal
    )
  }

  func registerManagedHook(
    _ registration: AgentHookLaunchRegistration,
    surfaceID: UUID
  ) -> UUID {
    let epoch = beginDispatchEpoch(surfaceID: surfaceID)
    var record = records[surfaceID] ?? SurfaceRecord()
    record.managedHook = ManagedHookRegistrationRecord(
      launch: registration,
      evidenceEpoch: epoch
    )
    records[surfaceID] = record
    return epoch
  }

  func hasManagedHook(surfaceID: UUID) -> Bool {
    records[surfaceID]?.managedHook != nil
  }

  func revokeManagedHook(surfaceID: UUID) -> CodexForwardingRecord? {
    guard var record = records[surfaceID], let managed = record.managedHook else { return nil }
    record.managedHook = nil
    record.evidenceEpoch = UUID()
    record.processGeneration = nil
    record.sessionID = nil
    record.awaitingFirstProcessGeneration = false
    record.firstProcessGenerationStartedBefore = nil
    record.channels.removeAll()
    record.clearCurrentSignals()
    if record.latestSignal != nil { record.latestSignalBinding = .stale }
    records[surfaceID] = record
    return managed.launch.forwardingRecord
  }

  func recordManagedHook(
    _ input: AgentNativeHookInput,
    callerAncestry: [AgentProcessGeneration],
    surfaceID: UUID
  ) -> ManagedHookRecordResult {
    guard input.validationErrorMessage == nil,
      var record = records[surfaceID],
      var managed = record.managedHook,
      managed.launch.token == input.token,
      managed.launch.runtime == input.runtime,
      managed.launch.nativeEvents[input.signal.nativeEvent] == input.signal.event,
      normalizedPath(managed.launch.launchCWD) == normalizedPath(input.signal.cwd)
    else {
      logManagedHookRejection(input, surfaceID: surfaceID)
      return .rejected
    }
    guard let generation = managed.processGeneration ?? record.processGeneration else {
      guard record.awaitingFirstProcessGeneration else { return .rejected }
      if managed.pendingSignals.count < 8 {
        managed.pendingSignals.append(
          PendingManagedHookSignal(input: input, callerAncestry: callerAncestry)
        )
        record.managedHook = managed
        records[surfaceID] = record
      }
      return .pending
    }
    guard callerAncestry.contains(generation), managed.processGeneration == generation else {
      observationLogger.debug(
        "managed hook rejected \(input.runtime.rawValue)/\(input.signal.nativeEvent) reason=generation-mismatch"
      )
      return .rejected
    }
    // A retired session is normally dead, but an announcing runtime can legitimately resume one:
    // Claude's /resume re-announces the old id with a fresh authoritative SessionStart. Let that
    // reactivate it (rotation below retires the current session and re-verifies); every other
    // retired-session event, and Codex (no SessionStart), stays rejected.
    let resumesRetiredSession =
      managed.announcesSessionStarts
      && input.signal.event == .sessionStart
      && managed.retiredSessionIDs.contains(input.signal.sessionID)
    if managed.retiredSessionIDs.contains(input.signal.sessionID), !resumesRetiredSession {
      observationLogger.debug(
        "managed hook rejected \(input.runtime.rawValue)/\(input.signal.nativeEvent) reason=retired-session"
      )
      return .rejected
    }
    if resumesRetiredSession {
      managed.retiredSessionIDs.remove(input.signal.sessionID)
    }
    // A session the detector reports having moved away from blocks a delayed hook event for it,
    // but only a SessionStart may arbitrate (re-affirm or rotate) — anything else is a stale edge.
    if managed.detectorSupersededSessionID == input.signal.sessionID,
      input.signal.event != .sessionStart
    {
      observationLogger.debug(
        "managed hook rejected \(input.runtime.rawValue)/\(input.signal.nativeEvent) reason=detector-superseded"
      )
      return .rejected
    }

    if let currentSession = managed.sessionID,
      currentSession != input.signal.sessionID
    {
      let mayRotateSession =
        !managed.announcesSessionStarts || input.signal.event == .sessionStart
      guard mayRotateSession else {
        observationLogger.debug(
          "managed hook rejected \(input.runtime.rawValue)/\(input.signal.nativeEvent) reason=session-changed"
        )
        return .rejected
      }
      // Retire the superseded session for every runtime so a lagging detector read of it is
      // ignored rather than rolling the channel back to it (announcing runtimes rotate here on
      // their own SessionStart; Codex rotates on ordinary events).
      managed.retiredSessionIDs.insert(currentSession)
      record.evidenceEpoch = UUID()
      record.channels.removeAll()
      record.clearCurrentSignals()
      if record.latestSignal != nil { record.latestSignalBinding = .stale }
      managed.evidenceEpoch = record.evidenceEpoch
      managed.verified = false
    }
    // A SessionStart is the final arbiter: it clears any detector supersession and suppresses the
    // conflicting detector candidate (the session the detector currently reports) so a repeating
    // false positive cannot re-supersede the session the hook just affirmed.
    if input.signal.event == .sessionStart {
      managed.detectorSupersededSessionID = nil
      managed.suppressedDetectorSessionID =
        record.sessionID != input.signal.sessionID ? record.sessionID : nil
    }
    record.sessionID = input.signal.sessionID
    managed.sessionID = input.signal.sessionID
    managed.verified = true
    let runtime = AgentProfileRuntime(rawValue: input.runtime.rawValue) ?? .claude
    let signal = AgentSignal(
      kind: signalKind(input.signal.event),
      source: .hook(runtime: runtime, event: input.signal.nativeEvent),
      confidence: .exact,
      timestamp: now(),
      sessionID: input.signal.sessionID,
      detail: input.signal.detail,
      claimedOrigin: nil
    )
    let source = signal.source.payloadName
    record.channels[source] = AgentSignalChannelRecord(
      state: .verifiedLive,
      confidence: .exact,
      events: managed.launch.coveredEvents,
      lastSeenAt: signal.timestamp,
      sessionID: signal.sessionID
    )
    record.managedHook = managed
    record.latestManagedHookSignal = signal
    records[surfaceID] = record
    publishSignal(signal, binding: .current, surfaceID: surfaceID)
    return .accepted(signal: signal, evidenceEpoch: managed.evidenceEpoch)
  }

  func beginDispatchEpoch(surfaceID: UUID) -> UUID {
    var record = records[surfaceID] ?? SurfaceRecord()
    record.evidenceEpoch = UUID()
    record.processGeneration = nil
    record.sessionID = nil
    record.sessionlessSignalsAllowed = true
    record.awaitingFirstProcessGeneration = true
    record.firstProcessGenerationStartedBefore = now().addingTimeInterval(
      dispatchGenerationWindow
    )
    record.channels.removeAll()
    record.clearCurrentSignals()
    if record.latestSignal != nil { record.latestSignalBinding = .stale }
    records[surfaceID] = record
    return record.evidenceEpoch
  }

  func currentEvidenceEpoch(surfaceID: UUID) -> UUID? {
    records[surfaceID]?.evidenceEpoch
  }

  @discardableResult
  func updateEvidenceEpoch(
    surfaceID: UUID,
    processGeneration: AgentProcessGeneration?,
    sessionID: String?
  ) -> AgentEvidenceEpochUpdate {
    var record = records[surfaceID] ?? SurfaceRecord()
    if record.managedHook != nil,
      record.processGeneration != nil,
      processGeneration == nil
    {
      return AgentEvidenceEpochUpdate()
    }
    let acceptedSessionID = acceptedManagedSessionID(sessionID, record: record)
    let firstGenerationIsTimely =
      processGeneration.map {
        $0.startedAt <= (record.firstProcessGenerationStartedBefore ?? .distantPast)
      } ?? false
    let attachesFirstLaunchGeneration =
      record.awaitingFirstProcessGeneration
      && record.processGeneration == nil
      && processGeneration != nil
      && (firstGenerationIsTimely || record.managedHook != nil)
    let rejectsLateFirstGeneration =
      record.awaitingFirstProcessGeneration
      && record.processGeneration == nil
      && processGeneration != nil
      && !firstGenerationIsTimely
      && record.managedHook == nil
    let processChanged =
      rejectsLateFirstGeneration
      || (!attachesFirstLaunchGeneration && record.processGeneration != processGeneration)
    let sessionChanged =
      !processChanged
      && record.sessionID != nil
      && acceptedSessionID != nil
      && record.sessionID != acceptedSessionID
    var update = AgentEvidenceEpochUpdate()
    if processChanged || sessionChanged {
      record.evidenceEpoch = UUID()
      record.channels.removeAll()
      record.clearCurrentSignals()
      if record.latestSignal != nil { record.latestSignalBinding = .stale }
      record.sessionlessSignalsAllowed = processChanged
      if processChanged { record.sessionID = nil }
      if processChanged, let managed = record.managedHook {
        if let forwardingRecord = managed.launch.forwardingRecord {
          update.revokedForwardingRecords.append(forwardingRecord)
        }
        record.managedHook = nil
      } else if sessionChanged, var managed = record.managedHook {
        Self.reconcileManagedSessionOnDetectorChange(
          &managed, evidenceEpoch: record.evidenceEpoch, acceptedSessionID: acceptedSessionID)
        record.managedHook = managed
      }
    }
    if attachesFirstLaunchGeneration || rejectsLateFirstGeneration {
      record.awaitingFirstProcessGeneration = false
      record.firstProcessGenerationStartedBefore = nil
    }
    if attachesFirstLaunchGeneration, var managed = record.managedHook {
      managed.processGeneration = processGeneration
      let pending = managed.pendingSignals
      managed.pendingSignals.removeAll()
      record.managedHook = managed
      record.processGeneration = processGeneration
      if let acceptedSessionID { record.sessionID = acceptedSessionID }
      records[surfaceID] = record
      for pendingSignal in pending {
        if case .accepted(let signal, _) = recordManagedHook(
          pendingSignal.input,
          callerAncestry: pendingSignal.callerAncestry,
          surfaceID: surfaceID
        ) {
          update.activatedSignals.append(signal)
        }
      }
      return update
    }
    record.processGeneration = processGeneration
    if let acceptedSessionID { record.sessionID = acceptedSessionID }
    records[surfaceID] = record
    return update
  }

  /// Reconcile a managed hook's session bookkeeping when the detector reports a different session.
  /// Codex (no SessionStart) retires the superseded session permanently; an announcing runtime
  /// marks it reversibly so a delayed edge is blocked but the detector can self-correct.
  private static func reconcileManagedSessionOnDetectorChange(
    _ managed: inout ManagedHookRegistrationRecord,
    evidenceEpoch: UUID,
    acceptedSessionID: String?
  ) {
    managed.evidenceEpoch = evidenceEpoch
    managed.verified = false
    managed.pendingSignals.removeAll()
    guard managed.announcesSessionStarts else {
      if let managedSessionID = managed.sessionID, managedSessionID != acceptedSessionID {
        managed.retiredSessionIDs.insert(managedSessionID)
      }
      managed.sessionID = nil
      return
    }
    if acceptedSessionID == managed.sessionID {
      // The detector returned to the hook session: clear the reversible supersession.
      managed.detectorSupersededSessionID = nil
    } else {
      // The detector moved to a new, non-suppressed candidate: supersede the hook session
      // reversibly (block its delayed edges, allow a later correction) and drop any prior
      // SessionStart suppression, which this genuinely new candidate invalidates.
      managed.detectorSupersededSessionID = managed.sessionID
      managed.suppressedDetectorSessionID = nil
    }
  }

  private func acceptedManagedSessionID(
    _ sessionID: String?,
    record: SurfaceRecord
  ) -> String? {
    // A session the hook rotated away from (retired), or one a SessionStart has already overridden
    // as the arbiter (suppressed), must not drive rotation: a lagging or repeating detector read of
    // it would otherwise revoke the freshly verified session and roll `record.sessionID` backwards.
    // A genuinely new session the hook has not yet announced is still honored, so the channel is
    // distrusted until the hook re-announces.
    guard let sessionID, let managed = record.managedHook else { return sessionID }
    if managed.retiredSessionIDs.contains(sessionID) { return nil }
    if managed.suppressedDetectorSessionID == sessionID { return nil }
    return sessionID
  }

  func bindingForSignal(
    surfaceID: UUID,
    generationMatches: Bool,
    signalSessionID: String?
  ) -> AgentSignalBinding {
    guard generationMatches, var record = records[surfaceID] else { return .unbound }
    if let signalSessionID {
      if let current = record.sessionID, current != signalSessionID { return .unbound }
      if record.sessionID == nil {
        record.sessionID = signalSessionID
        records[surfaceID] = record
      }
      return .current
    }
    return record.sessionlessSignalsAllowed ? .current : .unbound
  }

  func signalsPayload(
    surfaceID: UUID,
    formatter: ISO8601DateFormatter,
    includeDiagnosticLast: Bool
  ) -> AgentSignalsPayload {
    guard let record = records[surfaceID] else { return .empty }
    let channels = record.channels
      .map { source, channel in
        AgentSignalChannelPayload(
          source: source,
          state: channel.state,
          confidence: channel.confidence.rawValue,
          events: channel.events.sorted { $0.rawValue < $1.rawValue },
          lastSeenAt: formatter.string(from: channel.lastSeenAt),
          sessionID: channel.sessionID
        )
      }
      .sorted { $0.source < $1.source }
    let mayExposeLast = includeDiagnosticLast || record.latestSignalBinding == .current
    let last =
      mayExposeLast
      ? record.latestSignal.map {
        $0.payload(timestamp: formatter.string(from: $0.timestamp))
      } : nil
    return AgentSignalsPayload(
      channels: channels,
      last: last,
      lastBinding: last == nil ? nil : (record.latestSignalBinding ?? .unbound)
    )
  }

  private func signalKind(_ event: AgentSignalEvent) -> AgentSignal.Kind {
    switch event {
    case .turnEnded: .turnEnded
    case .needsInput: .needsInput
    case .sessionStart: .sessionStart
    case .sessionEnd: .sessionEnd
    case .progress: .progress(nil)
    }
  }

  /// A rejected native hook is silent by design, which makes a misconfigured runtime very
  /// hard to diagnose. Name the first failing precondition in debug builds only.
  private func logManagedHookRejection(_ input: AgentNativeHookInput, surfaceID: UUID) {
    let event = "runtime=\(input.runtime.rawValue) event=\(input.signal.nativeEvent)"
    guard let managed = records[surfaceID]?.managedHook else {
      observationLogger.debug("managed hook rejected \(event) reason=no-registration")
      return
    }
    let reason: String
    if managed.launch.token != input.token {
      reason = "token-mismatch"
    } else if managed.launch.runtime != input.runtime {
      reason = "runtime-mismatch expected=\(managed.launch.runtime.rawValue)"
    } else if managed.launch.nativeEvents[input.signal.nativeEvent] != input.signal.event {
      reason = "event-not-declared declared=\(managed.launch.nativeEvents.keys.sorted().joined(separator: ","))"
    } else if normalizedPath(managed.launch.launchCWD) != normalizedPath(input.signal.cwd) {
      reason =
        "cwd-mismatch launch=\(normalizedPath(managed.launch.launchCWD)) hook=\(normalizedPath(input.signal.cwd))"
    } else {
      reason = "invalid-input"
    }
    observationLogger.debug("managed hook rejected \(event) reason=\(reason)")
  }

  private func normalizedPath(_ url: URL) -> String {
    normalizedPath(url.path(percentEncoded: false))
  }

  /// Runtimes disagree on how they report their working directory: some echo the shell's
  /// logical path (`/tmp/...`) while others report `getcwd()`, which the kernel already
  /// resolved (`/private/tmp/...`). Both name the same directory, so symlinks are resolved
  /// before comparison — otherwise a correctly launched agent's hooks are silently rejected.
  private func normalizedPath(_ path: String) -> String {
    let value = URL(filePath: path, directoryHint: .isDirectory)
      .standardizedFileURL
      .resolvingSymlinksInPath()
      .path(percentEncoded: false)
    return value.count > 1 && value.hasSuffix("/") ? String(value.dropLast()) : value
  }

  private func publish(_ event: ObservedAgentState, surfaceID: UUID) {
    guard let subscribers = records[surfaceID]?.subscribers else { return }
    for (subscriberID, continuation) in subscribers {
      switch continuation.yield(event) {
      case .enqueued:
        continue
      case .dropped:
        continuation.finish(throwing: AgentObservationError.bufferOverflow)
        records[surfaceID]?.subscribers.removeValue(forKey: subscriberID)
      case .terminated:
        records[surfaceID]?.subscribers.removeValue(forKey: subscriberID)
      @unknown default:
        continuation.finish(throwing: AgentObservationError.bufferOverflow)
        records[surfaceID]?.subscribers.removeValue(forKey: subscriberID)
      }
    }
  }

  private func removeSubscriber(_ subscriberID: UUID, surfaceID: UUID) {
    guard var record = records[surfaceID] else { return }
    record.subscribers.removeValue(forKey: subscriberID)
    records[surfaceID] = record
  }
}
