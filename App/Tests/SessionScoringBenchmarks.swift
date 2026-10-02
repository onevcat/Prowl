import Foundation
import Testing

@testable import supacode

extension PerformanceBenchmarks {
  /// Pins the #650/#657 fragment cache: a poll whose transcript tails are
  /// unchanged must not pay tail reads, JSON parsing, and normalization again.
  /// Cold rounds rebuild a fresh `TranscriptFragmentCache` per call — the
  /// pre-#650 per-poll cost — while warm rounds reuse one cache the way
  /// `AgentSessionResolver` does across its 300 ms polls.
  @Suite
  struct SessionScoringBenchmarks {
    @Test func warmFragmentCacheOutpacesColdReparsingPerPoll() throws {
      let fileManager = FileManager.default
      let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? fileManager.removeItem(at: tempRoot) }
      try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)

      let marker = "the quick brown benchmark fox jumps over the lazy resolver dog"
      let sessionCount = 6
      let linesPerTranscript = BenchmarkMeasurement.isFullMode ? 400 : 100
      var candidates: [AgentSessionCandidate] = []
      for sessionIndex in 0..<sessionCount {
        let url = tempRoot.appending(path: "session\(sessionIndex).jsonl")
        var lines: [String] = []
        for lineIndex in 0..<linesPerTranscript {
          lines.append(#"{"content": "セッション\#(sessionIndex)の本文テキスト行\#(lineIndex)、画面には現れない内容です。"}"#)
        }
        if sessionIndex == 0 {
          lines.append(#"{"content": "\#(marker)"}"#)
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        let modifiedAt =
          (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .now
        candidates.append(
          AgentSessionCandidate(
            session: AgentSession(id: "session\(sessionIndex)", transcriptPath: url, source: .recentFile),
            modifiedAt: modifiedAt
          )
        )
      }
      let activeText = "  \(marker)  \n prompt>"

      var coldCache = TranscriptFragmentCache()
      let coldWinner = AgentSessionFingerprintMatcher.bestMatch(
        activeText: activeText,
        candidates: candidates,
        fragments: &coldCache
      )
      let warmBox = FragmentCacheBox()
      let warmWinner = AgentSessionFingerprintMatcher.bestMatch(
        activeText: activeText,
        candidates: candidates,
        fragments: &warmBox.cache
      )
      #expect(coldWinner?.session.id == "session0")
      #expect(warmWinner?.session.id == coldWinner?.session.id)

      let medians = BenchmarkMeasurement.interleavedMedians(
        reference: {
          var cache = TranscriptFragmentCache()
          _ = AgentSessionFingerprintMatcher.bestMatch(
            activeText: activeText,
            candidates: candidates,
            fragments: &cache
          )
        },
        shipped: {
          _ = AgentSessionFingerprintMatcher.bestMatch(
            activeText: activeText,
            candidates: candidates,
            fragments: &warmBox.cache
          )
        }
      )
      BenchmarkMeasurement.report(suite: "SessionScoring", name: "warm-vs-cold", medians: medians)
      #expect(
        BenchmarkMeasurement.ratio(medians) >= 3,
        "warm fragment cache was only \(BenchmarkMeasurement.ratio(medians))x cold re-parsing"
      )
    }
  }
}

/// `bestMatch` takes the cache `inout`; a closure cannot capture `inout` state,
/// so the warm cache lives in a reference box instead.
private final class FragmentCacheBox {
  var cache = TranscriptFragmentCache()
}
