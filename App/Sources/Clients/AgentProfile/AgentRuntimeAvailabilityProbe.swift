import Dependencies
import Foundation
import Sharing

nonisolated struct AgentRuntimeAvailabilityProbeResult: Equatable, Sendable {
  let isAvailable: Bool
  let checkedAt: Date
}

extension SharedReaderKey
where Self == InMemoryKey<[AgentProfileRuntime: AgentRuntimeAvailabilityProbeResult]>.Default {
  /// Session cache of the login-shell executable probe. A missing entry means
  /// the probe has not answered for that runtime yet this session.
  static var agentRuntimeAvailabilityProbeResults: Self {
    Self[.inMemory("agentRuntimeAvailabilityProbeResults"), default: [:]]
  }
}

extension AgentProfileAvailability {
  /// The launcher surfaces' judgment: the session probe cache first, the
  /// home-directory heuristic while a runtime is unanswered.
  @MainActor
  static func launchWarning(for profile: AgentProfile) -> String? {
    @Shared(.agentRuntimeAvailabilityProbeResults) var probeResults
    return launchWarning(
      for: profile,
      probedAvailable: probeResults[profile.runtime]?.isAvailable
    )
  }
}

/// Resolves runtime executables through the user's login shell — the same
/// resolution a profile launch uses, so a positive answer means the launch
/// will find the binary (docs-ai 053/005). A GUI app's own PATH is the launchd
/// default and useless for this; the login shell's rc-built PATH is the truth.
///
/// One refresh batches every pending `command -v` into a single login shell.
/// Positive answers are final for the app session. Negative answers have a
/// short TTL so a newly installed CLI becomes visible without paying login-rc
/// startup cost every time the Agents popover opens.
@MainActor
enum AgentRuntimeAvailabilityProbe {
  static let negativeResultLifetime: TimeInterval = 5 * 60

  private static let outputMarker = "__PROWL_AGENT_RUNTIME_AVAILABILITY__"
  private static var inFlightRefresh: Task<Void, Never>?

  static func refresh() async {
    if let inFlightRefresh {
      await inFlightRefresh.value
      return
    }

    let task = Task { await performRefresh() }
    inFlightRefresh = task
    await task.value
    inFlightRefresh = nil
  }

  private static func performRefresh() async {
    @Dependency(\.date.now) var now
    @Shared(.agentRuntimeAvailabilityProbeResults) var probeResults
    let checkedAt = now
    let pending = AgentProfileRuntime.allCases.filter { runtime in
      guard let result = probeResults[runtime] else { return true }
      guard !result.isAvailable else { return false }
      return checkedAt.timeIntervalSince(result.checkedAt) >= negativeResultLifetime
    }
    guard !pending.isEmpty, let answers = await probeAvailability(of: pending) else { return }

    $probeResults.withLock { results in
      for (runtime, isAvailable) in answers {
        results[runtime] = AgentRuntimeAvailabilityProbeResult(
          isAvailable: isAvailable,
          checkedAt: checkedAt
        )
      }
    }
  }

  /// Returns the complete set of login-shell answers, or nil when the probe
  /// itself could not run or returned malformed output. An incomplete batch
  /// must remain unanswered rather than masquerading as "not installed".
  private static func probeAvailability(
    of runtimes: [AgentProfileRuntime]
  ) async -> [AgentProfileRuntime: Bool]? {
    let probes = runtimes.compactMap { runtime -> (runtime: AgentProfileRuntime, executable: String)? in
      guard
        let executable = try? AgentRuntimeAdapterRegistry.makeStartInvocation(
          AgentStartRequest(runtime: runtime, intent: .interactive)
        ).executable
      else { return nil }
      return (runtime, executable)
    }
    guard !probes.isEmpty else { return [:] }

    let script = probes.map { probe in
      let executable = AgentInvocation.shellQuote(probe.executable)
      let available = AgentInvocation.shellQuote("\(outputMarker):\(probe.runtime.rawValue):1")
      let unavailable = AgentInvocation.shellQuote("\(outputMarker):\(probe.runtime.rawValue):0")
      return """
        if command -v -- \(executable) >/dev/null 2>&1; then
          printf '%s\\n' \(available)
        else
          printf '%s\\n' \(unavailable)
        fi
        """
    }.joined(separator: "\n")

    @Dependency(ShellClient.self) var shell
    guard
      let output = try? await shell.runLogin(
        URL(fileURLWithPath: "/bin/sh"),
        ["-c", script],
        nil,
        log: false
      )
    else { return nil }

    var answers: [AgentProfileRuntime: Bool] = [:]
    for line in output.stdout.split(whereSeparator: \.isNewline) {
      let fields = line.split(separator: ":", omittingEmptySubsequences: false)
      guard
        fields.count == 3,
        fields[0] == outputMarker[...],
        let runtime = AgentProfileRuntime(rawValue: String(fields[1]))
      else { continue }
      switch fields[2] {
      case "1": answers[runtime] = true
      case "0": answers[runtime] = false
      default: continue
      }
    }

    let expected = Set(probes.map { $0.runtime })
    guard Set(answers.keys) == expected else { return nil }
    return answers
  }
}
