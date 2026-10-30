import Foundation
import Testing

@testable import Prowl

/// The open policy for links from terminal output (OSC 8 hyperlinks and
/// `link` config matches), which libghostty 1.4 leaves to the embedder.
struct TerminalLinkTests {
  private func makeDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "TerminalLinkTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func makeFile(_ name: String, in directory: URL, executable: Bool = false) throws -> URL {
    let url = directory.appending(path: name)
    try Data("echo hi\n".utf8).write(to: url)
    if executable {
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
    }
    return url
  }

  @Test func webLinksWithAHostOpenDirectly() {
    #expect(TerminalLink("https://example.com/a?b=1").decision == .allow(URL(string: "https://example.com/a?b=1")!))
    #expect(TerminalLink("HTTP://localhost:3000").decision == .allow(URL(string: "HTTP://localhost:3000")!))
  }

  @Test func webLinksWithoutAHostAreDenied() {
    #expect(TerminalLink("https:relative").decision == .deny(.invalidWebURL))
  }

  @Test func mailtoNeedsAnAddress() {
    #expect(TerminalLink("mailto:someone@example.com").decision == .allow(URL(string: "mailto:someone@example.com")!))
    #expect(TerminalLink("mailto:").decision == .deny(.malformedURL))
  }

  @Test func customSchemesAskFirst() {
    #expect(TerminalLink("vscode://file/tmp/a.swift").decision == .confirm(URL(string: "vscode://file/tmp/a.swift")!))
  }

  @Test func valuesWithoutASchemeAreDenied() {
    #expect(TerminalLink("").decision == .deny(.malformedURL))
    #expect(TerminalLink("src/main.zig").decision == .deny(.malformedURL))
  }

  @Test func unsafeCharactersAreDenied() {
    #expect(TerminalLink("https://example.com/\u{202E}gpj.app").decision == .deny(.unsafeCharacters))
    #expect(TerminalLink("https://example.com/a\nb").decision == .deny(.unsafeCharacters))
    #expect(TerminalLink("https://exa\u{200B}mple.com").decision == .deny(.unsafeCharacters))
  }

  @Test func applicationBundlesAreDenied() {
    #expect(TerminalLink("file:///System/Applications/Calculator.app").decision == .deny(.unsafeFile))
  }

  @Test func executablesAndScriptsAreDenied() throws {
    let directory = try makeDirectory()
    let executable = try makeFile("tool", in: directory, executable: true)
    let command = try makeFile("run.command", in: directory)
    #expect(TerminalLink(executable.absoluteString).decision == .deny(.unsafeFile))
    #expect(TerminalLink(command.absoluteString).decision == .deny(.unsafeFile))
  }

  @Test func symlinkToAnExecutableIsDenied() throws {
    let directory = try makeDirectory()
    let executable = try makeFile("tool", in: directory, executable: true)
    let link = directory.appending(path: "notes.txt")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
    #expect(TerminalLink(link.absoluteString).decision == .deny(.unsafeFile))
  }

  private func makeAlias(_ name: String, to target: URL, in directory: URL) throws -> URL {
    let alias = directory.appending(path: name)
    let data = try target.bookmarkData(options: .suitableForBookmarkFile)
    try URL.writeBookmarkData(data, to: alias)
    return alias
  }

  @Test func finderAliasesAreClassifiedByTheirTarget() throws {
    let directory = try makeDirectory()
    let executable = try makeFile("tool", in: directory, executable: true)
    let notes = try makeFile("notes.txt", in: directory)
    let appAlias = try makeAlias("Report", to: URL(filePath: "/System/Applications/Calculator.app"), in: directory)
    let toolAlias = try makeAlias("Tool alias", to: executable, in: directory)
    let notesAlias = try makeAlias("Notes alias", to: notes, in: directory)
    let symlinkToAlias = directory.appending(path: "readme.txt")
    try FileManager.default.createSymbolicLink(at: symlinkToAlias, withDestinationURL: appAlias)

    #expect(TerminalLink(appAlias.absoluteString).decision == .deny(.unsafeFile))
    #expect(TerminalLink(toolAlias.absoluteString).decision == .deny(.unsafeFile))
    #expect(TerminalLink(symlinkToAlias.absoluteString).decision == .deny(.unsafeFile))
    // A safe target opens, and the alert text names the same file.
    let canonicalNotes = notes.resolvingSymlinksInPath()
    #expect(TerminalLink(notesAlias.absoluteString).decision == .allow(canonicalNotes))
    #expect(TerminalLink(notesAlias.absoluteString).displayString == canonicalNotes.path(percentEncoded: false))
  }

  @Test func plainFilesAndFoldersOpenAtTheirCanonicalPath() throws {
    let directory = try makeDirectory()
    let file = try makeFile("notes.txt", in: directory)
    #expect(TerminalLink(file.absoluteString).decision == .allow(file.resolvingSymlinksInPath()))
    #expect(TerminalLink(directory.absoluteString).decision == .allow(directory.resolvingSymlinksInPath()))
  }

  @Test func missingAndRemoteFilesAreDenied() throws {
    let missing = try makeDirectory().appending(path: "missing.txt")
    #expect(TerminalLink(missing.absoluteString).decision == .deny(.inaccessibleFile))
    #expect(TerminalLink("file://server/share/notes.txt").decision == .deny(.malformedURL))
    #expect(TerminalLink("file:///etc/hosts#top").decision == .deny(.malformedURL))
  }

  @Test func unknownKindPathsBecomeFileURLs() {
    #expect(TerminalLink(unknownKindValue: "/Users/nobody/a/../b.txt").string == "file:///Users/nobody/b.txt")
    let home = URL(filePath: NSHomeDirectory()).appending(path: "notes.txt")
    #expect(TerminalLink(unknownKindValue: "~/notes.txt").string == home.absoluteString)
    #expect(TerminalLink(unknownKindValue: "https://example.com").string == "https://example.com")
    // Unsafe characters stay visible to the check instead of being percent-encoded.
    #expect(TerminalLink(unknownKindValue: "/tmp/a\u{202E}b").decision == .deny(.unsafeCharacters))
  }

  @Test func displayStringEscapesUnsafeCharacters() {
    #expect(TerminalLink("https://example.com/\u{202E}x").displayString == "https://example.com/\\u{202E}x")
  }
}
