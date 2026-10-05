import Foundation
import Testing

@testable import Prowl

struct GhosttyRawConfigTests {
  @Test func commentsAreSkippedAndTheLastValueWins() throws {
    let directory = try Self.makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = try Self.write(
      """
      # theme = should-be-ignored
      theme = kanagawabones
      font-size = 14
        # theme = indented comment
      theme = "light:Everforest Dark Hard,dark:Everforest Dark Hard"
      """,
      to: directory.appending(path: "config.ghostty")
    )
    #expect(
      GhosttyRawConfig.lastValue(of: "theme", files: [file])
        == "light:Everforest Dark Hard,dark:Everforest Dark Hard")
    #expect(GhosttyRawConfig.lastValue(of: "font-family", files: [file]) == nil)
  }

  @Test func blankValueClearsTheSetting() throws {
    let directory = try Self.makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = try Self.write("theme = Nord\ntheme =\n", to: directory.appending(path: "config.ghostty"))
    #expect(GhosttyRawConfig.lastValue(of: "theme", files: [file]) == nil)
  }

  /// Includes load after every root file, in the order they are named, and
  /// nested includes load after them.
  @Test func includesFollowGhosttyLoadOrder() throws {
    let directory = try Self.makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let nested = directory.appending(path: "nested", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    _ = try Self.write("value = deep\n", to: nested.appending(path: "deep.ghostty"))
    _ = try Self.write("value = a-include\nconfig-file = deep.ghostty\n", to: nested.appending(path: "a.ghostty"))
    let first = try Self.write(
      """
      value = root-1
      config-file = ?"nested/missing.ghostty"
      config-file = nested/a.ghostty
      """,
      to: directory.appending(path: "first.ghostty")
    )
    let second = try Self.write("value = root-2\n", to: directory.appending(path: "second.ghostty"))

    let values = GhosttyRawConfig.entries(files: [first, second]).filter { $0.key == "value" }.map(\.value)
    #expect(values == ["root-1", "root-2", "a-include", "deep"])
  }

  @Test func includeCyclesStop() throws {
    let directory = try Self.makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = try Self.write("config-file = b.ghostty\nvalue = a\n", to: directory.appending(path: "a.ghostty"))
    _ = try Self.write("config-file = a.ghostty\nvalue = b\n", to: directory.appending(path: "b.ghostty"))
    let values = GhosttyRawConfig.entries(files: [first]).filter { $0.key == "value" }.map(\.value)
    #expect(values == ["a", "b"])
  }

  @Test func includePathsResolveLikeGhostty() {
    let file = URL(fileURLWithPath: "/Users/me/.config/ghostty/config.ghostty")
    let home = FileManager.default.homeDirectoryForCurrentUser
    #expect(
      GhosttyRawConfig.includeURL("themes/dark.ghostty", relativeTo: file)
        == URL(fileURLWithPath: "/Users/me/.config/ghostty/themes/dark.ghostty"))
    #expect(
      GhosttyRawConfig.includeURL("?\"/etc/ghostty extra\"", relativeTo: file)
        == URL(fileURLWithPath: "/etc/ghostty extra"))
    #expect(
      GhosttyRawConfig.includeURL("~/fonts.ghostty", relativeTo: file)
        == home.appending(path: "fonts.ghostty").standardizedFileURL)
    #expect(GhosttyRawConfig.includeURL("?", relativeTo: file) == nil)
  }

  private static func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "GhosttyRawConfigTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private static func write(_ contents: String, to url: URL) throws -> URL {
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
  }
}
