import Foundation

/// One OSC 7501 record as the terminal keeps it (docs-ai 079).
nonisolated struct ProgramStatusRecord: Equatable, Sendable {
  /// A record's state; `clear` is a command on the store, never a stored state.
  enum State: String, Equatable, Sendable {
    case idle
    case working
    case done
    case blocked
    case error
  }

  /// Empty for the root record; `/` nests records, so `build/test` is a child of `build`.
  let id: String
  let state: State
  /// Only kept for `.blocked`.
  let kind: GhosttyProgramStatusReport.Kind?
  let progress: Int?
  /// As reported. A record without one inherits the nearest ancestor's, see
  /// `ProgramStatusRecordStore.app(of:)`.
  let app: String?
  let title: String?
  let message: String?
  /// The store revision that applied this report.
  let revision: UInt64
  /// Wall-clock arrival of the report at the action callback; the attribution fence
  /// compares it with the detected process's start time.
  let arrivedAt: Date

  var isRoot: Bool { id.isEmpty }

  fileprivate init(_ report: GhosttyProgramStatusReport, state: State, revision: UInt64, arrivedAt: Date) {
    id = report.id
    self.state = state
    kind = state == .blocked ? report.kind : nil
    progress = report.progress
    app = report.app
    title = report.title
    message = report.message
    self.revision = revision
    self.arrivedAt = arrivedAt
  }
}

/// The record tree of one surface: the protocol's lifetime rules (whole-record
/// replacement, subtree `clear`, `app` inheritance, least-recently-updated eviction)
/// plus a monotonic revision and per-record arrival time. Pure; the terminal owner
/// holds one per surface because reports can arrive before a process is bound and
/// because records belong to the terminal, not to a process.
nonisolated struct ProgramStatusRecordStore: Equatable, Sendable {
  /// The protocol's upper bound; terminals must keep at least 64.
  static let capacity = 256

  /// Advances on every applied report and on a `commandFinished` that removed a record.
  private(set) var revision: UInt64 = 0
  private(set) var records: [String: ProgramStatusRecord] = [:]
  /// Least recently updated first.
  private var recency: [String] = []

  init() {}

  var root: ProgramStatusRecord? { records[""] }

  /// Every record except the root, ordered by id for deterministic consumers.
  var children: [ProgramStatusRecord] {
    records.values.filter { !$0.isRoot }.sorted { $0.id < $1.id }
  }

  func record(id: String) -> ProgramStatusRecord? { records[id] }

  /// The record's own `app`, else the nearest ancestor's. The root is every record's
  /// ultimate ancestor; a missing intermediate parent is skipped.
  func app(of record: ProgramStatusRecord) -> String? {
    if let app = record.app { return app }
    var id = Substring(record.id)
    while let slash = id.lastIndex(of: "/") {
      id = id[..<slash]
      if let app = records[String(id)]?.app { return app }
    }
    return record.isRoot ? nil : records[""]?.app
  }

  mutating func apply(_ report: GhosttyProgramStatusReport, arrivedAt: Date) {
    revision &+= 1
    guard let state = ProgramStatusRecord.State(report.state) else {
      clear(id: report.id)
      return
    }
    if records[report.id] == nil, records.count >= Self.capacity, let evicted = recency.first {
      recency.removeFirst()
      records.removeValue(forKey: evicted)
    }
    records[report.id] = ProgramStatusRecord(report, state: state, revision: revision, arrivedAt: arrivedAt)
    recency.removeAll { $0 == report.id }
    recency.append(report.id)
  }

  /// A new shell prompt: drops the `working` and `blocked` records that existed when
  /// the command finished (`revision` captured at the 133 D) and keeps `idle`,
  /// `done`, and `error`. Anything a successor reported after the mark stays. Returns
  /// whether a record was removed.
  @discardableResult
  mutating func commandFinished(upTo mark: UInt64) -> Bool {
    let doomed = records.values.filter {
      ($0.state == .working || $0.state == .blocked) && $0.revision <= mark
    }
    guard !doomed.isEmpty else { return false }
    remove(Set(doomed.map(\.id)))
    revision &+= 1
    return true
  }

  private mutating func clear(id: String) {
    guard !id.isEmpty else {
      records.removeAll()
      recency.removeAll()
      return
    }
    let prefix = id + "/"
    remove(Set(records.keys.filter { $0 == id || $0.hasPrefix(prefix) }))
  }

  private mutating func remove(_ ids: Set<String>) {
    for id in ids { records.removeValue(forKey: id) }
    recency.removeAll { ids.contains($0) }
  }
}

extension ProgramStatusRecord.State {
  /// `nil` for `clear`, which is a command on the store rather than a state.
  nonisolated init?(_ state: GhosttyProgramStatusReport.State) {
    switch state {
    case .idle: self = .idle
    case .working: self = .working
    case .done: self = .done
    case .blocked: self = .blocked
    case .error: self = .error
    case .clear: return nil
    }
  }
}
