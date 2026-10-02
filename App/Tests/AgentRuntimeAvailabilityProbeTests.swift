import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import supacode

@Suite(.serialized)
@MainActor
struct AgentRuntimeAvailabilityProbeTests {
  @Test(.dependencies) func refreshBatchesAllPendingRuntimesInOneLoginShell() async {
    let probeCalls = LockIsolated(0)
    await withDependencies {
      $0.date.now = Date(timeIntervalSince1970: 1_000)
      $0.shellClient = shellClient(probeCalls: probeCalls, available: [.codex])
    } operation: {
      @Shared(.agentRuntimeAvailabilityProbeResults) var probeResults
      $probeResults.withLock { $0 = [:] }

      await AgentRuntimeAvailabilityProbe.refresh()

      #expect(probeCalls.value == 1)
      #expect(probeResults[.codex]?.isAvailable == true)
      #expect(probeResults[.claude]?.isAvailable == false)
    }
  }

  @Test(.dependencies) func refreshCachesNegativeAnswersUntilTheirTTLExpires() async {
    let probeCalls = LockIsolated(0)
    let now = LockIsolated(Date(timeIntervalSince1970: 1_000))
    await withDependencies {
      $0.date = DateGenerator { now.value }
      $0.shellClient = shellClient(probeCalls: probeCalls, available: [.codex])
    } operation: {
      @Shared(.agentRuntimeAvailabilityProbeResults) var probeResults
      $probeResults.withLock { $0 = [:] }

      await AgentRuntimeAvailabilityProbe.refresh()
      #expect(probeCalls.value == 1)

      now.setValue(Date(timeIntervalSince1970: 1_299))
      await AgentRuntimeAvailabilityProbe.refresh()
      #expect(probeCalls.value == 1)

      now.setValue(Date(timeIntervalSince1970: 1_300))
      await AgentRuntimeAvailabilityProbe.refresh()
      #expect(probeCalls.value == 2)
      #expect(probeResults[.codex]?.isAvailable == true)
      #expect(probeResults[.codex]?.checkedAt == Date(timeIntervalSince1970: 1_000))
      #expect(probeResults[.claude]?.isAvailable == false)
      #expect(probeResults[.claude]?.checkedAt == Date(timeIntervalSince1970: 1_300))
    }
  }

  @Test(.dependencies) func refreshLeavesAnIncompleteBatchUnanswered() async {
    let probeCalls = LockIsolated(0)
    await withDependencies {
      $0.date.now = Date(timeIntervalSince1970: 1_000)
      $0.shellClient = ShellClient(
        run: { _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
        runLoginImpl: { _, _, _, _ in
          probeCalls.withValue { $0 += 1 }
          return ShellOutput(
            stdout: "\(Self.outputMarker):codex:1",
            stderr: "",
            exitCode: 0
          )
        }
      )
    } operation: {
      @Shared(.agentRuntimeAvailabilityProbeResults) var probeResults
      $probeResults.withLock { $0 = [:] }

      await AgentRuntimeAvailabilityProbe.refresh()

      #expect(probeCalls.value == 1)
      #expect(probeResults.isEmpty)
    }
  }

  @Test(.dependencies) func refreshLeavesFailedBatchUnansweredAndSkipsPositives() async {
    let probeCalls = LockIsolated(0)
    await withDependencies {
      $0.date.now = Date(timeIntervalSince1970: 1_000)
      $0.shellClient = ShellClient(
        run: { _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
        runLoginImpl: { _, _, _, _ in
          probeCalls.withValue { $0 += 1 }
          // A spawn-level failure must not masquerade as "not installed".
          throw CocoaError(.fileNoSuchFile)
        }
      )
    } operation: {
      @Shared(.agentRuntimeAvailabilityProbeResults) var probeResults
      $probeResults.withLock {
        $0 = [
          .codex: AgentRuntimeAvailabilityProbeResult(
            isAvailable: true,
            checkedAt: Date(timeIntervalSince1970: 1_000)
          )
        ]
      }

      await AgentRuntimeAvailabilityProbe.refresh()

      #expect(probeCalls.value == 1)
      #expect(probeResults[.codex]?.isAvailable == true)
      #expect(probeResults[.claude] == nil)
    }
  }

  private func shellClient(
    probeCalls: LockIsolated<Int>,
    available: Set<AgentProfileRuntime>
  ) -> ShellClient {
    ShellClient(
      run: { _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runLoginImpl: { _, arguments, _, _ in
        probeCalls.withValue { $0 += 1 }
        let command = arguments.joined(separator: " ")
        if command.contains(Self.outputMarker) {
          return ShellOutput(
            stdout: Self.probeOutput(for: command, available: available),
            stderr: "",
            exitCode: 0
          )
        }

        // Compatibility with the pre-batching implementation keeps this a
        // behavioral RED test instead of a test that only fails to compile.
        if let runtime = AgentProfileRuntime.allCases.first(where: {
          command.contains("'\($0.rawValue)'")
        }), available.contains(runtime) {
          return ShellOutput(stdout: "/usr/local/bin/\(runtime.rawValue)", stderr: "", exitCode: 0)
        }
        throw ShellClientError(command: command, stdout: "", stderr: "", exitCode: 1)
      }
    )
  }

  nonisolated private static let outputMarker = "__PROWL_AGENT_RUNTIME_AVAILABILITY__"

  nonisolated private static func probeOutput(
    for command: String,
    available: Set<AgentProfileRuntime>
  ) -> String {
    AgentProfileRuntime.allCases.filter { runtime in
      command.contains("\(outputMarker):\(runtime.rawValue):")
    }.map { runtime in
      "\(outputMarker):\(runtime.rawValue):\(available.contains(runtime) ? 1 : 0)"
    }.joined(separator: "\n")
  }
}
