import Foundation
import Testing

@testable import supacode

/// Fingerprint matching re-reads the same transcript tails every time a pane's
/// session cache expires. `TranscriptFragmentCache` replays the parsed result
/// for unchanged files; these tests pin both the reuse and the bounding.
struct TranscriptFragmentCacheTests {
  private func key(_ path: String, _ secondsSinceEpoch: TimeInterval) -> TranscriptFragmentCache.Key {
    TranscriptFragmentCache.Key(path: path, modifiedAt: Date(timeIntervalSince1970: secondsSinceEpoch))
  }

  @Test func reusesFragmentsForAnUnchangedFile() {
    var cache = TranscriptFragmentCache()
    var loads = 0
    let target = key("/tmp/a.jsonl", 100)

    let first = cache.fragments(for: target) {
      loads += 1
      return [.init(text: "parsed fragment")]
    }
    let second = cache.fragments(for: target) {
      loads += 1
      return [.init(text: "should not be reached")]
    }

    #expect(loads == 1)
    #expect(first?.map(\.text) == ["parsed fragment"])
    #expect(second?.map(\.text) == ["parsed fragment"])
  }

  @Test func reloadsWhenTheFileIsAppendedTo() {
    var cache = TranscriptFragmentCache()
    var loads = 0

    _ = cache.fragments(for: key("/tmp/a.jsonl", 100)) {
      loads += 1
      return [.init(text: "old")]
    }
    let updated = cache.fragments(for: key("/tmp/a.jsonl", 101)) {
      loads += 1
      return [.init(text: "new")]
    }

    #expect(loads == 2)
    #expect(updated?.map(\.text) == ["new"])
  }

  @Test func doesNotCacheAnUnreadableTail() {
    var cache = TranscriptFragmentCache()
    var loads = 0
    let target = key("/tmp/gone.jsonl", 100)

    let missing = cache.fragments(for: target) {
      loads += 1
      return nil
    }
    let recovered = cache.fragments(for: target) {
      loads += 1
      return [.init(text: "now readable")]
    }

    // Caching the failure would keep a briefly unreadable transcript excluded
    // from every later match.
    #expect(loads == 2)
    #expect(missing == nil)
    #expect(recovered?.map(\.text) == ["now readable"])
  }

  @Test func replacesAnOlderVersionOfTheSamePathImmediately() {
    var cache = TranscriptFragmentCache()
    _ = cache.fragments(for: key("/tmp/busy.jsonl", 100)) { [.init(text: "v1")] }
    _ = cache.fragments(for: key("/tmp/busy.jsonl", 101)) { [.init(text: "v2")] }

    #expect(cache.count == 1)
  }

  @Test func dropsAnOlderVersionWhenLoadingTheNewVersionFails() {
    var cache = TranscriptFragmentCache()
    _ = cache.fragments(for: key("/tmp/busy.jsonl", 100)) { [.init(text: "v1")] }

    #expect(cache.fragments(for: key("/tmp/busy.jsonl", 101)) { nil } == nil)
    #expect(cache.count == 0)
  }

  @Test func evictsTheLeastRecentlyUsedEntryAtCapacity() {
    var cache = TranscriptFragmentCache(maxEntryCount: 2, maxRetainedUTF8Bytes: .max)
    let first = key("/tmp/first.jsonl", 100)
    let second = key("/tmp/second.jsonl", 100)
    let third = key("/tmp/third.jsonl", 100)
    _ = cache.fragments(for: first) { [.init(text: "first")] }
    _ = cache.fragments(for: second) { [.init(text: "second")] }
    _ = cache.fragments(for: first) { [.init(text: "not reached")] }
    _ = cache.fragments(for: third) { [.init(text: "third")] }

    var firstReloads = 0
    _ = cache.fragments(for: first) {
      firstReloads += 1
      return [.init(text: "first reloaded")]
    }
    var secondReloads = 0
    _ = cache.fragments(for: second) {
      secondReloads += 1
      return [.init(text: "second reloaded")]
    }

    #expect(firstReloads == 0, "A cache hit must make the entry most recently used")
    #expect(secondReloads == 1, "The least recently used entry must be evicted first")
  }

