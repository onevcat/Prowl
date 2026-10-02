import ConcurrencyExtras
import Foundation
import Testing

@testable import supacode

@MainActor
struct MemoryWatchdogTests {
  @Test func baselineDoesNotFireBeforeDelay() {
    let env = makeEnv(baselineMB: 500)
    env.now.setValue(baseDate.addingTimeInterval(60))
    env.watchdog.tick()
    #expect(env.events.value.isEmpty)
    #expect(env.watchdog.baselineMB == nil)
  }

  @Test func baselineFiresAtDelayAndOnlyOnce() {
    let env = makeEnv(baselineMB: 500)
    env.now.setValue(baseDate.addingTimeInterval(180))
    env.watchdog.tick()
    #expect(env.events.value.count == 1)
    #expect(env.events.value[0].event == "app_memory_baseline")
    #expect(env.events.value[0].residentMB == 500)
    #expect(env.watchdog.baselineMB == 500)

    env.now.setValue(baseDate.addingTimeInterval(600))
    env.watchdog.tick()
    #expect(env.events.value.count == 1, "baseline must not fire twice")
  }

  @Test func thresholdFiresOnceEachAndSentryAtOrAbove4GB() {
    let env = makeEnv(baselineMB: 500)
    env.now.setValue(baseDate.addingTimeInterval(180))
    env.watchdog.tick()

    env.currentMB.setValue(2_500)
    env.now.setValue(baseDate.addingTimeInterval(3_600))
    env.watchdog.tick()
    env.currentMB.setValue(5_000)
    env.now.setValue(baseDate.addingTimeInterval(7_200))
    env.watchdog.tick()
    env.currentMB.setValue(9_000)
    env.now.setValue(baseDate.addingTimeInterval(10_800))
    env.watchdog.tick()

    let thresholdEvents = env.events.value.map(\.event).filter { $0.hasPrefix("memory_threshold_") }
    #expect(thresholdEvents == ["memory_threshold_2048mb", "memory_threshold_4096mb", "memory_threshold_8192mb"])

    env.watchdog.tick()
    let afterReplay = env.events.value.map(\.event).filter { $0.hasPrefix("memory_threshold_") }
    #expect(afterReplay.count == 3, "thresholds must not re-fire")

    #expect(env.sentryMessages.value.count == 2, "Sentry fires for 4GB and 8GB only")
  }

  @Test func droppingBelowThresholdDoesNotRearm() {
    let env = makeEnv(baselineMB: 500)
    env.now.setValue(baseDate.addingTimeInterval(180))
    env.watchdog.tick()

    env.currentMB.setValue(2_500)
    env.now.setValue(baseDate.addingTimeInterval(3_600))
    env.watchdog.tick()
    env.currentMB.setValue(800)
    env.now.setValue(baseDate.addingTimeInterval(7_200))
    env.watchdog.tick()
    env.currentMB.setValue(2_500)
    env.now.setValue(baseDate.addingTimeInterval(10_800))
    env.watchdog.tick()

    let thresholdEvents = env.events.value.map(\.event).filter { $0.hasPrefix("memory_threshold_") }
    #expect(thresholdEvents == ["memory_threshold_2048mb"])
  }

  @Test func thresholdsNeverFireWithoutBaseline() {
    let env = makeEnv(baselineMB: 3_000)
    env.now.setValue(baseDate.addingTimeInterval(30))
    env.watchdog.tick()
    #expect(env.events.value.isEmpty)
    #expect(env.sentryMessages.value.isEmpty)
  }

  @Test func thresholdPropertiesIncludeContextAndGrowthRatio() {
    let env = makeEnv(baselineMB: 500)
    env.now.setValue(baseDate.addingTimeInterval(180))
    env.watchdog.tick()

    env.currentMB.setValue(2_500)
    env.now.setValue(baseDate.addingTimeInterval(3_600))
    env.watchdog.tick()

    let event = env.events.value.last { $0.event == "memory_threshold_2048mb" }
    #expect(event?.residentMB == 2_500)
    #expect(event?.baselineMB == 500)
    #expect(event?.growthRatio == 5.0)
    #expect(event?.repositoryCount == 1)
    #expect(event?.openedWorktreeCount == 2)
    #expect(event?.terminalTabCount == 3)
  }

  // MARK: - Test helpers

  private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

  private nonisolated struct CapturedEvent: Sendable, Equatable {
    let event: String
    let residentMB: Int?
    let baselineMB: Int?
    let growthRatio: Double?
    let uptimeSeconds: Int?
    let repositoryCount: Int?
    let openedWorktreeCount: Int?
    let terminalTabCount: Int?

    init(event: String, properties: [String: Any]) {
      self.event = event
      residentMB = properties["resident_mb"] as? Int
      baselineMB = properties["baseline_mb"] as? Int
      growthRatio = properties["growth_ratio"] as? Double
      uptimeSeconds = properties["uptime_seconds"] as? Int
      repositoryCount = properties["repository_count"] as? Int
      openedWorktreeCount = properties["opened_worktree_count"] as? Int
      terminalTabCount = properties["terminal_tab_count"] as? Int
    }
  }

  private struct Env {
    let watchdog: MemoryWatchdog
    let currentMB: LockIsolated<Int>
    let now: LockIsolated<Date>
    let events: LockIsolated<[CapturedEvent]>
    let sentryMessages: LockIsolated<[String]>
  }

  private func makeEnv(baselineMB: Int) -> Env {
    let currentMB = LockIsolated(baselineMB)
    let now = LockIsolated(baseDate)
    let events = LockIsolated<[CapturedEvent]>([])
    let sentryMessages = LockIsolated<[String]>([])
    let watchdog = MemoryWatchdog(
      probe: { currentMB.value },
      clock: { now.value },
      tickInterval: 300,
      baselineDelay: 180,
      thresholdsMB: [2_048, 4_096, 8_192],
      sentryThresholdMB: 4_096,
      analyticsCapture: { event, properties in
        let captured = CapturedEvent(event: event, properties: properties ?? [:])
        events.withValue { $0.append(captured) }
      },
      sentryCapture: { message in
        sentryMessages.withValue { $0.append(message) }
      },
      contextProvider: {
        .init(repositoryCount: 1, openedWorktreeCount: 2, terminalTabCount: 3)
      }
    )
    return Env(
      watchdog: watchdog,
      currentMB: currentMB,
      now: now,
      events: events,
      sentryMessages: sentryMessages
    )
  }
}
