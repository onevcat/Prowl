import CoreGraphics
import Foundation
import Testing

@testable import Prowl

struct GhosttyRuntimeSplitDividerWidthTests {
  @Test func parsesBareIntegerValue() {
    let parsed = GhosttyRuntime.parseProwlSplitDividerWidth(
      from: """
        font-size = 14
        prowl-split-divider-width = 3
        background = #000000
        """)

    #expect(parsed == 3)
  }

  @Test func parsesDecimalValue() {
    let parsed = GhosttyRuntime.parseProwlSplitDividerWidth(
      from: "prowl-split-divider-width = 1.5\n")

    #expect(parsed == 1.5)
  }

  @Test func toleratesExtraWhitespaceAroundEquals() {
    let parsed = GhosttyRuntime.parseProwlSplitDividerWidth(
      from: "   prowl-split-divider-width   =    2   ")

    #expect(parsed == 2)
  }

  @Test func ignoresCommentedDirective() {
    let parsed = GhosttyRuntime.parseProwlSplitDividerWidth(
      from: "# prowl-split-divider-width = 5")

    #expect(parsed == nil)
  }

  @Test func returnsNilWhenKeyAbsent() {
    let parsed = GhosttyRuntime.parseProwlSplitDividerWidth(
      from: """
        font-size = 14
        background = #000000
        """)

    #expect(parsed == nil)
  }

  @Test func ignoresNonNumericValue() {
    let parsed = GhosttyRuntime.parseProwlSplitDividerWidth(
      from: "prowl-split-divider-width = wide")

    #expect(parsed == nil)
  }

  @Test func lastDeclarationWins() {
    let parsed = GhosttyRuntime.parseProwlSplitDividerWidth(
      from: """
        prowl-split-divider-width = 1
        prowl-split-divider-width = 4
        """)

    #expect(parsed == 4)
  }

  @Test func clampsExcessiveValues() {
    let parsed = GhosttyRuntime.parseProwlSplitDividerWidth(
      from: "prowl-split-divider-width = 9999")

    #expect(parsed == 32)
  }

  @Test func clampsNegativeValuesToZero() {
    let parsed = GhosttyRuntime.parseProwlSplitDividerWidth(
      from: "prowl-split-divider-width = -3")

    #expect(parsed == 0)
  }

  @Test func ignoresUnrelatedProwlPrefixedKeys() {
    let parsed = GhosttyRuntime.parseProwlSplitDividerWidth(
      from: "prowl-split-divider-color = #ff0000")

    #expect(parsed == nil)
  }

  @MainActor
  @Test func readsTheFileAgainOnlyAfterTheConfigChanges() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "split-divider-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = directory.appending(path: "first.conf")
    let second = directory.appending(path: "second.conf")
    try "prowl-split-divider-width = 3\n".write(to: first, atomically: true, encoding: .utf8)
    try "prowl-split-divider-width = 7\n".write(to: second, atomically: true, encoding: .utf8)
    let runtime = GhosttyRuntime(configSource: .file(path: first.path(percentEncoded: false)))

    #expect(runtime.splitDividerWidth() == 3)
    try "prowl-split-divider-width = 5\n".write(to: first, atomically: true, encoding: .utf8)
    #expect(runtime.splitDividerWidth() == 3)

    runtime.reloadAppConfig()
    #expect(runtime.splitDividerWidth() == 5)

    runtime.setConfigSource(.file(path: second.path(percentEncoded: false)))
    #expect(runtime.splitDividerWidth() == 7)
  }
}
