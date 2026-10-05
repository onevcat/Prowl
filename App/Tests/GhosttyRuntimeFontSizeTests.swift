import Foundation
import GhosttyKit
import Testing

@testable import Prowl

@MainActor
struct GhosttyRuntimeFontSizeTests {
  /// `font-size` is an `f32` in Ghostty. Reading it into a `Double` gave a
  /// denormal near 5e-315, which became 0 as a `Float32`.
  @Test func defaultFontSizeIsTheConfiguredSize() throws {
    let runtime = GhosttyRuntime()
    let config = try #require(runtime.config)
    let configured = try #require(Self.configuredFontSize(config))
    #expect(configured > 1)
    #expect(runtime.defaultFontSize() == configured)
  }

  /// A remembered size equal to the config's size means "follow the config",
  /// so it is cleared at launch and the cleared value is sent to Settings.
  @Test func rememberedSizeEqualToTheConfigIsCleared() async throws {
    let runtime = GhosttyRuntime()
    let config = try #require(runtime.config)
    let configured = try #require(Self.configuredFontSize(config))
    let manager = WorktreeTerminalManager(runtime: runtime, preferredFontSize: configured)
    try #require(manager.preferredFontSizeForTesting == nil)

    let stream = manager.eventStream()
    var cleared = false
    for await event in stream {
      if case .fontSizeChanged(let size) = event {
        cleared = size == nil
        break
      }
    }
    #expect(cleared)
  }

  @Test func rememberedSizeThatDiffersFromTheConfigIsKept() throws {
    let runtime = GhosttyRuntime()
    let config = try #require(runtime.config)
    let configured = try #require(Self.configuredFontSize(config))
    let manager = WorktreeTerminalManager(runtime: runtime, preferredFontSize: configured + 3)
    #expect(manager.preferredFontSizeForTesting == configured + 3)
  }

  /// Reads `font-size` the way Ghostty stores it, independent of the code under test.
  private static func configuredFontSize(_ config: ghostty_config_t) -> Float32? {
    var value: Float32 = 0
    let key = "font-size"
    guard ghostty_config_get(config, &value, key, UInt(key.lengthOfBytes(using: .utf8))) else { return nil }
    return value
  }
}
