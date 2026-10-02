import Foundation
import Testing

@testable import supacode

extension PerformanceBenchmarks {
  /// Pins the #650/#657 escape-absence guard: nearly every transcript fragment
  /// holds no ESC byte, so proving absence with a byte scan must stay cheaper
  /// than letting the regex engine walk the whole string to conclude nothing.
  ///
  /// The corpus mirrors the measured workload shape from docs-ai/032.004 —
  /// mostly non-ASCII bytes, a small minority of fragments carrying escapes —
  /// which is also why no separate ASCII-fast-path ratio is asserted: on this
  /// byte mix its measured gain is marginal, and the equivalence tests in
  /// `AgentSessionFingerprintNormalizeTests` already pin its semantics.
  @Suite
  struct FingerprintNormalizeBenchmarks {
    /// Optimized builds only: under `-Onone` the guard's own byte scan is an
    /// unspecialized `Sequence.contains` and its advantage over the regex
    /// collapses to ~1.13x — see `BenchmarkMeasurement.isOptimizedBuild`.
    @Test(.enabled(if: BenchmarkMeasurement.isOptimizedBuild))
    func escapeAbsenceGuardOutpacesTheRegexOnlyFormulation() {
      let corpus = Self.corpus()

      for fragment in corpus {
        #expect(AgentSessionFingerprintMatcher.normalize(fragment) == Self.referenceNormalize(fragment))
      }

      let medians = BenchmarkMeasurement.interleavedMedians(
        reference: {
          for fragment in corpus { _ = Self.referenceNormalize(fragment) }
        },
        shipped: {
          for fragment in corpus { _ = AgentSessionFingerprintMatcher.normalize(fragment) }
        }
      )
      BenchmarkMeasurement.report(suite: "FingerprintNormalize", name: "mixed-corpus", medians: medians)
      #expect(
        BenchmarkMeasurement.ratio(medians) >= 1.3,
        "shipped normalize was only \(BenchmarkMeasurement.ratio(medians))x the regex-only formulation"
      )
    }

    /// The pre-#650 formulation: the escape-stripping regex runs whether or not
    /// an ESC byte exists. Kept verbatim so the benchmark measures exactly the
    /// path the guard replaced.
    private static func referenceNormalize(_ value: String) -> String {
      value
        .replacing(#/\u{001B}\[[0-?]*[ -\/]*[@-~]/#, with: " ")
        .lowercased()
        .split(whereSeparator: \Character.isWhitespace)
        .joined(separator: " ")
    }

    /// 240 fragments, ~80% non-ASCII bytes, 2 carrying real CSI sequences —
    /// the "238 of 240 fragments contained no ESC" shape the guard was built
    /// for. Deterministic so every run measures the same bytes.
    private static func corpus() -> [String] {
      let fragmentCount = BenchmarkMeasurement.isFullMode ? 240 : 60
      let cjkLine = "エージェントが長い応答を生成しています。コードの説明と修正の提案を含む本文のテキストです。"
      let asciiLine = "The agent produced MIXED Case output with    collapsing\twhitespace and code: let x = f(y)"
      var fragments: [String] = []
      for index in 0..<fragmentCount {
        var fragment = ""
        for line in 0..<20 {
          fragment += (line % 4 == 3) ? asciiLine : cjkLine
          fragment += "\n"
        }
        if index < 2 {
          fragment = "\u{001B}[1;31m" + fragment + "\u{001B}[0m"
        }
        fragments.append(fragment)
      }
      return fragments
    }
  }
}
