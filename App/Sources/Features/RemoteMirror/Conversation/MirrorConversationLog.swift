import Foundation

/// The bounded, ordered event log of one conversation subscription. Sequence numbers are
/// monotonic for the life of the log, including across `clear()`, so a client's `since`
/// never means two different things. Retention is by event count and estimated bytes.
nonisolated struct MirrorConversationLog: Sendable {
  struct Snapshot: Equatable, Sendable {
    let events: [MirrorConversationEvent]
    /// Events between the requested point and `events.first` were dropped.
    let gap: Bool
    let latestSequence: UInt64
    /// The session the retained events belong to, kept even after its `session.started`
    /// was evicted, so a fresh subscriber never depends on the first event surviving.
    let session: MirrorConversationEvent.Session?
  }

  var maximumEvents = 500
  var maximumBytes = 1_024 * 1_024

  private(set) var events: [MirrorConversationEvent] = []
  private(set) var latestSequence: UInt64 = 0
  /// Merged from `session.started` and `session.updated`; nil between sessions.
  private(set) var currentSession: MirrorConversationEvent.Session?
  private var retainedBytes = 0
  /// The sequence the current segment started after; `clear()` moves it.
  private var segmentStart: UInt64 = 0

  @discardableResult
  mutating func append(_ event: MirrorConversationEvent) -> MirrorConversationEvent {
    var assigned = event
    latestSequence += 1
    assigned.sequence = latestSequence
    events.append(assigned)
    retainedBytes += assigned.estimatedBytes
    track(assigned)
    evictIfNeeded()
    return assigned
  }

  private mutating func track(_ event: MirrorConversationEvent) {
    switch (event.kind, event.payload) {
    case (.sessionStarted, .session(let session)):
      currentSession = session
    case (.sessionUpdated, .session(let update)):
      var merged = currentSession ?? .init()
      if let id = update.id { merged.id = id }
      if let cwd = update.cwd { merged.cwd = cwd }
      if let model = update.model { merged.model = model }
      if let title = update.title { merged.title = title }
      if let version = update.version { merged.version = version }
      if let cost = update.costUSD { merged.costUSD = cost }
      currentSession = merged
    case (.sessionChanged, _), (.sessionPending, _), (.sessionEnded, _):
      currentSession = nil
    default:
      break
    }
  }

  @discardableResult
  mutating func append(contentsOf newEvents: [MirrorConversationEvent]) -> [MirrorConversationEvent] {
    newEvents.map { append($0) }
  }

  /// Drops retained events; sequences keep counting.
  mutating func clear() {
    events.removeAll()
    retainedBytes = 0
    segmentStart = latestSequence
  }

  func snapshot(since: UInt64?) -> Snapshot {
    guard let oldest = events.first?.sequence else {
      // Nothing retained: a client whose point lies before this segment still has a gap.
      let behind = since.map { $0 < segmentStart } ?? false
      return Snapshot(events: [], gap: behind, latestSequence: latestSequence, session: currentSession)
    }
    guard let since else {
      return Snapshot(
        events: events, gap: oldest > segmentStart + 1, latestSequence: latestSequence, session: currentSession)
    }
    if since >= latestSequence {
      return Snapshot(events: [], gap: false, latestSequence: latestSequence, session: currentSession)
    }
    if since + 1 < oldest {
      return Snapshot(events: events, gap: true, latestSequence: latestSequence, session: currentSession)
    }
    return Snapshot(
      events: events.filter { $0.sequence > since }, gap: false, latestSequence: latestSequence, session: currentSession
    )
  }

  private mutating func evictIfNeeded() {
    while events.count > 1, events.count > maximumEvents || retainedBytes > maximumBytes {
      retainedBytes -= events.removeFirst().estimatedBytes
    }
  }
}

extension MirrorConversationEvent {
  /// A cheap size estimate for retention: the texts an event carries plus a fixed envelope.
  nonisolated var estimatedBytes: Int {
    let texts: [String?]
    switch payload {
    case .session(let value): texts = [value.title, value.cwd, value.id]
    case .turn(let value): texts = [value.lastMessage?.text]
    case .message(let value): texts = [value.text.text]
    case .reasoning(let value): texts = [value.summary?.text]
    case .toolStart(let value): texts = [value.title, value.command, value.path] + (value.changedPaths ?? [])
    case .toolEnd(let value): texts = [value.output?.text, value.diff?.text]
    case .status, .none: texts = []
    case .prompt(let value):
      let questions = value.questions ?? []
      texts =
        [value.detail?.text, value.title] + questions.map(\.question) + questions.flatMap(\.options).map(\.label)
        + (value.choices ?? []).map(\.label)
    case .subagent(let value): texts = [value.summary?.text]
    case .notice(let value): texts = [value.text]
    }
    return 160 + texts.reduce(0) { $0 + ($1?.utf8.count ?? 0) }
  }
}
