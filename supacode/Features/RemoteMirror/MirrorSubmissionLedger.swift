import CryptoKit
import Foundation

/// A bounded receipt cache stores hashes, never prompts. A missing receipt means
/// unknown; it is not permission to repeat a delivery after disconnecting.
nonisolated struct MirrorSubmissionLedger {
  struct Key: Hashable, Sendable {
    let run: UUID
    let pane: UUID
    let generation: UUID
    let submission: UUID
  }
  enum Reservation {
    case reserved
    case existing(MirrorSubmitOutcome)
    case refused(String)
  }
  private struct Entry {
    let hash: SHA256.Digest
    var outcome: MirrorSubmitOutcome
  }
  private var entries: [Key: Entry] = [:]
  private var order: [Key] = []
  private let capacity: Int
  init(capacity: Int = 256) { self.capacity = max(1, capacity) }

  mutating func reserve(_ key: Key, text: String) -> Reservation {
    let hash = SHA256.hash(data: Data(text.utf8))
    if let entry = entries[key] {
      guard entry.hash == hash else { return .refused("Submission ID was already used for different text.") }
      return .existing(entry.outcome)
    }
    guard Self.validText(text) else {
      return .refused("Use nonempty text up to 64 KiB without terminal control characters.")
    }
    let pending = entries.filter { $0.value.outcome.status == .pending }
    guard pending.count < 16, !pending.contains(where: { $0.key.pane == key.pane }) else {
      return .refused("A submission is already awaiting confirmation.")
    }
    if entries.count >= capacity {
      guard let index = order.firstIndex(where: { entries[$0]?.outcome.status != .pending }) else {
        return .refused("Submission receipt capacity is full.")
      }
      entries.removeValue(forKey: order.remove(at: index))
    }
    entries[key] = Entry(hash: hash, outcome: .init(status: .pending, detail: "Delivery is pending."))
    order.append(key)
    return .reserved
  }

  mutating func finish(_ key: Key, outcome: MirrorSubmitOutcome) {
    guard entries[key]?.outcome.status == .pending, outcome.status != .pending else { return }
    entries[key]?.outcome = outcome
  }

  func receipt(_ key: Key) -> MirrorSubmitOutcome {
    entries[key]?.outcome
      ?? .init(status: .unknown, detail: "No retained receipt. Check the Host before sending again.")
  }

  static func validText(_ text: String) -> Bool {
    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && text.utf8.count <= MirrorWire.maximumInput
      && text.unicodeScalars.allSatisfy {
        $0.value == 10 || $0.value == 9 || ($0.value >= 32 && !(127...159).contains($0.value))
      }
  }
}