  @Test func doesNotRetainAnEntryLargerThanTheByteBudget() {
    var cache = TranscriptFragmentCache(maxEntryCount: 10, maxRetainedUTF8Bytes: 3)
    let target = key("/tmp/large.jsonl", 100)
    var loads = 0

    for _ in 0..<2 {
      _ = cache.fragments(for: target) {
        loads += 1
        return [.init(text: "four")]
      }
    }

    #expect(loads == 2)
    #expect(cache.count == 0)
  }

  @Test func byteBudgetEvictsTheLeastRecentlyUsedEntry() {
    var cache = TranscriptFragmentCache(maxEntryCount: 10, maxRetainedUTF8Bytes: 10)
    let first = key("a", 100)
    let second = key("b", 100)
    let third = key("c", 100)
    _ = cache.fragments(for: first) { [.init(text: "1234")] }
    _ = cache.fragments(for: second) { [.init(text: "1234")] }
    _ = cache.fragments(for: first) { [.init(text: "not reached")] }
    _ = cache.fragments(for: third) { [.init(text: "1234")] }

    var firstReloads = 0
    _ = cache.fragments(for: first) {
      firstReloads += 1
      return [.init(text: "1234")]
    }
    var secondReloads = 0
    _ = cache.fragments(for: second) {
      secondReloads += 1
      return [.init(text: "1234")]
    }

    #expect(firstReloads == 0)
    #expect(secondReloads == 1)
  }

  @Test func fragmentPrecomputesCountAndOnlyASuffixWorthTesting() {
    let short = TranscriptFragmentCache.Fragment(text: String(repeating: "a", count: 80))
    #expect(short.characterCount == 80)
    // At or below the window the suffix would equal the whole fragment, so the
    // scoring loop must not be handed a second, identical search to run.
    #expect(short.suffix == nil)

    let long = TranscriptFragmentCache.Fragment(text: String(repeating: "b", count: 81))
    #expect(long.characterCount == 81)
    #expect(long.suffix?.count == 80)

    // `characterCount` must be the grapheme count `String.count` reports, not a
    // byte or scalar count, because the score derives from it.
    let emoji = TranscriptFragmentCache.Fragment(text: "e\u{0301}moji 👩‍👩‍👧‍👦 test")
    #expect(emoji.characterCount == emoji.text.count)
  }

  @Test func bestMatchServesASecondCallFromTheCache() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "prowl-fragment-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let firstURL = root.appending(path: "first.jsonl")
    let secondURL = root.appending(path: "second.jsonl")
    try #"{"type":"user","message":{"content":"Refactor authentication middleware without changing its API."}}"#
      .write(to: firstURL, atomically: true, encoding: .utf8)
    try #"{"type":"user","message":{"content":"Investigate the unrelated rendering regression."}}"#
      .write(to: secondURL, atomically: true, encoding: .utf8)

    let modifiedAt = Date(timeIntervalSince1970: 1_000)
    let candidates = [
      AgentSessionCandidate(
        session: AgentSession(id: "first", transcriptPath: firstURL, source: .recentFile),
        modifiedAt: modifiedAt
      ),
      AgentSessionCandidate(
        session: AgentSession(id: "second", transcriptPath: secondURL, source: .recentFile),
        modifiedAt: modifiedAt
      ),
    ]
    let activeText = "❯ Refactor authentication middleware without changing its API."

    var cache = TranscriptFragmentCache()
    let first = AgentSessionFingerprintMatcher.bestMatch(
      activeText: activeText,
      candidates: candidates,
      fragments: &cache
    )
    #expect(first?.session.id == "first")

    // Deleting the transcripts makes a re-read impossible, so a second match on
    // the same keys can only succeed by replaying the cached fragments.
    try FileManager.default.removeItem(at: firstURL)
    try FileManager.default.removeItem(at: secondURL)

    let cached = AgentSessionFingerprintMatcher.bestMatch(
      activeText: activeText,
      candidates: candidates,
      fragments: &cache
    )
    #expect(cached?.session.id == "first")

    // A cacheless call over the same candidates now has nothing to read, which
    // confirms the previous call really was served from the cache.
    #expect(AgentSessionFingerprintMatcher.bestMatch(activeText: activeText, candidates: candidates) == nil)
  }
}
