import Foundation
import GhosttyKit
import Testing

@testable import Prowl

struct GhosttyConfigSourceTests {
  @Test func blankPathSelectsGhosttyDefaultFiles() {
    for path: String? in [nil, "", "  \n"] {
      #expect(GhosttyConfigSource(dedicatedPath: path) == .ghosttyDefault)
    }
  }

  @Test func dedicatedPathIsTrimmedAndTildeExpanded() {
    let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
    let source = GhosttyConfigSource(dedicatedPath: "  ~/prowl/ghostty.conf ")
    guard case .file(let path) = source else {
      Issue.record("Expected a dedicated file, got \(source)")
      return
    }
    #expect(path.hasPrefix(home.hasSuffix("/") ? home : home + "/"))
    #expect(path.hasSuffix("/prowl/ghostty.conf"))
    #expect(GhosttyConfigSource.normalizedPath("  /tmp/a.conf ") == "/tmp/a.conf")
  }

  @Test func dedicatedFileIsTheEditableAndOnlyRootFile() {
    let source = GhosttyConfigSource.file(path: "/tmp/prowl-ghostty.conf")
    #expect(source.editableFilePath == "/tmp/prowl-ghostty.conf")
    #expect(source.userConfigFileURLs == [URL(fileURLWithPath: "/tmp/prowl-ghostty.conf")])
  }

