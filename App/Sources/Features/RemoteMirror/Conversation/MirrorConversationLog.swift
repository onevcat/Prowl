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
  }

  var maximumEvents = 500
  var maximumBytes = 1_024 * 1_024

  private(set) var events: [MirrorConversationEvent] = []
  private(set) var latestSequence: UInt64 = 0
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
    evictIfNeeded()
    return assigned
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
      return Snapshot(events: [], gap: false, latestSequence: latestSequence)
    }
    guard let since else {
      return Snapshot(events: events, gap: oldest > segmentStart + 1, latestSequence: latestSequence)
    }
    if since >= latestSequence { return Snapshot(events: [], gap: false, latestSequence: latestSequence) }
    if since + 1 < oldest { return Snapshot(events: events, gap: true, latestSequence: latestSequence) }
    return Snapshot(events: events.filter { $0.sequence > since }, gap: false, latestSequence: latestSequence)
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
    case .toolStart(let value): texts = [value.title, value.command, value.path]
    case .toolEnd(let value): texts = [value.output?.text]
    case .status, .none: texts = []
    case .prompt(let value):
      texts = [value.detail?.text, value.title] + (value.questions ?? []).map(\.question)
    case .subagent(let value): texts = [value.summary?.text]
    case .notice(let value): texts = [value.text]
    }
    return 160 + texts.reduce(0) { $0 + ($1?.utf8.count ?? 0) }
  }
}
