import Foundation

/// Decodes tail changes into events on the tail's queue: bytes → lines → records → adapter.
nonisolated final class MirrorTranscriptPipeline: @unchecked Sendable {
  private let agent: DetectedAgent
  private var reader = MirrorJSONLineReader()
  private var adapter: any MirrorConversationAdapter
  private(set) var rejectedRecords = 0

  init?(agent: DetectedAgent) {
    guard let adapter = MirrorConversationAdapters.make(for: agent) else { return nil }
    self.agent = agent
    self.adapter = adapter
  }

  func ingest(_ change: MirrorTranscriptTail.Change) -> [MirrorConversationEvent] {
    switch change {
    case .replay(let data, let startsMidRecord):
      restart()
      if startsMidRecord { reader.discardPartialFirstLine() }
      return decode(reader.append(data))
    case .appended(let data):
      return decode(reader.append(data))
    case .rotated:
      restart()
      return [.init(.sessionChanged, .session(.init(reason: .rotated)), at: Date(), source: .host)]
    case .missing:
      return [.init(.sessionPending, .session(.init(reason: .uncertain)), at: Date(), source: .host)]
    }
  }

  private func restart() {
    reader.reset()
    if let fresh = MirrorConversationAdapters.make(for: agent) { adapter = fresh }
  }

  private func decode(_ lines: [Data]) -> [MirrorConversationEvent] {
    var events: [MirrorConversationEvent] = []
    for line in lines {
      guard let record = try? JSONSerialization.jsonObject(with: line) as? MirrorConversationRecord else {
        rejectedRecords += 1
        continue
      }
      events += adapter.events(for: record)
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
  private(set) var transcript: Transcript?
  /// Called with the events just appended, sequences assigned, in order.
  var onEvents: (([MirrorConversationEvent]) -> Void)?

  private let queue: DispatchQueue
  private let tailOptions: MirrorTranscriptTail.Options
  private var tail: MirrorTranscriptTail?
  private var statusMapper = MirrorConversationStatusMapper()
  private var generation = 0

  init(
    queue: DispatchQueue = DispatchQueue(label: "com.onevcat.prowl.mirror-conversation"),
    tailOptions: MirrorTranscriptTail.Options = .init()
  ) {
    self.queue = queue
    self.tailOptions = tailOptions
  }

  /// Follows `transcript`, or none while the Host cannot name one. Switching from one
  /// transcript to another sends `session.changed` with `reason`; the first follow does not.
  func follow(_ transcript: Transcript?, reason: MirrorConversationEvent.SessionReason? = nil) {
    guard transcript != self.transcript else { return }
    let previous = self.transcript
    stopTail()
    self.transcript = transcript
    log.clear()
    guard let transcript, let pipeline = MirrorTranscriptPipeline(agent: transcript.agent) else {
      self.transcript = nil
      append([.init(.sessionPending, .session(.init(reason: reason ?? .uncertain)), at: Date(), source: .host)])
      return
    }
    if previous != nil {
      append([.init(.sessionChanged, .session(.init(reason: reason ?? .uncertain)), at: Date(), source: .host)])
    }
    let generation = self.generation
    let tail = MirrorTranscriptTail(url: transcript.url, queue: queue, options: tailOptions) { [weak self] change in
      let events = pipeline.ingest(change)
      guard !events.isEmpty else { return }
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self, self.generation == generation else { return }
          self.append(events)
        }
      }
    }
    self.tail = tail
    tail.start()
  }

  func observe(_ pane: PaneAgentState) {
    if let event = statusMapper.event(for: pane, at: Date()) { append([event]) }
  }

  func stop() {
    stopTail()
    transcript = nil
  }

  private func stopTail() {
    generation += 1
    tail?.stop()
    tail = nil
  }

  private func append(_ events: [MirrorConversationEvent]) {
    let assigned = log.append(contentsOf: events)
    onEvents?(assigned)
  }
}