  @Test func sharedSourceListsGhosttyDefaultFilesInLoadOrder() {
    let names = GhosttyConfigSource.ghosttyDefault.userConfigFileURLs.map {
      "\($0.deletingLastPathComponent().lastPathComponent)/\($0.lastPathComponent)"
    }
    #expect(
      names == [
        "ghostty/config", "ghostty/config.ghostty",
        "com.mitchellh.ghostty/config", "com.mitchellh.ghostty/config.ghostty",
      ])
  }

  @Test func dedicatedFileReplacesTheSharedConfig() throws {
    let directory = try Self.makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "prowl.ghostty")
    try "font-size = 23\n".write(to: file, atomically: true, encoding: .utf8)

    let config = try #require(
      GhosttyRuntime.makeConfig(source: .file(path: file.path(percentEncoded: false)), overrideFileURLs: [])
    )
    defer { ghostty_config_free(config) }
    #expect(Self.fontSize(config) == 23)
  }

  @Test func dedicatedFileFollowsItsIncludes() throws {
    let directory = try Self.makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let included = directory.appending(path: "fonts.ghostty")
    try "font-size = 19\n".write(to: included, atomically: true, encoding: .utf8)
    let file = directory.appending(path: "prowl.ghostty")
    try "config-file = fonts.ghostty\n".write(to: file, atomically: true, encoding: .utf8)

    let config = try #require(
      GhosttyRuntime.makeConfig(source: .file(path: file.path(percentEncoded: false)), overrideFileURLs: [])
    )
    defer { ghostty_config_free(config) }
    #expect(Self.fontSize(config) == 19)
  }

  /// A missing dedicated file loads nothing; the result matches an empty file,
  /// so no shared Ghostty setting leaks in.
  @Test func missingDedicatedFileLoadsOnlyBuiltInDefaults() throws {
    let directory = try Self.makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let empty = directory.appending(path: "empty.ghostty")
    try "".write(to: empty, atomically: true, encoding: .utf8)
    let missing = directory.appending(path: "missing.ghostty")

    let emptyConfig = try #require(
      GhosttyRuntime.makeConfig(source: .file(path: empty.path(percentEncoded: false)), overrideFileURLs: [])
    )
    defer { ghostty_config_free(emptyConfig) }
    let missingConfig = try #require(
      GhosttyRuntime.makeConfig(source: .file(path: missing.path(percentEncoded: false)), overrideFileURLs: [])
    )
    defer { ghostty_config_free(missingConfig) }
    #expect(Self.fontSize(missingConfig) == Self.fontSize(emptyConfig))
    #expect(!FileManager.default.fileExists(atPath: missing.path(percentEncoded: false)))
  }

  @Test func overrideFilesWinOverTheDedicatedFile() throws {
    let directory = try Self.makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "prowl.ghostty")
    try "font-size = 23\n".write(to: file, atomically: true, encoding: .utf8)
    let override = directory.appending(path: "override.conf")
    try "font-size = 15\n".write(to: override, atomically: true, encoding: .utf8)

    let config = try #require(
      GhosttyRuntime.makeConfig(source: .file(path: file.path(percentEncoded: false)), overrideFileURLs: [override])
    )
    defer { ghostty_config_free(config) }
    #expect(Self.fontSize(config) == 15)
  }

  @Test func dedicatedFileSnapshotReadsBackgroundAndRawTheme() throws {
    let directory = try Self.makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "prowl.ghostty")
    try "background = #fafafa\n".write(to: file, atomically: true, encoding: .utf8)

    let source = GhosttyConfigSource.file(path: file.path(percentEncoded: false))
    let snapshot = try #require(GhosttyRuntime.userConfigSnapshot(loading: source))
    #expect(snapshot == GhosttyUserConfigSnapshot(themeMode: .none, backgroundTone: .light))

    try "background = #101010\ntheme = light:A,dark:B\n".write(to: file, atomically: true, encoding: .utf8)
    let dual = try #require(GhosttyRuntime.userConfigSnapshot(loading: source))
    #expect(dual.themeMode == .dual)
    #expect(dual.backgroundTone == .dark)
  }

  /// A light/dark pair set in an include is the user's explicit choice, so the
  /// theme fallback must not treat the config as having no theme.
  @Test func dedicatedFileSnapshotFollowsIncludesForTheTheme() throws {
    let directory = try Self.makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try "theme = light:My Light,dark:My Dark\n".write(
      to: directory.appending(path: "themes.ghostty"), atomically: true, encoding: .utf8)
    let file = directory.appending(path: "prowl.ghostty")
    try "background = #101010\nconfig-file = themes.ghostty\n".write(to: file, atomically: true, encoding: .utf8)

    let source = GhosttyConfigSource.file(path: file.path(percentEncoded: false))
    let snapshot = try #require(GhosttyRuntime.userConfigSnapshot(loading: source))
    #expect(snapshot.themeMode == .dual)
  }

  /// A blank `config-file` drops the include, so its light/dark pair never applies.
  @Test func clearedIncludeThemeIsNotTheUsersTheme() throws {
    let directory = try Self.makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try "theme = light:My Light,dark:My Dark\n".write(
      to: directory.appending(path: "themes.ghostty"), atomically: true, encoding: .utf8)
    let file = directory.appending(path: "prowl.ghostty")
    try "config-file = themes.ghostty\nconfig-file =\n".write(to: file, atomically: true, encoding: .utf8)

    let source = GhosttyConfigSource.file(path: file.path(percentEncoded: false))
    #expect(GhosttyRuntime.rawUserThemeMode(source: source) == nil)
    let snapshot = try #require(GhosttyRuntime.userConfigSnapshot(loading: source))
    #expect(snapshot.themeMode == .none)
  }

  /// Ghostty loads includes after the file that names them, so an included theme wins.
  @Test func includedThemeWinsOverTheRootTheme() throws {
    let directory = try Self.makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try "theme = Single\n".write(
      to: directory.appending(path: "themes.ghostty"), atomically: true, encoding: .utf8)
    let file = directory.appending(path: "prowl.ghostty")
    try "config-file = themes.ghostty\ntheme = light:A,dark:B\n".write(to: file, atomically: true, encoding: .utf8)

    let source = GhosttyConfigSource.file(path: file.path(percentEncoded: false))
    #expect(GhosttyRuntime.rawUserThemeMode(source: source) == .single)
  }

  private static func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "GhosttyConfigSourceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private static func fontSize(_ config: ghostty_config_t) -> Float {
    var value: Float = 0
    let key = "font-size"
    _ = ghostty_config_get(config, &value, key, UInt(key.lengthOfBytes(using: .utf8)))
    return value
  }
}
