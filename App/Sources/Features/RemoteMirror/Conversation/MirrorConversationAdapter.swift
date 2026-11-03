import Foundation

/// One decoded JSONL record of an agent's own transcript.
typealias MirrorConversationRecord = [String: Any]

/// Maps one agent's transcript records to conversation events, in file order. Adapters are
/// stateful: they pair tool starts with results and suppress repeated metadata. One adapter
/// instance follows one transcript file; a session change gets a fresh instance.
nonisolated protocol MirrorConversationAdapter {
  var agent: DetectedAgent { get }
  mutating func events(for record: MirrorConversationRecord) -> [MirrorConversationEvent]
  /// Session metadata from one of the file's first records, for a replay window that
  /// started later. Returns nothing for records that do not identify the session.
  mutating func bootstrap(_ record: MirrorConversationRecord) -> [MirrorConversationEvent]
}

extension MirrorBoundedText {
  /// Diffs and added content get twice the output budget.
  nonisolated static let diffLimit = 8 * 1024
}

nonisolated enum MirrorConversationAdapters {
  static func make(for agent: DetectedAgent) -> (any MirrorConversationAdapter)? {
    switch agent {
    case .claude: ClaudeConversationAdapter()
    case .codex: CodexConversationAdapter()
    default: nil
    }
  }

  static func supports(_ agent: DetectedAgent?) -> Bool {
    guard let agent else { return false }
    return make(for: agent) != nil
  }
}

/// Typed reads of untyped JSON records.
nonisolated enum MirrorConversationRecordValue {
  static func string(_ record: MirrorConversationRecord, _ key: String) -> String? {
    record[key] as? String
  }

  static func object(_ record: MirrorConversationRecord, _ key: String) -> MirrorConversationRecord? {
    record[key] as? MirrorConversationRecord
  }

  static func objects(_ record: MirrorConversationRecord, _ key: String) -> [MirrorConversationRecord]? {
    record[key] as? [MirrorConversationRecord]
  }

  static func int(_ record: MirrorConversationRecord, _ key: String) -> Int? {
    guard let number = record[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    return number.intValue
  }

  static func double(_ record: MirrorConversationRecord, _ key: String) -> Double? {
    guard let number = record[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    return number.doubleValue
  }

  static func bool(_ record: MirrorConversationRecord, _ key: String) -> Bool? {
    guard let number = record[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
    return number.boolValue
  }

  static func timestamp(_ record: MirrorConversationRecord, _ key: String = "timestamp") -> Date? {
    guard let raw = record[key] as? String else { return nil }
    return MirrorConversationEvent.parseTimestamp(raw)
  }

  static func epochMilliseconds(_ record: MirrorConversationRecord, _ key: String) -> Date? {
    guard let value = double(record, key) else { return nil }
    return Date(timeIntervalSince1970: value / 1000)
  }

  /// Joins the `text` of block arrays such as `[{"type":"text","text":"…"}]`; image and other
  /// non-text blocks are skipped.
  static func blockText(_ value: Any?) -> String? {
    if let text = value as? String { return text }
    guard let blocks = value as? [MirrorConversationRecord] else { return nil }
    let parts = blocks.compactMap { $0["text"] as? String }
    return parts.isEmpty ? nil : parts.joined(separator: "\n")
  }

  /// Image blocks in a block array (`image`, `local_image`).
  static func imageCount(_ value: Any?) -> Int {
    guard let blocks = value as? [MirrorConversationRecord] else { return 0 }
    return blocks.filter { ($0["type"] as? String).map { $0 == "image" || $0 == "local_image" } ?? false }.count
  }

  /// A short single-line label for a tool card.
  static func title(_ text: String, limit: Int = 120) -> String {
    let firstLine =
      text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
    return String(firstLine.prefix(limit))
  }
}
