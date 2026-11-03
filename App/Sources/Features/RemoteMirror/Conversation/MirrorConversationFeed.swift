import Foundation

/// Decodes tail changes into events on the tail's queue: bytes → lines → records → adapter.
nonisolated final class MirrorTranscriptPipeline: @unchecked Sendable {
  struct Ingest: Sendable {
    var events: [MirrorConversationEvent]
    /// The events belong to a new log segment: the file was replaced, truncated or lost.
    var resetsSegment: Bool
  }

  private let agent: DetectedAgent
  private var reader = MirrorJSONLineReader()
  private var adapter: any MirrorConversationAdapter
  private(set) var rejectedRecords = 0

  init?(agent: DetectedAgent) {
    guard let adapter = MirrorConversationAdapters.make(for: agent) else { return nil }
    self.agent = agent
    self.adapter = adapter
  }

  func ingest(_ change: MirrorTranscriptTail.Change) -> Ingest {
    switch change {
    case .replay(let data, let head, let startsMidRecord):
      restart()
      var events: [MirrorConversationEvent] = []
      if let head { events += bootstrap(head) }
      if startsMidRecord { reader.discardPartialFirstLine() }
      events += decode(reader.append(data))
      return Ingest(events: events, resetsSegment: false)
    case .appended(let data):
      return Ingest(events: decode(reader.append(data)), resetsSegment: false)
    case .rotated:
      restart()
      let changed = MirrorConversationEvent(
        .sessionChanged, .session(.init(reason: .rotated)), at: Date(), source: .host)
      return Ingest(events: [changed], resetsSegment: true)
    case .missing:
      let pending = MirrorConversationEvent(
        .sessionPending, .session(.init(reason: .uncertain)), at: Date(), source: .host)
      return Ingest(events: [pending], resetsSegment: true)
    }
  }

  private func restart() {
    reader.reset()
    if let fresh = MirrorConversationAdapters.make(for: agent) { adapter = fresh }
  }

  /// The replay window skipped the file's start; the first records still name the session.
  private func bootstrap(_ head: Data) -> [MirrorConversationEvent] {
    var headReader = MirrorJSONLineReader()
    for line in headReader.append(head) {
      guard let record = try? JSONSerialization.jsonObject(with: line) as? MirrorConversationRecord else { continue }
      let events = adapter.bootstrap(record)
      if !events.isEmpty { return events }
    }
    return []
  }

  private func decode(_ lines: [Data]) -> [MirrorConversationEvent] {
    var events: [MirrorConversationEvent] = []
    var rejected = 0
    for line in lines {
      guard let record = try? JSONSerialization.jsonObject(with: line) as? MirrorConversationRecord else {
        rejected += 1
        continue
      }
      events += adapter.events(for: record)
    }
    if rejected > 0 {
      rejectedRecords += rejected
      let notice = MirrorConversationEvent.Notice(
        level: .warning, text: "\(rejected) transcript record(s) could not be read", subtype: "transcript")
      events.append(.init(.notice, .notice(notice), at: Date(), source: .host))
    }
    return events
  }
}

/// Follows one pane's transcript and agent state and keeps its bounded conversation log
/// (docs-ai 087). `follow` switches transcripts on session changes; `observe` feeds the
/// pane's agent state; `stop()` is required before release.
@MainActor
final class MirrorConversationFeed {
  struct Transcript: Equatable, Sendable {
    let url: URL
    let agent: DetectedAgent
  }

  private(set) var log = MirrorConversationLog()
  /// The transcript being tailed; nil while pending or unsupported.
  private(set) var transcript: Transcript?
  /// The last transcript asked for, including an unsupported one, so repeats are no-ops.
  private var requested: Transcript?
  /// Called with the events just appended, sequences assigned, in order.
  var onEvents: (([MirrorConversationEvent]) -> Void)?

  private let queue: DispatchQueue
  private let tailOptions: MirrorTranscriptTail.Options
  private var tail: MirrorTranscriptTail?
  private var statusMapper = MirrorConversationStatusMapper()
  private var lastPane: PaneAgentState?
  private var generation = 0
  private var hasFollowed = false

  init(
    queue: DispatchQueue = DispatchQueue(label: "com.onevcat.prowl.mirror-conversation"),
    tailOptions: MirrorTranscriptTail.Options = .init()
  ) {
    self.queue = queue
    self.tailOptions = tailOptions
  }

  /// Follows `transcript`, or none while the Host cannot name one. Switching from one
  /// transcript to another sends `session.changed` with `reason`; the first follow does not.
  /// Every switch starts a new log segment that restates the current agent status.
  func follow(_ transcript: Transcript?, reason: MirrorConversationEvent.SessionReason? = nil) {
    guard transcript != requested || !hasFollowed else { return }
    hasFollowed = true
    requested = transcript
    let previous = self.transcript
    stopTail()
    self.transcript = transcript
    resetSegment()
    guard let transcript, let pipeline = MirrorTranscriptPipeline(agent: transcript.agent) else {
      self.transcript = nil
      let pending = MirrorConversationEvent(
        .sessionPending, .session(.init(reason: reason ?? .uncertain)), at: Date(), source: .host)
      append([pending] + currentStatus())
      return
    }
    var opening: [MirrorConversationEvent] = []
    if previous != nil {
      opening.append(
        .init(.sessionChanged, .session(.init(reason: reason ?? .uncertain)), at: Date(), source: .host))
    }
    append(opening + currentStatus())
    let generation = self.generation
    let tail = MirrorTranscriptTail(url: transcript.url, queue: queue, options: tailOptions) { [weak self] change in
      let ingest = pipeline.ingest(change)
      guard !ingest.events.isEmpty || ingest.resetsSegment else { return }
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self, self.generation == generation else { return }
          self.receive(ingest)
        }
      }
    }
    self.tail = tail
    tail.start()
  }

  func observe(_ pane: PaneAgentState) {
    lastPane = pane
    if let event = statusMapper.event(for: pane, at: Date()) { append([event]) }
  }

  func stop() {
    stopTail()
    transcript = nil
    requested = nil
  }

  private func receive(_ ingest: MirrorTranscriptPipeline.Ingest) {
    if ingest.resetsSegment { resetSegment() }
    append(ingest.events + (ingest.resetsSegment ? currentStatus() : []))
  }

  private func resetSegment() {
    log.clear()
    statusMapper.reset()
  }

  /// The status the pane last reported, restated at the start of a segment.
  private func currentStatus() -> [MirrorConversationEvent] {
    guard let lastPane, let event = statusMapper.event(for: lastPane, at: Date()) else { return [] }
    return [event]
  }

  private func stopTail() {
    generation += 1
    tail?.stop()
    tail = nil
  }

  private func append(_ events: [MirrorConversationEvent]) {
    guard !events.isEmpty else { return }
    let assigned = log.append(contentsOf: events)
    onEvents?(assigned)
  }
}
