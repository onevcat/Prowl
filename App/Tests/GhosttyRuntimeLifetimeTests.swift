import GhosttyKit
import Testing

@testable import Prowl

/// Ghostty posts wakeups and actions from its own threads. They reach the main queue with an
/// unretained pointer and can run after the runtime is released.
@MainActor
struct GhosttyRuntimeLifetimeTests {
  @Test func aReleasedRuntimeIgnoresAQueuedWakeupAndAction() async throws {
    let previous = GhosttyRuntime.shared
    defer { GhosttyRuntime.shared = previous }
    let (runtimeBits, appBits) = try makeAndReleaseRuntime()
    // An isolated deinit can run after a hop to the main actor.
    for _ in 0..<1000 where GhosttyRuntime.isLive(appBits: appBits) {
      await Task.yield()
    }

    #expect(!GhosttyRuntime.isLive(runtimeBits: runtimeBits))
    #expect(!GhosttyRuntime.isLive(appBits: appBits))
    GhosttyRuntime.wakeup(userdataBits: runtimeBits)
    var target = ghostty_target_s()
    target.tag = GHOSTTY_TARGET_APP
    var action = ghostty_action_s()
    action.tag = GHOSTTY_ACTION_QUIT
    #expect(!GhosttyRuntime.handleAction(appBits: appBits, target: target, action: action))
  }

  private func makeAndReleaseRuntime() throws -> (runtimeBits: UInt, appBits: UInt) {
    let runtime = GhosttyRuntime()
    let runtimeBits = UInt(bitPattern: Unmanaged.passUnretained(runtime).toOpaque())
    let appBits = UInt(bitPattern: try #require(runtime.app))
    #expect(GhosttyRuntime.isLive(runtimeBits: runtimeBits))
    #expect(GhosttyRuntime.isLive(appBits: appBits))
    return (runtimeBits, appBits)
  }

  @Test func aLiveRuntimeStillTicksOnAWakeup() throws {
    let runtime = GhosttyRuntime()
    let previous = GhosttyRuntime.shared
    defer { GhosttyRuntime.shared = previous }
    GhosttyRuntime.wakeup(userdataBits: UInt(bitPattern: Unmanaged.passUnretained(runtime).toOpaque()))
    #expect(runtime.app != nil)
  }
}
