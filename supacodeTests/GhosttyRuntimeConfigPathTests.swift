import Foundation
import Testing

@testable import supacode

@MainActor
struct GhosttyRuntimeConfigPathTests {
  @Test func loadsAndSwitchesDedicatedConfigFiles() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "prowl-ghostty-config-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let firstConfig = directory.appending(path: "first-config")
    let secondConfig = directory.appending(path: "second-config")
    try "focus-follows-mouse = true".write(to: firstConfig, atomically: true, encoding: .utf8)
    try "background-opacity = 0.42".write(to: secondConfig, atomically: true, encoding: .utf8)

    let runtime = GhosttyRuntime(configPath: firstConfig.path(percentEncoded: false))
    #expect(runtime.configPath == firstConfig.path(percentEncoded: false))
    #expect(runtime.focusFollowsMouse())

    runtime.setConfigPath(secondConfig.path(percentEncoded: false))
    #expect(runtime.configPath == secondConfig.path(percentEncoded: false))
    #expect(!runtime.focusFollowsMouse())
    #expect(abs(runtime.backgroundOpacity() - 0.42) < 0.001)
  }

  @Test func blankConfigPathUsesDefaultSelection() {
    let runtime = GhosttyRuntime(configPath: "   ")
    #expect(runtime.configPath == nil)
  }
}
