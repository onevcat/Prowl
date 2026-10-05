import Foundation
import GhosttyKit
import Testing

@testable import Prowl

struct GhosttyCJKFontFallbackTests {
  @Test(arguments: [
    (["ja-JP"], "Hiragino Sans"),
    (["en-US", "ja-JP"], "Hiragino Sans"),
    (["fr-FR", "zh-Hant-TW", "ja-JP"], "PingFang TC"),
    (["zh-Hans-CN"], "PingFang SC"),
    (["zh-Hans-JP", "ja-JP"], "PingFang SC"),
    (["zh-TW"], "PingFang TC"),
    (["zh-Hant"], "PingFang TC"),
    (["zh-HK"], "PingFang HK"),
    (["zh-Hant-MO"], "PingFang HK"),
    (["zh"], "PingFang SC"),
    (["ko-KR"], "Apple SD Gothic Neo"),
    (["en-US"], "PingFang SC"),
    ([], "PingFang SC"),
  ])
  func cjkFamilyFollowsTheFirstCJKLanguage(languages: [String], family: String) {
    #expect(GhosttyCJKFontFallback.cjkFamily(preferredLanguages: languages) == family)
  }

  @Test func launchArgumentThenSystemThenProcessLanguagesPickTheFont() {
    #expect(
      GhosttyCJKFontFallback.preferredLanguages(
        argumentLanguages: ["ja-JP"], systemLanguages: ["zh-Hans-CN"], processLanguages: ["en"]
      ) == ["ja-JP"]
    )
    #expect(
      GhosttyCJKFontFallback.preferredLanguages(
        argumentLanguages: nil, systemLanguages: ["ja-JP", "en-US"], processLanguages: ["en"]
      ) == ["ja-JP", "en-US"]
    )
    #expect(
      GhosttyCJKFontFallback.preferredLanguages(
        argumentLanguages: [], systemLanguages: [], processLanguages: ["ko-KR"]
      ) == ["ko-KR"]
    )
  }

  @Test func overrideMapsCJKAndHangulRanges() throws {
    let contents = try #require(
      GhosttyCJKFontFallback.overrideContents(userConfigFiles: [], preferredLanguages: ["ja-JP"])
    )
    let lines = contents.split(whereSeparator: \.isNewline).map(String.init)
    #expect(lines.count == 2)
    #expect(lines[0].hasPrefix("font-codepoint-map = U+2E80-U+2FFF,"))
    #expect(lines[0].contains("U+3040-U+30FF"))
    #expect(lines[0].contains("U+4E00-U+9FFF"))
    #expect(lines[0].contains("U+FF00-U+FF9F"))
    #expect(lines[0].contains("U+FFE0-U+FFEF"))
    #expect(!lines[0].contains("U+FFA0"))
    #expect(lines[0].contains("U+1AFF0-U+1B16F"))
    #expect(lines[0].contains("U+20000-U+323AF"))
    #expect(lines[0].hasSuffix("=Hiragino Sans"))
    #expect(lines[1].contains("U+AC00-U+D7AF"))
    #expect(lines[1].contains("U+FFA0-U+FFDC"))
    #expect(lines[1].hasSuffix("=Apple SD Gothic Neo"))
  }

  /// Ghostty accepts the generated lines without a diagnostic.
  @Test func overrideIsValidGhosttyConfig() throws {
    let directory = try Self.makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let contents = try #require(
      GhosttyCJKFontFallback.overrideContents(userConfigFiles: [], preferredLanguages: ["zh-Hant-TW"])
    )
    let file = directory.appending(path: "cjk.conf")
    try contents.write(to: file, atomically: true, encoding: .utf8)

    let config = try #require(ghostty_config_new())
    defer { ghostty_config_free(config) }
    file.path(percentEncoded: false).withCString { ghostty_config_load_file(config, $0) }
    ghostty_config_finalize(config)
    #expect(ghostty_config_diagnostics_count(config) == 0)
  }

  @Test func noConfigOrCommentsOnlyConfiguresNoFont() throws {
    let directory = try Self.makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let template = try Self.write(
      """
      # font-family = Maple Mono NF CN
      theme = Catppuccin Latte
      font-family-bold = Menlo
      font-size = 14
      """,
      to: directory.appending(path: "config.ghostty")
    )
    let missing = directory.appending(path: "missing.ghostty")
    #expect(!GhosttyCJKFontFallback.configuresFont(files: []))
    #expect(!GhosttyCJKFontFallback.configuresFont(files: [template, missing]))
    #expect(
      GhosttyCJKFontFallback.overrideContents(userConfigFiles: [template], preferredLanguages: ["ja"]) != nil
    )
  }

  @Test func fontFamilyOrCodepointMapIsAConfiguredFont() throws {
    let directory = try Self.makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let family = try Self.write(
      "font-family = \"Maple Mono NF CN\"\n", to: directory.appending(path: "family.ghostty"))
    let map = try Self.write(
      "font-codepoint-map = U+3040-U+30FF=Klee One\n", to: directory.appending(path: "map.ghostty"))
    #expect(GhosttyCJKFontFallback.configuresFont(files: [family]))
    #expect(GhosttyCJKFontFallback.configuresFont(files: [map]))
    #expect(
      GhosttyCJKFontFallback.overrideContents(userConfigFiles: [family], preferredLanguages: ["ja"]) == nil
    )
  }

  /// A blank value clears the list, as Ghostty does, and later files win.
  @Test func blankValueResetsAConfiguredFont() throws {
    let directory = try Self.makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = try Self.write("font-family = Menlo\n", to: directory.appending(path: "a.ghostty"))
    let second = try Self.write("font-family = \"\"\n", to: directory.appending(path: "b.ghostty"))
    #expect(!GhosttyCJKFontFallback.configuresFont(files: [first, second]))
    #expect(GhosttyCJKFontFallback.configuresFont(files: [second, first]))
  }

  /// Ghostty skips a UTF-8 byte order mark, so a font on the first line still counts.
  @Test func fontAfterAByteOrderMarkIsAConfiguredFont() throws {
    let directory = try Self.makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
    let root = directory.appending(path: "config.ghostty")
    try Data(bom + Array("font-family = Maple Mono NF CN\n".utf8)).write(to: root)
    let include = directory.appending(path: "fonts.ghostty")
    try Data(bom + Array("font-codepoint-map = U+3040-U+30FF=Klee One\n".utf8)).write(to: include)
    let includingRoot = try Self.write("config-file = fonts.ghostty\n", to: directory.appending(path: "b.ghostty"))

    #expect(GhosttyCJKFontFallback.configuresFont(files: [root]))
    #expect(GhosttyCJKFontFallback.configuresFont(files: [includingRoot]))
    #expect(
      GhosttyCJKFontFallback.overrideContents(userConfigFiles: [root], preferredLanguages: ["ja"]) == nil
    )
  }

  /// Ghostty reads `--key=value` launch arguments after the config files.
  @Test func launchArgumentFontsCountLikeConfigLines() throws {
    let directory = try Self.makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let empty = try Self.write("# no fonts\n", to: directory.appending(path: "empty.ghostty"))
    let family = try Self.write("font-family = Menlo\n", to: directory.appending(path: "family.ghostty"))

    #expect(GhosttyCJKFontFallback.configuresFont(files: [empty], arguments: ["Prowl", "--font-family=Menlo"]))
    #expect(
      GhosttyCJKFontFallback.configuresFont(
        files: [empty], arguments: ["Prowl", "--font-codepoint-map=U+3040-U+30FF=Klee One"]))
    #expect(!GhosttyCJKFontFallback.configuresFont(files: [family], arguments: ["Prowl", "--font-family="]))
    #expect(
      !GhosttyCJKFontFallback.configuresFont(
        files: [empty], arguments: ["Prowl", "-AppleLanguages", "(ja-JP)", "-e", "--font-family=Menlo"]))
    #expect(
      GhosttyCJKFontFallback.overrideContents(
        userConfigFiles: [empty], arguments: ["Prowl", "--font-family=Menlo"], preferredLanguages: ["ja"]) == nil
    )
  }

  /// A theme file can set a font, and the user's config loads after it.
  @Test func fontFromTheActiveThemeIsAConfiguredFont() throws {
    let directory = try Self.makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let userThemes = directory.appending(path: "user-themes", directoryHint: .isDirectory)
    let builtInThemes = directory.appending(path: "resources-themes", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: userThemes, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: builtInThemes, withIntermediateDirectories: true)
    _ = try Self.write(
      "font-family = Maple Mono NF CN\nconfig-file = ignored.ghostty\n", to: userThemes.appending(path: "Fonty"))
    _ = try Self.write("background = #000000\n", to: builtInThemes.appending(path: "Plain"))
    let absoluteTheme = try Self.write(
      "font-codepoint-map = U+3040-U+30FF=Klee One\n", to: directory.appending(path: "absolute-theme"))
    let directories = [userThemes, builtInThemes]
    func configures(_ config: String) throws -> Bool {
      let root = try Self.write(config, to: directory.appending(path: "config-\(UUID().uuidString).ghostty"))
      return GhosttyCJKFontFallback.configuresFont(files: [root], themeDirectories: directories)
    }

    #expect(try configures("theme = Fonty\n"))
    #expect(try configures("theme = light:Plain,dark:Fonty\n"))
    #expect(try configures("theme = \(absoluteTheme.path(percentEncoded: false))\n"))
    #expect(try !configures("theme = Plain\n"))
    #expect(try !configures("theme = Missing\n"))
    #expect(try !configures("theme = Fonty\nfont-family =\n"))
    #expect(try !configures("theme = Fonty\ntheme =\n"))
  }

  /// Includes are read as Ghostty loads them; a cleared include does not count.
  @Test func includesAreFollowedLikeGhostty() throws {
    let directory = try Self.makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let nested = directory.appending(path: "nested", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    _ = try Self.write("font-family = Menlo\n", to: nested.appending(path: "fonts.ghostty"))
    let main = try Self.write(
      """
      config-file = ?"nested/missing.ghostty"
      config-file = nested/fonts.ghostty
      """,
      to: directory.appending(path: "config.ghostty")
    )
    #expect(GhosttyCJKFontFallback.configuresFont(files: [main]))

    let cleared = try Self.write(
      "config-file = nested/fonts.ghostty\nconfig-file =\n", to: directory.appending(path: "cleared.ghostty"))
    #expect(!GhosttyCJKFontFallback.configuresFont(files: [cleared]))
  }

  private static func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "GhosttyCJKFontFallbackTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private static func write(_ contents: String, to url: URL) throws -> URL {
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
  }
}
