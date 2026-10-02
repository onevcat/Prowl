import Testing

@testable import supacode

extension PerformanceBenchmarks {
  /// Tracks absolute changed-screen classification cost over the same sanitized
  /// Claude/Codex capture corpus used by the end-to-end regression test.
  @Suite
  struct ScreenHeuristicsBenchmarks {
    @Test func capturedCorpusChangedFrameCost() throws {
      let fixtures = try Self.loadFixtures()
      let repeats = BenchmarkMeasurement.isFullMode ? 20 : 2
      var checksum = 0

      let median = BenchmarkMeasurement.repeatedMedian {
        var iterationChecksum = 0
        for _ in 0..<repeats {
          for fixture in fixtures {
            iterationChecksum &+= fixture.agent.detectState(in: fixture.text).rawValue.utf8.count
          }
        }
        checksum &+= iterationChecksum
      }

      #expect(checksum > 0)
      BenchmarkMeasurement.reportAbsolute(
        suite: "ScreenHeuristics",
        name: "captured-claude-codex-corpus",
        median: median,
        normalizingBy: repeats
      )
    }

    private static func loadFixtures() throws -> [(agent: DetectedAgent, text: String)] {
      try AgentScreenFixtureCorpus.load().map { ($0.agent, $0.text) }
    }
  }
}
