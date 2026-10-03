import Foundation
import Sentry

/// Monitors process memory footprint over the app's lifetime and emits exactly
/// these analytics events per session:
///
/// - `app_memory_baseline` fires once, `baselineDelay` seconds after start,
///   establishing the steady-state working set for this launch.
/// - `memory_threshold_<N>mb` fires at most once per threshold per session
///   when phys_footprint first crosses N. 4GB+ additionally surfaces a Sentry
///   event so dashboards pair the spike with breadcrumbs/context.
///
/// Noise-controlled by design — long-lived sessions with stable memory emit
/// exactly one event (the baseline); only genuine growth produces more.
@MainActor
@Observable
final class MemoryWatchdog {
  struct Context: Sendable, Equatable {
    let repositoryCount: Int
    let openedWorktreeCount: Int
    let terminalTabCount: Int
  }

  typealias AnalyticsCapture = @Sendable (_ event: String, _ properties: [String: Any]?) -> Void
  typealias SentryCapture = @Sendable (_ message: String) -> Void

  private let probe: @Sendable () -> Int
  private let clock: @Sendable () -> Date
  private let tickInterval: TimeInterval
  private let baselineDelay: TimeInterval
  private let thresholdsMB: [Int]
  private let sentryThresholdMB: Int
  private let analyticsCapture: AnalyticsCapture
  private let sentryCapture: SentryCapture
  private let contextProvider: @MainActor () -> Context

  private let startedAt: Date
  private(set) var baselineMB: Int?
  private(set) var firedThresholds: Set<Int> = []
  private var tickTask: Task<Void, Never>?

  init(
    probe: @escaping @Sendable () -> Int = MemoryProbe.physFootprintMegabytes,
    clock: @escaping @Sendable () -> Date = Date.init,
    tickInterval: TimeInterval = 300,
    baselineDelay: TimeInterval = 180,
    thresholdsMB: [Int] = [2048, 4096, 8192],
    sentryThresholdMB: Int = 4096,
    analyticsCapture: @escaping AnalyticsCapture,
    sentryCapture: @escaping SentryCapture = { SentrySDK.capture(message: $0) },
    contextProvider: @escaping @MainActor () -> Context
  ) {
    self.probe = probe
    self.clock = clock
    self.tickInterval = tickInterval
    self.baselineDelay = baselineDelay
    self.thresholdsMB = thresholdsMB.sorted()
    self.sentryThresholdMB = sentryThresholdMB
    self.analyticsCapture = analyticsCapture
    self.sentryCapture = sentryCapture
    self.contextProvider = contextProvider
    self.startedAt = clock()
  }

  /// Begins periodic ticking on a background Task. Safe to call more than once.
  func start() {
    tickTask?.cancel()
    let interval = tickInterval
    tickTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(interval))
        guard !Task.isCancelled else { return }
        self?.tick()
      }
    }
  }

  func stop() {
    tickTask?.cancel()
    tickTask = nil
  }

  /// One monitoring pass. Exposed for tests; `start()` drives it on a schedule.
  func tick() {
    let now = clock()
    let currentMB = probe()
    let uptime = now.timeIntervalSince(startedAt)

    if baselineMB == nil, uptime >= baselineDelay {
      baselineMB = currentMB
      let ctx = contextProvider()
      analyticsCapture("app_memory_baseline", baselineProperties(currentMB: currentMB, uptime: uptime, context: ctx))
    }

    guard let baseline = baselineMB else { return }

    for threshold in thresholdsMB where currentMB >= threshold && !firedThresholds.contains(threshold) {
      firedThresholds.insert(threshold)
      let ctx = contextProvider()
      let props = thresholdProperties(
        currentMB: currentMB,
        baselineMB: baseline,
        uptime: uptime,
        context: ctx
      )
      analyticsCapture("memory_threshold_\(threshold)mb", props)
      if threshold >= sentryThresholdMB {
        sentryCapture(
          "Memory threshold \(threshold) MB crossed (current=\(currentMB)MB, baseline=\(baseline)MB)"
        )
      }
    }
  }

  private func baselineProperties(currentMB: Int, uptime: TimeInterval, context: Context) -> [String: Any] {
    [
      "resident_mb": currentMB,
      "uptime_seconds": Int(uptime),
      "repository_count": context.repositoryCount,
      "opened_worktree_count": context.openedWorktreeCount,
      "terminal_tab_count": context.terminalTabCount,
    ]
  }

  private func thresholdProperties(
    currentMB: Int,
    baselineMB: Int,
    uptime: TimeInterval,
    context: Context
  ) -> [String: Any] {
    let growth = baselineMB > 0 ? (Double(currentMB) / Double(baselineMB)) : 0
    return [
      "resident_mb": currentMB,
      "baseline_mb": baselineMB,
      "growth_ratio": (growth * 100).rounded() / 100,
      "uptime_seconds": Int(uptime),
      "repository_count": context.repositoryCount,
      "opened_worktree_count": context.openedWorktreeCount,
      "terminal_tab_count": context.terminalTabCount,
    ]
  }
}
